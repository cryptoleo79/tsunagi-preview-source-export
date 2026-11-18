-- | Praos threshold oracle — computes T = 1 - (1-f)^sigma exactly as
-- cardano-node does, using 34-digit fixed-point arithmetic.
--
-- Arithmetic source:
--   ln  : generalized continued fraction (Cardano.Ledger.NonIntegral.ln')
--   exp : Taylor series with argument reduction (Cardano.Ledger.NonIntegral.exp')
--   FixedPoint = Data.Fixed.Fixed E34  (34 decimal digits, from Cardano.Ledger.BaseTypes)
--   activeSlotLog storage: floor(10^34 * ln'(1-f)) then reload (mkActiveSlotCoeff)
--
-- Output: JSONL with non-null expected_threshold_x1e12.
-- Rounding for x1e12 conversion: floor.

module Main where

import Data.Char (isDigit)
import Data.Fixed (Fixed, HasResolution (..))
import Data.List (intercalate)
import NonIntegral (exp', ln')
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

--------------------------------------------------------------------
-- FixedPoint type (34 decimal digits)
-- Source: cardano-ledger/libs/cardano-ledger-core/src/Cardano/Ledger/BaseTypes.hs
--------------------------------------------------------------------
data E34

instance HasResolution E34 where
  resolution _ = (10 :: Integer) ^ (34 :: Integer)

type FixedPoint = Fixed E34

fpPrecision :: FixedPoint
fpPrecision = (10 :: FixedPoint) ^ (34 :: Integer)

--------------------------------------------------------------------
-- Threshold computation
--
-- Replicates cardano-node behavior:
--   1. activeSlotLog = floor(fpPrecision * ln'(1 - f)) / fpPrecision
--      (from mkActiveSlotCoeff in Cardano.Ledger.BaseTypes)
--   2. T = 1 - exp'(sigma * activeSlotLog)
--   3. expected_threshold_x1e12 = floor(T * 10^12)
--------------------------------------------------------------------
computeThresholdX1e12 :: Integer -> Integer -> Integer
computeThresholdX1e12 stakeX1e9 ascX1e6
  | stakeX1e9 <= 0 || ascX1e6 <= 0 = 0
  | ascX1e6 >= 1000000 = 1000000000000
  | otherwise =
      let f = fromIntegral ascX1e6 / 1000000 :: FixedPoint
          sigma = fromIntegral stakeX1e9 / 1000000000 :: FixedPoint
          -- Replicate mkActiveSlotCoeff: floor + reload
          logRaw = ln' (1 - f) :: FixedPoint
          logStored = floor (fpPrecision * logRaw) :: Integer
          c = fromIntegral logStored / fpPrecision :: FixedPoint
          -- T = 1 - (1-f)^sigma = 1 - exp(sigma * ln(1-f))
          t = 1 - exp' (sigma * c) :: FixedPoint
       in max 0 (floor (t * 1000000000000))

--------------------------------------------------------------------
-- JSONL output (manual formatting, no aeson dependency)
--------------------------------------------------------------------
jsonLine :: String -> Integer -> Integer -> Integer -> String -> String
jsonLine mode stakeX1e9 ascX1e6 threshX1e12 oracleVer =
  "{"
    ++ "\"mode\":"
    ++ show mode
    ++ ",\"stake_fraction_x1e9\":"
    ++ show stakeX1e9
    ++ ",\"asc_x1e6\":"
    ++ show ascX1e6
    ++ ",\"expected_threshold_x1e12\":"
    ++ show threshX1e12
    ++ ",\"oracle\":\"cardano-node\""
    ++ ",\"oracle_version\":"
    ++ show oracleVer
    ++ ",\"expected_threshold_rounding\":\"floor\""
    ++ "}"

--------------------------------------------------------------------
-- CLI
--------------------------------------------------------------------
data Config = Config
  { cfgMode :: String,
    cfgAscList :: [Integer],
    cfgStakeList :: [Integer],
    cfgOut :: Maybe FilePath,
    cfgOracleVer :: String,
    cfgStdin :: Bool
  }

defaultStakeList :: [Integer]
defaultStakeList =
  [1000, 10000, 100000, 1000000, 10000000, 100000000, 500000000, 900000000, 1000000000]

defaultConfig :: Config
defaultConfig =
  Config
    { cfgMode = "preview",
      cfgAscList = [50000],
      cfgStakeList = defaultStakeList,
      cfgOut = Nothing,
      cfgOracleVer = "non-integral-vendored",
      cfgStdin = False
    }

parseArgs :: [String] -> Either String Config
parseArgs = go defaultConfig
  where
    go cfg [] = Right cfg
    go cfg ("--mode" : v : rest) = go cfg {cfgMode = v} rest
    go cfg ("--asc-list" : v : rest) = case parseIntList v of
      Just xs -> go cfg {cfgAscList = xs} rest
      Nothing -> Left ("invalid --asc-list: " ++ v)
    go cfg ("--stake-list" : v : rest) = case parseIntList v of
      Just xs -> go cfg {cfgStakeList = xs} rest
      Nothing -> Left ("invalid --stake-list: " ++ v)
    go cfg ("--out" : v : rest) = go cfg {cfgOut = Just v} rest
    go cfg ("--oracle-version" : v : rest) = go cfg {cfgOracleVer = v} rest
    go cfg ("--stdin" : rest) = go cfg {cfgStdin = True} rest
    go _ (x : _) = Left ("unknown option: " ++ x)

parseIntList :: String -> Maybe [Integer]
parseIntList s =
  let parts = splitBy ',' s
   in if not (null parts) && all (\p -> not (null p) && all isDigit p) parts
        then Just (map read parts)
        else Nothing

splitBy :: Char -> String -> [String]
splitBy _ "" = []
splitBy sep s =
  let (w, rest) = break (== sep) s
   in w : case rest of
        [] -> []
        (_ : rs) -> splitBy sep rs

--------------------------------------------------------------------
-- Stdin JSONL parsing (minimal)
--------------------------------------------------------------------
extractJsonInt :: String -> String -> Maybe Integer
extractJsonInt key json =
  case findKey key json of
    Nothing -> Nothing
    Just rest ->
      let afterColon = dropWhile (\c -> c == ':' || c == ' ') rest
          digits = takeWhile isDigit afterColon
       in if null digits then Nothing else Just (read digits)

findKey :: String -> String -> Maybe String
findKey key = go
  where
    needle = "\"" ++ key ++ "\""
    nLen = length needle
    go [] = Nothing
    go s
      | take nLen s == needle = Just (drop nLen s)
      | otherwise = go (tail s)

parseStdinLine :: String -> Maybe (Integer, Integer)
parseStdinLine line = do
  stake <- extractJsonInt "stake_fraction_x1e9" line
  asc <- extractJsonInt "asc_x1e6" line
  Just (stake, asc)

--------------------------------------------------------------------
-- Main
--------------------------------------------------------------------
main :: IO ()
main = do
  args <- getArgs
  case parseArgs args of
    Left err -> do
      hPutStrLn stderr ("ERROR: " ++ err)
      exitWith (ExitFailure 3)
    Right cfg -> run cfg

run :: Config -> IO ()
run cfg = do
  pairs <-
    if cfgStdin cfg
      then do
        input <- getContents
        let ls = filter (not . null) (lines input)
            parsed = map (\l -> case parseStdinLine l of
                                  Just p -> Right p
                                  Nothing -> Left l) ls
            errs = [l | Left l <- parsed]
            good = [p | Right p <- parsed]
        mapM_ (\l -> hPutStrLn stderr ("WARN: skipping unparseable line: " ++ l)) errs
        return good
      else
        return [(s, a) | a <- cfgAscList cfg, s <- cfgStakeList cfg]

  let outputLines =
        [ jsonLine (cfgMode cfg) s a (computeThresholdX1e12 s a) (cfgOracleVer cfg)
          | (s, a) <- pairs
        ]

  case cfgOut cfg of
    Nothing -> mapM_ putStrLn outputLines
    Just path -> writeFile path (unlines outputLines)

  hPutStrLn stderr $
    "praos-threshold-oracle: "
      ++ show (length pairs)
      ++ " vectors"
      ++ maybe "" (\p -> " -> " ++ p) (cfgOut cfg)

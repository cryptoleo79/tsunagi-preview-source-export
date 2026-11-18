-- | Vendored from cardano-ledger for standalone oracle use.
--
-- Source: https://github.com/IntersectMBO/cardano-ledger
--   libs/non-integral/src/Cardano/Ledger/NonIntegral.hs
--
-- Package: non-integral
-- License: Apache-2.0 (same as original)
--
-- Only the module name is changed (Cardano.Ledger.NonIntegral -> NonIntegral)
-- to avoid directory nesting. All functions are verbatim from the source.

module NonIntegral
  ( (***),
    exp',
    ln',
    findE,
    splitLn,
    scaleExp,
    CompareResult (..),
    taylorExpCmp,
  )
where

data CompareResult a
  = BELOW a Int
  | ABOVE a Int
  | MaxReached Int
  deriving (Show, Eq)

eps :: Fractional a => a
eps = 1 / 10 ^ (24 :: Int)

(***) :: (RealFrac a, Enum a, Show a) => a -> a -> a
a *** b
  | b == 0 = 1
  | a == 0 = 0
  | a == 1 = 1
  | otherwise = exp' (b * ln' a)

ipow' :: Num a => a -> Integer -> a
ipow' x n
  | n == 0 = 1
  | m == 0 = let y = ipow' x d in y * y
  | otherwise = x * ipow' x (n - 1)
  where
    (d, m) = divMod n 2

ipow :: Fractional a => a -> Integer -> a
ipow x n
  | n < 0 = 1 / ipow' x (-n)
  | otherwise = ipow' x n

logAs :: Num a => a -> [a]
logAs a = a' : a' : logAs (a + 1)
  where
    a' = a * a

lncf :: (Fractional a, Enum a, Ord a, Show a) => Int -> a -> a
lncf maxN x
  | x < 0 = error ("x = " ++ show x ++ " is not inside domain [0,..)")
  | otherwise = cf maxN 0 eps Nothing 1 0 0 1 as [1, 2 ..]
  where
    as = x : map (* x) (logAs 1)

cf ::
  (Fractional a, Ord a, Show a) =>
  Int ->
  Int ->
  a ->
  Maybe a ->
  a ->
  a ->
  a ->
  a ->
  [a] ->
  [a] ->
  a
cf maxN n epsilon lastVal aNm2 bNm2 aNm1 bNm1 (an : as) (bn : bs)
  | maxN == n = xn
  | converges = xn
  | otherwise = cf maxN (n + 1) epsilon (Just xn) aNm1 bNm1 aN bN as bs
  where
    converges = maybe False (\x -> abs (x - xn) < epsilon) lastVal
    xn = aN / bN
    aN = bn * aNm1 + an * aNm2
    bN = bn * bNm1 + an * bNm2
cf _ _ _ _ _ _ aN bN _ _ = aN / bN

bound ::
  (Fractional a, Ord a) =>
  a ->
  a ->
  a ->
  a ->
  Integer ->
  Integer ->
  (Integer, Integer)
bound factor x x' x'' l u
  | x' <= x && x <= x'' = (l, u)
  | otherwise = bound factor x (x' * x') (x'' * x'') (2 * l) (2 * u)

contract ::
  (Fractional a, Ord a) =>
  a ->
  a ->
  Integer ->
  Integer ->
  Integer
contract factor x = go
  where
    go l u
      | l + 1 == u = l
      | otherwise =
          if x < x'
            then go l mid
            else go mid u
      where
        mid = l + ((u - l) `div` 2)
        x' = ipow factor mid

exp1 :: (RealFrac a, Show a) => a
exp1 = exp' 1

findE :: RealFrac a => a -> a -> Integer
findE e x = contract e x lower upper
  where
    (lower, upper) = bound e x (1 / e) e (-1) 1

ln' :: (RealFrac a, Enum a, Show a) => a -> a
ln' x
  | x <= 0 = error (show x ++ " is not in domain of ln")
  | otherwise = fromIntegral n + lncf 1000 x'
  where
    (n, x') = splitLn x

splitLn :: (RealFrac a, Show a) => a -> (Integer, a)
splitLn x = (n, x')
  where
    n = findE exp1 x
    y' = ipow exp1 n
    x' = (x / y') - 1

exp' :: (RealFrac a, Show a) => a -> a
exp' x
  | x < 0 = 1 / exp' (-x)
  | otherwise = ipow x' n
  where
    (n, x_) = scaleExp x
    x' = taylorExp 1000 1 x_ 1 1 1

scaleExp :: RealFrac a => a -> (Integer, a)
scaleExp x = (x', x / fromIntegral x')
  where
    x' = ceiling x

taylorExp :: (RealFrac a, Show a) => Int -> Int -> a -> a -> a -> a -> a
taylorExp maxN n x lastX acc divisor
  | maxN == n = acc
  | abs nextX < eps = acc
  | otherwise = taylorExp maxN (n + 1) x nextX (acc + nextX) (divisor + 1)
  where
    nextX = (lastX * x) / divisor

taylorExpCmp :: RealFrac a => a -> a -> a -> CompareResult a
taylorExpCmp boundX cmp x = go 1000 0 x 1 1
  where
    go maxN n err acc divisor
      | maxN == n = MaxReached n
      | cmp >= acc' + errorTerm = ABOVE acc' (n + 1)
      | cmp < acc' - errorTerm = BELOW acc' (n + 1)
      | otherwise = go maxN (n + 1) err' acc' divisor'
      where
        errorTerm = abs (err' * boundX)
        divisor' = divisor + 1
        nextX = err
        err' = (err * x) / divisor'
        acc' = acc + nextX

# TSUNAGI — ビジョンとロードマップ

**Tsunagi — 日本から世界へつなぐ。コードの精密さと、おもてなしの精神とともに。**

English version → [VISION.md](VISION.md)

---

> チェーンを追跡し、ローカル UTxO 状態を維持する Zig のみの Cardano 軽量ノード。

## なぜ Tsunagi か

Cardano のリファレンスノード（cardano-node）は Haskell で書かれており、フル同期に約 24 GB の RAM を必要とし、
組み込みやクロスコンパイルが困難です。私たちは以下を実現する最小限の依存関係のない代替を求めています：

* 月額 5 ドルの VPS（2 GB RAM 以下、1 vCPU）で動作する
* ChainSync/BlockFetch を通じてチェーンの先端を追跡する
* 残高クエリに応答可能なライブの LMDB バック UTxO セットを維持する
* コンパクトなバイナリ形式（TSF）でスナップショットをエクスポート/インポートする
* 完全に Zig で書かれている（libc と lmdb 以外の C/Haskell/Rust 依存なし）

## フェーズ

| フェーズ | タグ | 説明 |
|----------|------|------|
| f1 | v0.7.0–v0.7.9 | Zig ミニプロトコルスタック：TCP フレーム多重化、ハンドシェイク、ChainSync、BlockFetch |
| f2 | v0.7.10–v0.7.14 | CBOR デコーダ、tx_decode、インメモリ UTxO、undo スタック、キャプチャファイル |
| f3 | v0.7.15–v0.7.20 | LMDB UTxO ストア：真実/フォールバック、シード、バックフィル、可観測性、TSF スナップショット |
| **f4** | **v0.7.21** | **ブートストラップコマンド、VISION.md、公開準備パッケージング** |
| f5 | — | 完全な UTxO 収束：より大きなスナップショットによる truth_ratio → 1.0 |
| f6 | — | 残高クエリ HTTP API：GET /utxo/:address |
| f7 | — | マルチアセット対応（UTxO 値におけるネイティブトークン） |
| f8 | — | ステーク / デリゲーション追跡 |

## アーキテクチャ

```
┌───────────────────────────────────────────┐
│                main.zig                    │
│   CLI: run | bootstrap | snapshot-*        │
│         replay | lmdb-seed | backfill      │
└────────────┬──────────────────────────────┘
             │
     ┌───────▼────────┐     ┌──────────────┐
     │  follower.zig   │────▶│ http_metrics  │
     │  ChainSync loop │     │  :9080        │
     └───────┬─────────┘     └──────────────┘
             │
     ┌───────▼────────┐
     │  tx_decode.zig  │  CBOR → TxDeltas (consumed/produced)
     └───────┬─────────┘
             │
     ┌───────▼────────┐     ┌──────────────┐
     │   utxo.zig      │────▶│  lmdb_utxo   │
     │   in-memory      │     │  on-disk      │
     └─────────────────┘     └──────────────┘
```

## ブートストラップ クイックスタート

```bash
# 1. ビルド
cd tsunagi-node && zig build -Doptimize=ReleaseSafe

# 2. TSF スナップショットからブートストラップ
./zig-out/bin/tsunagi-node bootstrap --file utxo-mainnet.tsf

# 3. 実行
./zig-out/bin/tsunagi-node run --net mainnet --lang ja
```

## ライセンス

MIT

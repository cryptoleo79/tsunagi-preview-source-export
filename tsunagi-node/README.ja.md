**言語:** [English](README.md) | 日本語

# Tsunagi Node (Zig専用Cardanoフォロワー)

**Tsunagi** (繋ぎ、「接続・橋渡し」) は、Zig専用のCardanoノード・フォロワーであり、以下を組み合わせてライブUTxOセットを維持します:
- **ChainSync** - チップの進行とヘッダー取得
- **BlockFetch** - 必要に応じた完全なブロックボディの取得
- 堅牢な **CBORデコーダ** とトランザクションボディ抽出パイプライン
- **UTxO適用とロールバック** - アンドゥスタック経由

> 目標: 「WOW JAPAN FIRST」 Zig専用ノードパス、Amaruスタイルのミニマリズムにインスパイアされました。

---

## ステータス

✅ **メインネットで動作中**:
- BlockFetch proto=3 + 断片化メッセージのmux再構成
- 完全なブロックのCBORデコード（確定長・不定長、混合マップキータイプ）
- スコアリングによる実際のトランザクションボディ選択（witness/certマップを拒否）
- UTxOデルタの抽出と適用
- ロールバック処理（アンドゥスタック + rollbackDelta）

**現在のバージョン**: v0.1.0 ([CHANGELOG](CHANGELOG.md))

---

## クイックスタート

### 必要要件
- Zig `0.13.0`
- Linux/macOS（Linuxを推奨）
- Cardanoピアへのネットワークアクセス

### ビルドとテスト
```bash
zig fmt .
zig build test --summary none
```

### 実行（メインネット）
```bash
export TSUNAGI_HOME="$HOME/.tsunagi-mainnet"
mkdir -p "$TSUNAGI_HOME"
zig build run -- run --net mainnet --lang en --debug
```

### 実行（プレビュー）
```bash
export TSUNAGI_HOME="$HOME/.tsunagi-preview"
mkdir -p "$TSUNAGI_HOME"
zig build run -- run --net preview --lang en --debug
```

---

## ネットワーク

Tsunagiはmainnet、preprod、preview、sanchoをサポートします。`--net`フラグは必須です。

| ネットワーク | Magic | デフォルトリレー | ポート |
|---------|-------|---------------|------|
| mainnet | 764824073 | (リレーリスト) | 3001 |
| preprod | 1 | preprod-node.world.dev.cardano.org | 30000 |
| preview | 2 | preview-node.world.dev.cardano.org | 30002 |
| sancho | 4 | sanchonet-node.play.dev.cardano.org | 3001 |

各ネットワークは個別の`TSUNAGI_HOME`ディレクトリを使用します。ネットワーク間でLMDBを共有しないでください。

詳細は[docs/networks.md](docs/networks.md)を参照してください。

---

## 出力ファイル

Tsunagiは`$TSUNAGI_HOME`に状態ファイルを維持します:
- **`cursor.json`** - 同期位置（スロット、ブロック番号、ハッシュ）
- **`journal.ndjson`** - ロールフォワード/バックワードイベントトレース
- **`utxo.snapshot`** - 現在のUTxOカウント + エントリ

`utxo.snapshot`の例:
```
UTXO_COUNT 71
a3f2...8c1d:0 5000000
b7e9...4f2a:1 2000000
...
```

---

## アーキテクチャ概要

### ChainSync (proto=2)
- チェーンチップとロールフォワード/バックワードイベントを追跡
- インターセクト検索とチップ更新を処理

### BlockFetch (proto=3)
- トランザクションボディが必要な時に完全なブロックを取得
- 大きな断片化メッセージ（>12KB）のmuxレベル再構成を含む
- デバッグモードで10ロールフォワードごとに強制トリガー

### デコーダ
- CBORデコーダは不定長bytes/text/arrays/mapsをサポート
- 混合マップキータイプ（bytes、u64、text）を処理
- タグアンラッピング（tag 24、tag 258）

### トランザクション抽出
- 候補のトランザクションボディリストは**スコアリング**されます:
  - 実際のトランザクションボディマップごとに+10ポイント（キー0、1、2を持つ）
  - ハッシュのみのエントリで-5ポイント
- 「実際のトランザクションボディマップ」のみを選択（キー0=inputs、1=outputs、2=fee）
- witness/certificateマップを拒否（outputsまたはfeeが欠落）

### UTxO状態
- **デルタ適用** → アンドゥをプッシュ（roll_forward時）
- **ロールバックワード** → アンドゥをポップ → rollbackDelta
- アンドゥスタック付きでインメモリUTxOセットを維持

---

## デバッグ / ログ

常にファイルにログを記録し、小さなウィンドウでgrepします:
```bash
zig build run -- run --net mainnet --lang en --debug > /tmp/tsunagi.log 2>&1

# BlockFetchアクティビティをチェック
grep -E "BLOCKFETCH|UTXO live applied|ROLL FWD" /tmp/tsunagi.log | tail -n 200

# ロールバックをチェック
grep -E "roll backward|UTXO rollback" /tmp/tsunagi.log

# トランザクション抽出をチェック
grep -E "TX_EXTRACT|tx_list_len|deltas" /tmp/tsunagi.log | tail -100
```

---

## ロードマップ

### v0.2.0（計画中）
- 「ノードブレイン」異常スコアリング（ベイジアンリスクモデル）をフラグの後ろに配置
- より良いUTxO永続化フォーマット（バイナリスナップショット + チェックサム）
- 自動ローテーション付きマルチピアサポート
- メトリクス + 構造化ログ（Prometheus）
- UTxOクエリAPI

### 将来
- フルノード機能（ブロック生成）
- フロントエンド用WebSocket API
- ステークプール統合

---

## コントリビューション

コントリビューションを歓迎します！変更したいことについて、まずissueを開いて議論してください。

---

## ライセンス

MITライセンス - 詳細は[LICENSE](LICENSE)ファイルを参照してください。

---

## 謝辞

インスパイア元:
- [Amaru](https://github.com/txpipe/amaru) - Rust Cardanoノード
- [Pallas](https://github.com/txpipe/pallas) - Rust Cardanoプリミティブ
- Ouroborosプロトコルファミリー

Zigで❤️を込めて構築されました。

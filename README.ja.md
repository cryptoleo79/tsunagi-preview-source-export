# Tsunagi

**Tsunagi — 日本から世界へつなぐ。コードの精密さと、おもてなしの精神とともに。**

English version → [README.md](README.md)

> **Note:** この日本語版は英語版 README.md と一部内容が異なる場合があります。最新の正確な情報は [README.md](README.md) を参照してください。

---

Tsunagi は Zig ネイティブの Cardano ノード実装であり、以下に注力しています：

- 決定論的な台帳実行
- 自己修復型インフラストラクチャ
- LMDB に裏付けられた状態の整合性
- スナップショットベースのブートストラップ
- リプレイ検証可能な状態ダイジェスト
- リオーグ（チェーン再編成）下での運用耐性

利便性よりも正確性を重視するエンジニアのために構築されています。

以下の進化を設計しています：

軽量フォロワー → スナップショットブートストラップノード → LMDB 真実ストア → 完全な Zig ネイティブ Cardano ノード

## ビジョン / ロードマップ
完全なロードマップとアーキテクチャの詳細は [VISION.ja.md](VISION.ja.md) を参照してください。

## マニフェスト
Tsunagi の設計原則については [MANIFESTO.ja.md](MANIFESTO.ja.md) を参照してください。

## セキュリティと信頼モデル
正式な脅威モデル、信頼境界、鍵漏洩シナリオについては [docs/threat-model.md](docs/threat-model.md) を参照してください。Tsunagi はデフォルトで `no_forging` および `no_broadcast` 不変条件を強制します — ブロックの観測と証明のみを行い、生成や送信は行いません。

---

## クイックセットアップ（リレーノード）

Tsunagi にはロールベースのインストーラが含まれており、リレーノードを素早く安全に導入できます。

### Relay（メインネット）

```bash
./zig-out/bin/tsunagi-node setup --role relay
```

systemd ユーザーサービスを作成し、TSF アーティファクトの夜間タイマーを有効化し、ノードを起動します。状態確認やログ確認、メトリクス確認のコマンドも表示されます。

### GitHub Release からインストール

```bash
./zig-out/bin/tsunagi-node setup --role relay --install latest
```

GitHub から最新リリースをダウンロードし、SHA256 を検証して `~/.local/tsunagi/` にインストールします。`--install v0.7.42` でバージョン指定も可能です。

### AutoSwitch を有効化（任意）

```bash
./zig-out/bin/tsunagi-node setup --role relay --autoswitch
```

収束後に LMDB ネイティブモードへ自動切替する AutoSwitch タイマーを有効化します。

### Tools のみ（ノード起動なし）

```bash
./zig-out/bin/tsunagi-node setup --role tools
```

ノードサービスは起動せず、TSF アーティファクトタイマー（＋任意で AutoSwitch）を設定します。

### BP（ブロック生成）

```bash
./zig-out/bin/tsunagi-node setup --role bp
```

BP（ブロック生成）モードは現在未実装です。将来のフルノード鍛造機能のために予約されています。

### コンソール（オペレーターメニュー）

```bash
./zig-out/bin/tsunagi-node console --lang en
./zig-out/bin/tsunagi-node console --lang ja
```

SSH 経由のインタラクティブなオペレーターメニュー。ステータス確認、ログ表示、ノード再起動、メトリクス確認、TSF エクスポート、アップデートインストール、タイマー切替がメニューから操作できます。最新リリースへのアップグレードや、以前のバージョンへのロールバックにも対応しています。

### ローカル送信 API（localhost）

稼働中のノードは `127.0.0.1:9080` でローカル専用の制御 API を公開します：

**トランザクション送信（hex）：**
```bash
echo -n '83a100...' | curl -sS -H 'Content-Type: text/plain' -X POST --data-binary @- http://127.0.0.1:9080/tx/submit
```

**トランザクション送信（生 CBOR）：**
```bash
curl -sS -H 'Content-Type: application/octet-stream' --data-binary @tx.cbor http://127.0.0.1:9080/tx/submit
```

**メンプール確認：**
```bash
curl -sS http://127.0.0.1:9080/mempool
```

**CLI コマンド：**
```bash
./zig-out/bin/tsunagi-node submit-tx --hex 83a100...
./zig-out/bin/tsunagi-node submit-tx --file tx.cbor
./zig-out/bin/tsunagi-node submit-tx --file tx.cbor --offline   # ローカル検証のみ
./zig-out/bin/tsunagi-node mempool                              # 稼働中ノードに問い合わせ
```

**安全性：** localhost のみ（127.0.0.1）。制限: トランザクション最大 64 KB、1024 件、合計 8 MB。

---

## ネットワーク

Tsunagi は 4 つの Cardano ネットワークを厳密な状態分離でサポートしています：

```bash
# --net は必須（デフォルトなし）
tsunagi-node run --net preview
tsunagi-node run --net preprod
tsunagi-node run --net mainnet
tsunagi-node run --net sancho
```

`--net` の代わりに `TSUNAGI_NET` 環境変数も使用可能です。

各ネットワークはデフォルトで個別の TSUNAGI_HOME ディレクトリを使用します：

| ネットワーク | TSUNAGI_HOME |
|------------|-------------|
| mainnet | `~/tsunagi-home-mainnet` |
| preprod | `~/tsunagi-home-preprod` |
| preview | `~/tsunagi-home-preview` |
| sancho | `~/tsunagi-home-sancho` |

**状態分離：** LMDB、キャプチャ、回帰ベースライン、BAeY イベント、genesis ファイルはすべて TSUNAGI_HOME 内に格納されます。ネットワーク間で LMDB ディレクトリを共有しないでください。

上書き指定：`TSUNAGI_HOME=/path/to/dir tsunagi-node run --net preview`

詳細は [tsunagi-node/docs/networks.md](tsunagi-node/docs/networks.md) を参照してください。

---

## フォーク準備検証

Tsunagi v1.6.0 はマルチネットワークのフォーク準備検証を含みます。
詳細は [docs/fork-ready-proof.md](docs/fork-ready-proof.md) およびリリース証明バンドルを参照してください。

---

# Tsunagi Node (Zig)
**Cardano ChainSync フォロワー / 軽量フォロワー**

---

## 概要

Tsunagi は Zig で実装された Cardano ネットワーキングプロジェクトであり、**Node-to-Node（N2N）通信と ChainSync** に焦点を当てています。
Cardano の Preview および Mainnet ピアに接続し、MUX 上で v14 ハンドシェイクを実行し、ロールバック対応の永続状態でチェーンを追跡します。

---

## 現在の機能（v0.5.x）

- Node-to-Node **v14 ハンドシェイク（MUX）**
- ChainSync（FindIntersect / RequestNext）
- RollForward / RollBackward 対応
- 永続状態（Persistent State）
  - `cursor.json`
  - `journal.ndjson`
  - `utxo.snapshot`
- Preview / Mainnet 分離（`TSUNAGI_HOME`）
- Tx 検出ヒューリスティック + TPS 表示
- 英語 / 日本語 CLI
- `doctor` コマンドによる状態チェック

---

## 未対応事項

- フル検証ノード（台帳・コンセンサス検証）
- ブロック生成（BP）
- 完全な UTxO 適用（枠組みは実装済み）

現在は **軽量 ChainSync フォロワー** です。
将来のフルノード実装に向けた基盤です。

---

## 必要環境

- Zig **0.13.x**
- Linux / macOS
- Cardano リレーへのアウトバウンド TCP 接続

---

## ビルドとテスト

```bash
cd tsunagi-node
zig build test --summary all
```

### Genesis セットアップ（プロデューサークロック）

`shelley-genesis.json` を `$TSUNAGI_HOME/genesis/` に配置するか、`TSUNAGI_GENESIS_PATH` を設定してください。
ノードは起動時にメインネット genesis を自動検出します。

```bash
curl -s http://127.0.0.1:9080/state | jq .genesis
```

### Gap バンドル（アーティファクト診断）

`tsf-artifact` 実行時に、ギャップ診断ファイルが `.tsf` 出力と同じディレクトリの `gaps/` に
バンドルされます。これらのファイルには不足 TxIn の追跡データが含まれており、秘密鍵や機密情報は
含まれていないため、安全に共有できます。

ファイル: `missing_inputs.keys`、`top_missing.json`、`missing_inputs.log`（末尾200行）、
`first_seen.json`。

### ベンチマーク

**ベースライン作成:**
```bash
./zig-out/bin/tsunagi-node replay-baseline \
  --file ~/tsunagi-home-mainnet/captures/mainnet.bin \
  --out-dir /tmp/ts-bench
```
`baseline/report.json`、`report.csv`、`per_block.csv` を出力します。

**回帰テスト:**
```bash
./zig-out/bin/tsunagi-node replay-regress \
  --file ~/tsunagi-home-mainnet/captures/mainnet.bin \
  --out-dir /tmp/ts-bench
```
`baseline/report.json` と比較し、PASS/WARN/FAIL を表示します。

**フットプリントレポート:**
```bash
./zig-out/bin/tsunagi-node footprint
```
RSS、LMDB、チェーン状態、収束、BAEY、プロデューサー、ワンライナーを表示します。

### ローカルステートクエリ

```bash
curl -s http://127.0.0.1:9080/state | python3 -m json.tool | head -n 60
```

読み取り専用のオペレーター向け監視エンドポイントです。ウォレット API ではありません。
ティップ、ヘッダ権威、収束、バックフィル、ギャップのメトリクスを JSON で返します。

### 収束モード

systemd ユニットで `TSUNAGI_CAPTURE_ROTATE_MB=16` を設定すると、キャプチャセグメントが頻繁にローテーションされます。これによりバックフィルに多くの履歴が提供され、LMDB の収束が加速します。収束後（truth_ratio >= 0.99）は 64〜256MB に引き上げてファイルチャーンを抑えてください。

---

---

## F6: LMDB ネイティブモード自動移行（AutoSwitch）

Tsunagi は LMDB ストアの収束を検出すると、安全に `lmdb_native` モードへ自動移行する仕組みを備えています。
この設計は、セキュアな systemd サンドボックス構成を維持しながら、自律的にフルノード化へ移行することを目的としています。

### アーキテクチャ概要

#### ノード本体（サンドボックス内）

- `truth_ratio >= 0.999`
- fallback が 10 分以上増加していない

上記条件を満たすと、次のマーカーファイルを生成します：

`$TSUNAGI_HOME/native_ready.json`

このファイルは「ネイティブモードへ移行可能」であることを示します。
（ノード本体は systemd 設定を直接変更しません。セキュリティ分離を維持するためです。）

#### autoswitch-apply.timer（非サンドボックス）

5 分ごとに実行され、次を行います：

- `native_ready.json` の存在を確認
- `TSUNAGI_AUTOSWITCH=1` が設定されている場合のみ適用
- systemd drop-in を生成：

`~/.config/systemd/user/tsunagi-mainnet.service.d/99-native.conf`

drop-in 内容：

- `TSUNAGI_LMDB_TRUTH=1`
- `TSUNAGI_LMDB_AUTHORITY=1`
- `TSUNAGI_MODE=lmdb_native`

その後、`daemon-reload` と `restart` を実行します。

### セキュリティ思想

- ノード本体は `ProtectHome=true` のサンドボックスで動作
- 設定変更は分離されたタイマーサービスのみが実行
- 明示的に `TSUNAGI_AUTOSWITCH=1` が必要
- 監査可能なマーカー方式（native_ready.json）

Tsunagi は「勝手に危険な変更を行わない」設計です。

### 有効化手順（例）

example ファイルをコピー：

```bash
mkdir -p ~/.config/systemd/user
cp ops/systemd/autoswitch-apply.service.example ~/.config/systemd/user/autoswitch-apply.service
cp ops/systemd/autoswitch-apply.timer.example ~/.config/systemd/user/autoswitch-apply.timer
systemctl --user daemon-reload
systemctl --user enable --now autoswitch-apply.timer
```

確認：

```bash
systemctl --user list-timers --all | grep autoswitch-apply
```

### 収束確認

`/metrics` から確認できます：

- `tsunagi_lmdb_truth_blocks_total`
- `tsunagi_lmdb_fallback_blocks_total`
- `tsunagi_lmdb_truth_ratio`

`truth_ratio` が 1.0 に近づき、fallback が停止すれば収束状態です。

---

## ライセンス

MIT

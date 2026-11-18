# Contributing

## 日本語

参加歓迎です。日本語ファーストで、ゆっくり丁寧に進めます。  
コードだけでなく、文章・翻訳・UXの協力も大切です。  

役割:
- エンジニア
- ドキュメント / 翻訳
- UX / 体験づくり

行動の雰囲気:
- 落ち着いて、礼儀正しく
- 初心者にやさしく
- 相手を尊重する

## English

Contributions are welcome. We are Japanese‑first and move calmly.  
We value docs, translation, and UX as much as code.  

Roles:
- Engineers
- Docs / Translation
- UX / Experience

Tone:
- Calm and respectful
- Kind to beginners
- Respect each other

## Practical notes / 実務メモ

**Build and test.** See [`BUILD.md`](BUILD.md). Please run `zig build` and `zig build test`
in `tsunagi-node/` with the Zig version in `tsunagi-node/zig.version` before opening a pull
request, and say in the PR what you ran and what happened, including failures.

**Licensing of contributions.** Unless you state otherwise, anything you submit for
inclusion is licensed under **MIT OR Apache-2.0**, the same as the project
(see [`LICENSE`](LICENSE)), with no additional terms. Only submit work you have the right
to license this way. If you bring in third-party code, keep its license and copyright
notices and add it to [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

**History.** Changes land as ordinary forward commits. Please do not ask for published
history to be rewritten to tidy it; failed experiments, incident records and audit findings
stay in the record.

**Other implementations.** Comparisons with `cardano-node`, Amaru, Dingo and other projects
are welcome when they are specific, sourced and technical. Credit what you learned from
them. No disparagement of projects or people.

**Secrets.** Never include keys, certificates, `forge.env`, node state or host details in
issues, pull requests or test data. See [`SECURITY.md`](SECURITY.md).

**Readiness claims.** Keep "implemented", "integrated", "tested", "independently accepted"
and "deployed" separate, as in [`docs/REVIEW-GUIDE.md`](docs/REVIEW-GUIDE.md).

日本語:ビルドとテストは [`BUILD.md`](BUILD.md) を参照してください。コントリビューションは、
特に明記がない限りプロジェクトと同じ **MIT OR Apache-2.0** で提供されたものとして扱います。
第三者のコードを含める場合は、そのライセンス表記を保持し
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) に追記してください。履歴は通常のコミットで
前に進め、公開済みの履歴は書き換えません。他の実装との比較は、具体的で出典のある技術的な
内容に限り歓迎します。鍵・証明書・ノード状態・ホスト情報は決して含めないでください。

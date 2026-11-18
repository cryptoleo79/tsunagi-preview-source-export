# Source export

This repository is a **source export** of TSUNAGI's October 2026 Preview follower. Its Git
history was created for publication. It is not the project's original development history,
which is not part of this repository.

Maintained by A$Y (Tsunagi Project). Independent conformance review is welcome.

## What the commits are

| Commit | Content |
|---|---|
| `8b80c3b7f35dd16afca611cbef1c38ed19869999` (tag `october-2026-follower-source`) | The source of original commit `4cdcde42d5cd5f097e50bf5212db671b25ee6947`, from which the October 2026 follower binary was built, with the differences listed below. |
| Later commits on `main` | Publication material added on top: build guide, review guide, source/release map, security policy, third-party notices and license texts, the CI workflow, and the corrected `tsunagi-node/zig.version`. No file under `tsunagi-node/src`, `tsunagi-node/tools` or `tsunagi-node/build.zig` is changed. |

## Differences from the original commit

The export commit is **not byte-identical** to the original commit. It differs as follows.

- **Omitted:** 27 submodule entries that held no files.
- **Omitted files (18):** 13 files under `tsunagi-node/rehearsal-archive/` (six compiled
  executables from May 2026 rehearsals, with their notes and fingerprint lists), two
  internal process documents, and two image files (one of them stored at two paths). The
  website page `tsunagi-node/web/index.html` and its copy under `web/site/` still refer to
  one omitted image.
- **Edited source comments (2 lines):** the text of one comment line in
  `tsunagi-node/src/producer/keys.zig` and one in `tsunagi-node/src/producer/producer.zig`.
  No code, identifier or string literal is changed, and the line count of both files is
  unchanged.
- **Edited documents:** wording in four documents under `tsunagi-node/docs/` and in two
  website pages under `tsunagi-node/web/`.
- **Added:** [`CREDITS.md`](CREDITS.md).

All other files (597 of the 623 in the original commit) are byte-identical to it.

## Mapping to the published binary

| | |
|---|---|
| Binary | `tsunagi-preview-v2026.10.05-linux-x86_64`, release `v2026.10.05-preview-portable-x86_64` in [`cryptoleo79/tsunagi-preview`](https://github.com/cryptoleo79/tsunagi-preview) |
| Binary SHA-256 | `4919985711adbf8f59b07839752e605ac3d98d1df35a42f5f93ab2ff3985e08e` |
| Original source commit (embedded in the binary; not in this repository) | `4cdcde42d5cd5f097e50bf5212db671b25ee6947` |
| Original source tree (stated in the release's provenance manifest) | `02f603b30246da84d3cf9793162956a015ea8e00` |
| Export commit | `8b80c3b7f35dd16afca611cbef1c38ed19869999`, tree `a515d49c875840e0808cdd180dd7e378094ecd48` |

Git object ids of the parts the build reads:

| Path | Original commit | Export commit and tip of `main` |
|---|---|---|
| `tsunagi-node/src` | `9f395575f385cd5a225f5e7b1d7029884f255133` | `8acf4d75ebbd5691556642ca27170af9a2bb75c8` (two comment lines differ) |
| `tsunagi-node/tools` | `209e6d3b80cb6cba5cbddf1f110adbcd4af60f2a` | same |
| `tsunagi-node/build.zig` | `8c28479ae199d113bd3403057c37010ee7b07fc4` | same |
| `tsunagi-node/scripts` | `c1e37f58f7c9335514ccdd5096e4ca0f5196b55c` | same |
| `scripts` | `5478e00e7b8f6dfda2f86a4547849e6cc2613fdc` | same |

Check the export side with `git rev-parse <commit>:<path>`.

## How to check the source against the binary

Build the export commit with the command in
[`BUILD.md`](BUILD.md#reproduce-the-october-2026-follower-executable) and compare the
SHA-256 with the published binary.

What has been done: on 2026-11-18 the **original** commit was rebuilt on a different host
and the result was byte-identical to the published executable. **The export commit has not
been rebuilt or tested.** Because two source comments differ, an identical binary hash is
not claimed. If you build it, please report the result either way.

## What the export does not contain

- The original commits, their messages, authorship metadata, branches and tags. Co-author
  credits recorded there are carried forward in [`CREDITS.md`](CREDITS.md).
- Earlier states of the source, including the June 2026 producer's candidate source.
- Files that existed only in earlier commits, and the files listed as omitted above.

License and notices are unchanged: MIT OR Apache-2.0 ([`LICENSE`](LICENSE),
[`NOTICE`](NOTICE)), with third-party material listed in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

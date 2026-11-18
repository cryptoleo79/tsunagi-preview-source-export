# Build and test

How to build `tsunagi-node` from this source, run its tests, and reproduce the October 2026
Preview follower executable. For which binary corresponds to which commit, see
[`docs/SOURCE-RELEASE-MAP.md`](docs/SOURCE-RELEASE-MAP.md).

This is Preview evaluation software. Building it does not make it suitable for Mainnet,
stake-pool or production use.

## Requirements

| Input | Pin | Notes |
|---|---|---|
| OS / arch | Linux x86-64, glibc ≥ 2.34 | Checked on Ubuntu 22.04.5 (glibc 2.35). Other platforms are not covered here. |
| Zig | **0.16.0** (`tsunagi-node/zig.version`) | Official tarball SHA-256 `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`; `zig` executable SHA-256 `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c` |
| LMDB | `liblmdb-dev` (0.9.24 checked) | Distribution package |
| libsodium **with the VRF extension** | `IntersectMBO/libsodium`, branch `draft-irtf-cfrg-vrf-03` (commit `b397839b58ccfd09dde2191c7e1b67d47184f6b0` on 2026-11-18), installed under `/usr/local` | The stock distribution libsodium lacks `crypto_vrf_ietfdraft03_*` and will not link. |
| C toolchain | `build-essential`, `autoconf`, `automake`, `libtool`, `pkg-config` | Only to build libsodium |
| Zig packages | none | There is no `build.zig.zon`; the build fetches nothing. |

`build.zig` adds `/usr/local/include` and `/usr/local/lib` to the search paths, and the
resulting executable has RUNPATH `/usr/local/lib`.

The original build host's exact libsodium and LMDB builds were not recorded. Both are linked
dynamically. The rebuild described below matched the published bytes using its own host's
libraries: Ubuntu's `liblmdb` 0.9.24 and an existing `/usr/local` install of libsodium
1.0.18 with the VRF extension, whose exact source commit was not recorded either. The pinned
libsodium commit above is what CI uses; it was not the library on the rebuild host for that
first rebuild. A second local rebuild on 2026-11-18 — of a checkout whose node source is
tree-identical to the original commit — used the pinned commit, installed under
`/usr/local`, and also matched the published bytes. With the same library
installed under a different prefix the result was not byte-identical, because the prefix is
embedded in the executable's library search path.

## Install the dependencies

```sh
sudo apt-get update
sudo apt-get install -y liblmdb-dev autoconf automake libtool pkg-config build-essential git ca-certificates xz-utils

# libsodium with VRF, pinned
mkdir /tmp/libsodium && cd /tmp/libsodium
git init -q
git remote add origin https://github.com/IntersectMBO/libsodium.git
git fetch -q --depth 1 origin b397839b58ccfd09dde2191c7e1b67d47184f6b0
git checkout -q FETCH_HEAD
./autogen.sh -f && ./configure --prefix=/usr/local && make -j"$(nproc)"
sudo make install && sudo ldconfig

# Zig 0.16.0, verified
cd /tmp
curl -fsSLO https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  zig-x86_64-linux-0.16.0.tar.xz" | sha256sum --check
tar -xf zig-x86_64-linux-0.16.0.tar.xz
export PATH="/tmp/zig-x86_64-linux-0.16.0:$PATH"
zig version   # 0.16.0
```

## Build

```sh
cd tsunagi-node
zig build -j1 -Dcpu=baseline -Doptimize=ReleaseSafe
./zig-out/bin/tsunagi-node --version
```

This also builds `plutus-evaluator`, `praos-verify` and `tsunagi-slot-index-reset`.
`--version` works offline and prints the embedded version, commit, build mode and target.

`-j1` keeps memory use low and matches the release procedure. A clean build took about three
minutes on one core.

## Test

```sh
cd tsunagi-node
zig build test -j1 -Dcpu=baseline -Doptimize=ReleaseSafe --summary all
```

Recorded result for the original source commit `4cdcde42` on 2026-11-18 (Ubuntu 22.04.5, the
pins above). This export differs from that commit as listed in
[`SOURCE-EXPORT.md`](SOURCE-EXPORT.md); the tests have not been re-run on the export:

```text
Build Summary: 73/73 steps succeeded; 1506/1506 tests passed
```

Exit status 0, about nine minutes on one core. Four test executables print diagnostic lines
to standard error (for example `KES_CRITICAL: …` from tests that exercise that warning). Zig
shows such output under a `failed command:` heading even though the step succeeded. The
summary line and the exit status are the result.

These are unit tests and in-process protocol tests. They do not connect to a network, and
passing them is not a conformance result. Tests for Preview interoperability, block
production and recovery were run by the maintainer on live infrastructure and are recorded
as documents under `tsunagi-node/docs/`; they are not reproduced by this command.

## Reproduce the October 2026 follower executable

Published artifact: `tsunagi-preview-v2026.10.05-linux-x86_64`, SHA-256
`4919985711adbf8f59b07839752e605ac3d98d1df35a42f5f93ab2ff3985e08e`.

```sh
git checkout october-2026-follower-source      # export commit 8b80c3b7f35dd16afca611cbef1c38ed19869999
cd tsunagi-node

zig build \
  -j1 \
  -Dcpu=baseline \
  -Doptimize=ReleaseSafe \
  -Dversion=v2026.10.05-preview-portable-x86_64 \
  -Dcommit=4cdcde42d5cd5f097e50bf5212db671b25ee6947 \
  -Dtsunagi_git_tag=v2026.10.05-preview-portable-x86_64 \
  -Dtsunagi_source_dirty=false \
  -Dtsunagi_build_epoch=0

objcopy --strip-debug zig-out/bin/tsunagi-node tsunagi-preview-v2026.10.05-linux-x86_64
sha256sum tsunagi-preview-v2026.10.05-linux-x86_64
```

Check out that tag. It holds the source of the original commit `4cdcde42`, whose id the
binary embeds, with the differences listed in [`SOURCE-EXPORT.md`](SOURCE-EXPORT.md); that
is why the command passes `-Dcommit=4cdcde42…` although the commit itself is not in this
repository. Later commits on `main` change documentation and repository metadata only.

Observed on 2026-11-18, for the original commit: a clean export of it, an empty cache, a
different host, user and directory from the original build, GNU objcopy 2.38 — the result
was **byte-identical** to the published executable (5,798,056 bytes, same SHA-256).

The export commit is not byte-identical to the original commit: among the listed
differences, the text of two source comments is edited. It has not been rebuilt, and
whether a build of it produces the published SHA-256 has not been checked.

If your result differs, please report the Zig executable hash, `objcopy --version`, the
distribution, and the SHA-256 you got. A mismatch is useful information.

## The June 2026 producer executable

It cannot currently be reproduced: its source commit, working-tree state and build flags were
not recorded. See the gaps listed in
[`docs/SOURCE-RELEASE-MAP.md`](docs/SOURCE-RELEASE-MAP.md).

## Running

Run on Preview only, in observe mode first, with a dedicated empty state directory:

```sh
export TSUNAGI_HOME="$HOME/.local/state/tsunagi-preview"
mkdir -p "$TSUNAGI_HOME"
TSUNAGI_FORGE_ENABLE=0 ./zig-out/bin/tsunagi-node run --net preview --lang en --peer PREVIEW_PEER_HOST:PORT
```

Do not point it at another node's state directory, and do not supply pool keys unless you
intend to test block production on Preview with keys you control.

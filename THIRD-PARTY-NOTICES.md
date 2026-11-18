# Third-party notices

TSUNAGI's own source is licensed under **MIT OR Apache-2.0** (see [`LICENSE`](LICENSE),
[`LICENSE-MIT`](LICENSE-MIT), [`LICENSE-APACHE`](LICENSE-APACHE), [`NOTICE`](NOTICE)). That
choice does not cover the third-party material listed here, which stays under its own terms.

This list describes the tree of the October 2026 Preview follower source (original commit
`4cdcde42`) plus its build and run-time dependencies. Other lines of TSUNAGI work, which
are not in this repository, carry additional third-party material with their own notices;
they are not covered by this file.

## In this tree

| Path | Origin | License |
|---|---|---|
| `tsunagi-node/scripts/haskell/praos-threshold-oracle/NonIntegral.hs` | Copied from `IntersectMBO/cardano-ledger`, `libs/non-integral/src/Cardano/Ledger/NonIntegral.hs`; only the module name is changed (stated in the file header) | Apache-2.0 |
| `tsunagi-node/scripts/haskell/praos-threshold-oracle/Main.hs` | TSUNAGI code; arithmetic follows `cardano-ledger` `BaseTypes.hs` as cited in the file | MIT OR Apache-2.0 |
| `tsunagi-node/evidence/`, alignment and regression vectors under `tsunagi-node/` | The maintainer's own forged-block artifacts, and blocks, headers and transactions recorded from the public Cardano Preview network | TSUNAGI material and public chain data; no third-party license applies |

No other third-party source files were identified in this tree. There are no Zig package
dependencies and no vendored C libraries at this commit.

## Compiled into the binaries

| Component | Origin | License |
|---|---|---|
| Zig standard library and compiler runtime (`compiler_rt`) | <https://ziglang.org> | MIT. Copyright (c) Zig contributors. Full text: [`third-party-licenses/ZIG-LICENSE.txt`](third-party-licenses/ZIG-LICENSE.txt) |
| Routines in that runtime which the Zig sources mark as ported from musl libc (for example the `cos`, `exp` and `log` implementations) | <https://musl.libc.org> | MIT. Copyright © 2005-2020 Rich Felker, et al. Full text: [`third-party-licenses/MUSL-COPYRIGHT.txt`](third-party-licenses/MUSL-COPYRIGHT.txt) |

Every executable the Zig compiler produces contains compiled code from the Zig standard
library and compiler runtime. The MIT license requires its copyright and permission notice
to accompany copies, so the two texts above are kept in this repository.

This repository contains no compiled executables. The texts apply to the separately
published Preview binaries, which are not stored here, and to any executable built from
this source. The October 2026 follower was built with Zig 0.16.0. Ship both texts with
binary releases.

`ZIG-LICENSE.txt` is the `LICENSE` file of the Zig 0.16.0 distribution.
`MUSL-COPYRIGHT.txt` is `lib/libc/musl/COPYRIGHT` from the Zig 0.16.0 distribution. Both
are unmodified copies.

Dynamically linked executables also contain the small glibc startup objects that Zig
builds from the glibc sources it bundles; see the license headers of those files under
`lib/libc/glibc/` in the Zig distribution. Other components bundled with Zig carry their
own notices there.

## Linked at run time (not distributed here)

| Library | Origin | License |
|---|---|---|
| libsodium with the VRF extension (`draft-irtf-cfrg-vrf-03` branch) | <https://github.com/IntersectMBO/libsodium>, a fork of <https://github.com/jedisct1/libsodium> | ISC |
| LMDB (`liblmdb`) | <https://www.symas.com/lmdb> | OpenLDAP Public License 2.8 |
| GNU C Library | <https://www.gnu.org/software/libc/> | LGPL-2.1-or-later |

## Names and trademarks

Cardano, `cardano-node`, Amaru, Pallas, Dingo, gOuroboros and other project names are used
in this repository only to identify those projects, cite their specifications and source,
or describe interoperability tests. No affiliation or endorsement is implied.

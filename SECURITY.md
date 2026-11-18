# Security

## Scope

TSUNAGI is evaluation software for the Cardano **Preview** testnet. This repository is the
source for the public Preview binaries listed in
[`docs/SOURCE-RELEASE-MAP.md`](docs/SOURCE-RELEASE-MAP.md). It is not qualified for Mainnet,
stake-pool or production use. Public source access does not change that.

## Reporting a vulnerability

Please report security issues privately before opening a public issue.

- Use GitHub's **Report a vulnerability** button on this repository's *Security* tab
  (private vulnerability reporting).
- Include the commit or binary SHA-256, reproduction steps, and the impact you observed.

You will get an acknowledgement, and disclosure timing will be agreed with you. There is no
bug bounty. Findings against other Cardano implementations should go to those projects.

Ordinary conformance differences (TSUNAGI accepts or rejects something `cardano-node` does
not) are welcome as public issues unless they let a remote peer crash, stall or corrupt a
node, in which case please report privately.

## Keys are yours, and only yours

- TSUNAGI **never ships keys**. Operators generate and supply their own pool keys
  (cold / VRF / KES) and operational certificate.
- **Never commit keys, certificates, counters, seed material or `forge.env`** to any
  repository, issue or pull request. Test vectors must use published or freshly generated
  throwaway keys, and say so.
- Keep the cold signing key offline, not on the producing host.

## What was and was not checked before publication

Before this source was prepared for public review (2026-11-18), every file version reachable
from every branch, tag and pull-request ref of the original private repository, commit and tag messages,
issue and pull-request text, retained CI logs and published release assets were scanned with
pattern-based checks for private keys, Cardano signing-key envelopes, access tokens,
credentials in URLs, and key-like hex assignments. None were found.

That scan is pattern-based. It cannot prove the absence of a secret in an unusual encoding
or inside compressed or binary content. If you find something that looks like live key
material or a credential anywhere in this repository or its history, report it privately as
above.

## Verifying a download

Binaries are distributed from `cryptoleo79/tsunagi-preview`. Verify the SHA-256 against
[`docs/SOURCE-RELEASE-MAP.md`](docs/SOURCE-RELEASE-MAP.md) before running, and see
[`BUILD.md`](BUILD.md) to rebuild the October 2026 executable from source.

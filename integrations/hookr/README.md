# Hookr source-review draft

`manifest.json` follows the external-hook V2 files published in Hookr contracts PR 3 at revision `2b0ee64ed85a2d47037efebb8de144cafa23054e`.

This is a source-only standalone external hook draft. It claims multi-pool behavior, the `afterSwap` return-delta flag, local exact-input PoolManager tests, and explicit exact-output rejection. It has one immutable product-owned executor as a trusted custody boundary. This executor is not a Hookr ABI. The source does not implement live external swaps or claim native-block composition, a deployment, an audit, Hookr approval, or production approval.

The schema requires an immutable source commit. The current source is not committed, so the manifest temporarily uses repository `HEAD` (`eb39179cb0e97dffdde1dddfdab8cad444f13612`). The full local validator must fail because that commit does not contain the new contracts. After the source is committed and pushed, update `source.pinnedCommit` and the route evidence URLs before submission.

The validator unit suite can check the pinned PR schema and semantic rules without bypassing the full command's immutable-source check.

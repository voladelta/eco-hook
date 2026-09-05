# Hookr source-review draft

`manifest.json` follows the external-hook V2 files published in Hookr contracts PR 3 at revision `2b0ee64ed85a2d47037efebb8de144cafa23054e`.

This is a source-only standalone external hook draft. It claims multi-pool behavior, the `afterSwap` return-delta flag, local exact-input PoolManager tests, and explicit exact-output rejection. It has one immutable product-owned executor as a trusted custody boundary. This executor is not a Hookr ABI. The source does not implement live external swaps or claim native-block composition, a deployment, an audit, Hookr approval, or production approval.

The separate V6 review is pinned in `v6-review-source.json` and documented in
`../../docs/hookr-v6-compatibility-review.md`. It does not replace this manifest's schema or source
pin. The review found that the current V6 coordinator accepts Hookr modular roots, not this
standalone root, and exposes no typed Eco module path. The selected integration is a new typed
stateful module under the Hookr root, not an external-root lane.

The manifest pins source commit `a5f9ebd3da28911bc8d99194126869cab38eca64` and links each source-tested route to the immutable PoolManager integration test. The full local validator checks the pinned PR schema, semantic rules, and committed contract source.

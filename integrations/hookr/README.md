# Hookr source-review draft

`manifest.json` follows the external-hook V2 files published in Hookr contracts PR 3 at revision `2b0ee64ed85a2d47037efebb8de144cafa23054e`.

This is a source-only standalone external hook draft. It claims multi-pool behavior, the `afterSwap` return-delta flag, local exact-input PoolManager tests, and explicit exact-output rejection. It has one immutable product-owned executor as a trusted custody boundary. This executor is not a Hookr ABI. The source does not implement live external swaps or claim native-block composition, a deployment, an audit, Hookr approval, or production approval.

The current modular release assessment is pinned in `current-review-source.json` and documented in
[`hookr-current-compatibility-review.md`](../../docs/hookr-current-compatibility-review.md).
`v6-review-source.json` preserves the earlier historical review. Neither replaces this standalone
manifest's schema or source pin. The latest coordinator requires Native Mechanics V2 under an
admitted Hookr root. Eco's typed read-only policy and stateful claim strategies remain a candidate
for a new production profile.
The [local integration suite](../hookr-local/README.md) now demonstrates preparation and combined
settlement through a new test profile, plus a pinned Universal Router fork. Production client
integration and admission remain outstanding.

Run `node scripts/validate-hookr-review.mjs ../hookr-modular-hooks` from the Eco repository root
to check the current checkout, all 41 upstream manifest sources, and Eco's reviewed interface files.
The checker verifies source identity, not deployed admission or runtime compatibility.

The manifest pins source commit `a5f9ebd3da28911bc8d99194126869cab38eca64` and links each source-tested route to the immutable PoolManager integration test. The full local validator checks the pinned PR schema, semantic rules, and committed contract source.

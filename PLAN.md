# Hookr integration order

1. Agree the launch, registry and router interfaces with Hookr.
2. Build the reusable Eco hook, pool registry, vault factory and order hub.
3. Test instant launches and auction migrations through a Hookr adapter.
4. Publish the reviewed Eco Basket hook for selection on Hookr.
5. Launch `HOOKRECO` through Hookr with Eco Basket selected.
6. Run `HOOKRECO` as a production canary with strict spending limits.
7. Open the reviewed hook to other Hookr creators.
8. Add Eco Basket as a typed Hookr block if the compiler supports it.

The final decision is:

> Hookr creates each token and its canonical pool. The creator selects Eco Basket during the Hookr launch. Eco Basket then manages the pool's fee strategy, basket and vault.

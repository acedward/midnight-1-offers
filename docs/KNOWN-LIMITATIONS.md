# Known limitations

> **Scope.** This file currently records the limitations of the **`shielded-night`** profile.
> The other profiles' entries land with 00005 P6.

## `shielded-night`

### The browser flow needs the DEFAULT port block

Lace resolves the `undeployed` network to fixed endpoints — `127.0.0.1:9944` (node),
`:8088` (indexer), `:6300` (proof server) — and offers no way to be told otherwise. A stack
brought up on a generated port block (`./scripts/pick-ports.sh`) is therefore invisible to it,
and the page will connect to a wallet that is looking at a different chain, or at nothing.

**This profile has no override lane for it, and cannot have one.** The page never learns those
URLs from us: the wallet supplies them through the dApp connector's `getConfiguration()`. That
is what makes the profile port-agnostic in every other respect — only the contract address is
injected — and it is also why the browser flow is pinned to the default ports.

The automated verification is unaffected: `./verify.sh`'s round trips run inside the compose
network against service hostnames, on any port block.

This limitation is shared with the `frontend` (zswap-da) profile.

### The wallet must implement `getProvingProvider`

The page refuses to connect to a `window.midnight` wallet that does not implement the
dApp-connector 4.x `getProvingProvider`. This is a design decision upstream, not a gap: the
dApp hands the wallet the contract's ZK key material and the **wallet** proves, inside its own
trust boundary. A dApp that named its own proof server could send the private witness to a
prover the user never chose.

The consequence is that wallet support is version-dependent, and the page surfaces its own
explicit error ("This wallet does not support dApp proving yet") rather than failing obscurely.
`./verify.sh` cannot see this at all — it exercises the contract through the Node-side harness,
not through a browser — so the wallet requirement is documented here rather than asserted.

Upstream's live Preview deployment depends on this call, which is evidence that a current Lace
build implements it. Whether the same build also serves `undeployed` **with** proving
delegation is measured at the hand test; record what you observe here.

### The reverse conversion only works for coins minted in that browser

sNight → NIGHT in the page works only for wrapper coins minted **in this browser's session
storage**. The dApp connector exposes shielded balances in aggregate only — it does not hand
back the individual coin objects (`{nonce, color, value}`) a burn circuit needs — so the page
keeps the coins it minted itself in `localStorage` and can only spend those.

Consequences, all upstream and none fixed here:

* clearing site data, or opening the page in another browser or profile, loses the ability to
  unwrap coins that wallet still holds (the NIGHT is not lost — the contract still backs the
  credit — but that browser cannot build the burn);
* sNight **received from someone else** cannot be unwrapped in the page.

The Node-side harness has no such limit: it discovers coins from the wallet's own synced state,
which is why `./verify.sh`'s round trips exercise the full unwrap path that the browser cannot.

### The verify driver is the deployer's wallet (`genesis-2`)

`SHIELDED_NIGHT_DRIVER_SEED` defaults to `genesis-2` — the seed the deploy one-shot used. That
is safe rather than sloppy: `shielded-night-deploy` is `restart: "no"`, so it has published
`contract.json` and exited long before `./verify.sh` opens a wallet, and the hazard this
repository documents (two facades on one seed forcing each other's connection down) needs two
*concurrent* facades.

What this replaced is worth knowing, because it removes a rule: until project 00007 phase D′
the driver was the `lace-test` seed, and running `./verify.sh --shielded-night` while a Lace
session was connected on that wallet was a real collision. **That rule is gone** — nothing in
this profile touches `lace-test` any more, so the browser hand test and the automated gates can
overlap freely. (Owner decision, project 00007 question Q6 → D.)

The residual limit is unchanged in kind: `genesis-2` must stay a wallet with no long-lived
container facade. If a future profile wants it, give that profile its own seed — or give this
one a dedicated driver plus a NIGHT + DUST provisioning lane, which this repository still does
not have (the 2.x sibling's `scripts/fund-wallet.sh` is the shape it would take).

**A related timing note (measured, phase G, 2026-09-03):** the deploy one-shot's own
DUST-paying transaction and the round trip's first DUST-paying transaction both come from
`genesis-2`, back to back. Run `./verify.sh --shielded-night` (or `verify-shielded-night.sh`
directly) TOO SOON after the stack finishes coming up, and the round trip can be rejected on
chain with `1010: Invalid Transaction: Custom error: 196`
(`DustDoubleSpend(DustNullifier(...))`, visible in `docker compose … logs node`) — a real
on-chain rejection, not a flaky test, and it reproduces deterministically until enough time
passes for `genesis-2`'s DUST to settle after the deploy. A few minutes' gap (which a
bring-up that also builds the `frontend` profile gets for free) is enough; retrying the SAME
`./verify.sh` invocation after a short pause resolves it. This is a property of chaining two
DUST-spending actions on one wallet in quick succession — upstream's own test suite, and this
repository's choice to reuse `genesis-2` for both roles (Q6 → D) — not something this profile's
image or scripts can fix without either patching upstream (out of scope, Q2 → A) or adding a
wait nobody asked for to every bring-up.

### The relay and the COW solver cannot quote an sNight pair

The `solver` profile's COW solver quotes from inventory it actually holds, and its provisioning
one-shot mints it only the offer-files demo colours. sNight exists **only** by wrapping native
NIGHT through the ShieldedNight contract, which that profile knows nothing about — so an sNight
offer can never appear in the solver's ladder and the relay will not broker a fill for it.

This costs nothing today, because taking an Offer File needs no intermediary: the maker's
transaction is deliberately unbalanced, and a taker balances it, claims the give leg, pays the
want leg and submits. That is what `./verify.sh`'s book subsection does, and the kernel
certifies the outcome (the offer reaches `consumed`, i.e. its input nullifier was spent on
chain). With the `solver` profile up the section says so and takes the offer directly anyway.

Teaching the solver to hold sNight would mean coupling it to a profile that must depend only on
`core`. Recorded as question Q12 of project 00007.

### The page also offers the live Preview and PreProd networks

Upstream's committed `frontend/.env` carries the real Preview and PreProd contract addresses, so
the network dropdown lists both alongside *Local (undeployed)*. That file is upstream's and this
image applies no patch, so the entries stay. Selecting either talks to that public network
through your wallet and has nothing to do with this stack; nothing here can or should be
transacted from a demo stack.

### The demo faucet colours (DEVA/DEVB/DEVU) are, and stay, UNPRICED

Kernel `main`'s sponsorship gate (PR #54/#56) prices offers against a reference-asset table.
sNight is registered priced (`asset_id: midnight-3`, the same reference as native NIGHT — see
`docs/COMPONENTS.md`), but DEVA/DEVB/DEVU — minted fresh on every clean redeploy, by colour —
have no real-world reference asset and are deliberately left out of `PRICE_FEED_MAP`
(`.env.example`): mapping them to a fabricated price would be worse than leaving them unpriced.

This is only safe because the default policy is `BATCHER_SPONSOR_POLICY=warn` +
`BATCHER_SPONSOR_UNPRICED=allow`. If a future change flips the policy to `enforce` WITHOUT also
keeping `BATCHER_SPONSOR_UNPRICED=allow`, every offer using a demo colour — which is most of
what this stack posts, including the `book` subsection's `WANT` leg — starts refusing with
`422 NOT_SPONSORED`. This repository does not turn `enforce` on for exactly this reason.

### The kernel seeds a PREVIEW sNight colour into every fresh database (kernel #61)

Since `KERNEL_REF=c293ebd…`, the kernel's `packages/database/migrations/000-init.sql` seeds a
`SNIGHT` row at `793c29c9…` — the colour derived from shielded-night's **preview** contract. That
colour cannot exist on an `undeployed` devnet, where this stack deploys its own wrapper contract
and derives a different colour on every clean bring-up.

`known_tokens.name` is UNIQUE and `POST /v1/known-tokens` upper-cases the posted name **and
checks the name before the colour**, so the seeded row holds `SNIGHT` against a colour with no
supply on this chain, and this stack's real sNight colour cannot be registered under its own
name. Left alone, the failure is silent: every registration path treats a 409 as "already
registered".

`up.sh` works around it — the one-shot exits **75** when the name is held by a different colour,
`up.sh` deletes the row by name and re-runs the one-shot once (see `docs/OPERATIONS.md`). Both
steps log. **What remains a limitation**: the workaround runs only when BOTH `offerfiles` and
`shielded-night` are up, so on an `--with offerfiles`-only stack the phantom `SNIGHT` row stays in
the registry, listed by `GET /v1/known-tokens` and priceable, for a colour nothing on this chain
holds. It is harmless (no offer can reference it) but it is visible in the SPA's token list.

The upstream fix — stop seeding the row and let `price-map.ts`'s `SNIGHT` NAME entry price it
wherever it is registered — belongs to the kernel repository and is recorded there, not here.

### `undeployed` only

This profile deploys to `undeployed` and refuses any other `MN_ENV`. shielded-night's Preview
contract is already live and permanently locked; deploying another one from a demo stack with a
public dev seed would be noise on a real network at best.

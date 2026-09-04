# Known limitations

> **Scope.** This file records the limitations of the **`solver`** and **`shielded-night`**
> profiles. The other profiles' entries land with 00005 P6.

## `solver`

### The monitor's relay panel is empty until the solver publishes a ladder

`solver-frontend` reads the relay's `GET /tokens`, which is the union of what **connected
solvers advertise** — not a registry. So on a cold stack the relay panel is empty and the
published-ladder block says so, for a window that lasts until `solver-provision` and
`maker-offer` have both completed and the solver has mirrored the book and pushed once. That is
minutes on a cold host, and it is the *correct* rendering of that state rather than a fault; the
health strip's last two stages (relay socket, published ladder) are what say which half is still
missing. `./verify.sh` gives it `SOLVER_MONITOR_BUDGET_S` (180 s, spec SC-004's own budget)
before failing.

The same is true, permanently, of a stack brought up with `MAKER_OFFER_ENABLED=false` or
`SOLVER_PROVISION_ENABLED=false`: the ladder is derived from the book, so with nothing to quote
an empty publication is honest and the panel stays empty.

### The seeded maker offer does not survive a long run, and `./verify.sh` re-seeds

An offer on this chain lives `min(ROOT_WINDOW_SECONDS, OFFER_TTL_SECONDS)` = **1 hour**, whatever
`MAKER_OFFER_TTL_MINUTES` asks for, and it is archived the moment any on-chain transaction spends
its input nullifier — a settled take, or an unrelated transfer from the maker's own wallet that
selects the coin the offer reserved. Both happen on a full `./up.sh --all` + `./verify.sh` run.

The `solver` section therefore **posts a fresh offer** (`MAKER_OFFER_RESEED=true`) when the book
holds none, which costs a proving round of a minute or two, and reports the previous offer's
terminal status first. It is the one side effect `./verify.sh` has; `SOLVER_VERIFY_RESEED=false`
forbids it, at the price of turning an empty book into a failure. Skipping the assertions —
what this section did before 00011 — is not an option: it passed the section without testing it.

### The status port is not published, by design

`/status/*` carries the solver's entire internal state, so `:9100` is reachable only from inside
the compose network and only with the bearer. Reading it from the host needs `docker compose
exec` (the idiom is in `docs/OPERATIONS.md`) or uncommenting the `SOLVER_STATUS_HOST_PORT` block
in `compose/solver.yml`. The monitor on `:10800` is the intended reader.

## `poster`

### The first offer takes minutes, and nothing can make it faster

Before the poster's health server even binds, it has to sync a wallet, register its NIGHT for
DUST, wait (bounded) for that dust to appear, and join the offer-files contract; then the first
tick mints a coin, which is a proving transaction (~30 s), waits for the coin to become visible,
and only then builds and posts the offer. That is why the container healthcheck has a 15-minute
`start_period` and why `./verify.sh`'s poster section carries `POSTER_VERIFY_BUDGET_S` (420 s by
default) instead of a fixed wait. On a loaded host, raise it rather than reading a red section
as a defect.

### `degraded` answers **200**, on purpose

`GET /health` returns 200 while the poster is `starting` and while it is `degraded`; a 503
arrives only after `HEALTH_STALE_TICKS` consecutive FAILED ticks. `degraded` almost always means
`insufficient_dust`, i.e. the wallet has no NIGHT — and restarting a poster does not produce
NIGHT, so failing the healthcheck would only produce a restart loop that hides the cause.

The consequence is that **a healthy poster container is not evidence that anything was ever
posted.** Only the mint and live-offer counters are, which is what `./verify.sh` asserts.

### One poster per stack, and one seed for it alone

`offer-poster` must never be scaled past one replica: two facades on one seed against one node
force each other's connection down. The poster enforces the seed half itself (exit 78 if
`OFFER_POSTER_SEED` matches another seed in its environment) but nothing can enforce the replica
half, so it is a rule rather than a check.

### A poster on the book changes what `verify-solver.sh` can assume

The `solver` section's exact-quote assertion used to be able to treat "the book" as "the seeded
maker offer". With a poster running that is false, and the section was rewritten for it (00011
FR-014): it identifies the maker offer by the content hash the one-shot's marker records, reads
that offer's own legs from the kernel, and re-seeds when THAT offer is not live rather than when
the book is empty. Anything new that asserts on the book must do the same.

The two profiles' offers cannot be confused for each other, incidentally: the poster mints its
give leg from a faucet preset NAME while `maker-offer` gives a colour minted from a fixed domain
separator that no preset name maps to. That is a property of the two mint paths, not a choice —
but the assertions do not rely on it.

### `./verify.sh --poster` SETTLES one of the poster's offers

The section's last assertion is a real on-chain take: `e2e-taker` is funded with NIGHT from
genesis, MINTS the demanded faucet token itself (nothing on this stack holds one until something
mints it), balances the poster's offer file and submits it. That consumes one poster offer and
leaves the taker holding what it bought. On a throwaway devnet that is the point; set
`POSTER_VERIFY_SKIP_TAKE=true` to skip it, and the section says out loud that it did.

## `prices`

### With no key the profile runs and does NOTHING — on purpose

`COINGECKO_API_KEY` has no compose default and cannot have one, so `./up.sh --all` on a clean
host brings up a `price-feed` container that logs one warning at start, one on every tick
(24 h apart), and never refreshes anything. It is not broken and it must not be "fixed" by
making it exit: under `restart: unless-stopped` a non-zero exit is a crash loop, printing the
same line forever, on a stack whose seeded prices already quote real BTC/ETH ratios. That
trade-off is upstream's and this repository keeps it.

The visible consequences are exactly two: one idle container on every key-less `--all` stack,
and `./verify.sh` reporting its `prices` section **SKIPPED**. The skip is loud, named, counted
separately and never folded into "all checks passed" — but it does mean **a key-less gate has
not tested the feature at all**. Only a run with a key proves the refresh.

### Each `./verify.sh` with a key spends one CoinGecko request

The section's first assertion is a real `--once` cycle, because nothing weaker proves a
24-hour loop works. That is one `simple/price` request per `./verify.sh` run, against the demo
plan's ~10 000 credits a month and ~30 requests a minute — so a tight loop of gate runs is the
one way to meet a `429` here. A `429` is handled gracefully (the cycle stops where it stands,
keeps what it wrote and reports in `feed.last_error`) but it will fail the section, correctly.

### `source: feed` is a sticky flag, so freshness is the real assertion

Nothing ever rewrites a `feed` row back to `seed`. A row written by an earlier run — or by
another stack against a `postgres` volume that was reused instead of wiped — still reads
`feed` days later. So `source` alone cannot answer "did the refresh work", and
`./verify.sh`'s `prices` section asserts `updated_at` against `PRICES_VERIFY_MAX_AGE_S`
(600 s) as well. The same reasoning is why `./down.sh -v` matters here as everywhere else.

### The feed has no healthcheck, so `docker compose ps` cannot tell you it is working

A loop that sleeps a day between cycles has no cheap in-container liveness signal, and the
honest question — "did the last cycle succeed" — is a database row served by the *kernel*
(`GET /v1/prices` `feed.last_error`). A process-liveness probe would call a feed that had been
failing every cycle for a week `healthy`, and a perfectly good key-less one `unhealthy`, so
the fragment declares none. `up.sh` asserts only that the container runs and stays running;
`./verify.sh` asserts the rest. Reading `feed.last_error` is the operator-facing answer.

### The dev colours stay unpriced, and the feed does not change that

The feed refreshes the five *asset* rows, not the colour→asset map. DEVA/DEVB/DEVU still have
no reference asset by design (see below), so a live feed makes the priced colours live and
leaves the unpriced ones exactly as unpriced as before.

### A price that moves is a price that moves

`verify-kernel.sh` asserts the 2026-09-02 seed literals (`WBTC` `0.077387`, `WETH`
`0.00239328`) **only while `source` is `seed`**. Once this profile has refreshed them the
literals become context in the log and the surviving assertion is the arithmetic one —
per-base-unit == coin price / 10^decimals, exactly. That is deliberate: any gate that pinned a
live market price to a literal would be a gate that fails every morning.

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

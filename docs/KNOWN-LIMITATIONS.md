# Known limitations

> **Scope.** This file records the limitations of the **`offerfiles`** (one entry, added by the
> `a608fa6` re-pin), **`solver`**, **`poster`**, **`prices`**, **`shielded-night`** and
> **`issuer`** profiles. The remaining `offerfiles` entries land with 00005 P6.

## `offerfiles`

### The SPA's Faucet tab is DEAD at `KERNEL_REF=e3b9388…` (00020 PR C)

Kernel [#69](https://github.com/effectstream/zswap-offerfiles-kernel/pull/69) deleted
`packages/node/zk-assets.ts`, so the kernel no longer serves `GET /keys/*` or `GET /zkir/*`. The
zswap-da SPA's Faucet tab proves its mint IN THE BROWSER and fetches the proving keys from
exactly those routes, so pressing it fails. `scripts/verify-frontend.sh` asserts the routes are
**gone** (a 200 would mean `KERNEL_REF` had moved backwards onto a line these images no longer
build for) and says so where a reader will meet it.

**Nothing automated ever depended on it.** `issuer-fund` is this stack's headless minting path
and the browser mint has always been an owner hand test. **The hand test moved**, it did not
disappear: the `issuer` profile's own faucet site on `${FAUCET_HOST_PORT}` mints the six issued
tokens through a connected Lace wallet in exactly the same way, with the wallet doing the
proving.

Phase D of project 00020 re-points the SPA's Faucet link at that site.

### There is no `mints` counter any more, and `insufficient_inventory` is a normal state

Two field names people look for are gone with the mint they described: `/health`'s `mints`
(replaced by `inventoryAdoptions` + `reoffers`) and the journal's `contractAddress` (the journal
is keyed by NETWORK ID + GIVE-TOKEN ID now). See the `poster` section below for the budget that
`insufficient_inventory` reports.

### HISTORY — the entry below describes the pin BEFORE `e3b9388`

Kernel #69 deleted the mint, the contract, `offerfiles-deploy` and `offerfiles-token-names`, so
none of the behaviour described here happens on the current pin. It is kept because a reader
running an older stack forward will still see it in that stack's logs, and because it records
why the m1 names were authoritative by construction.

### The kernel's own mint logs three failed name registrations on every fresh stack, and that is correct

Since `KERNEL_REF=a608fa6…` (kernel
[#68](https://github.com/effectstream/zswap-offerfiles-kernel/pull/68)) upstream's
`packages/contracts-midnight/mint-test-tokens.ts` registers the colours it mints itself, through
`POST /v1/known-tokens` with the names `TestTokenA/B/U` (stored `TESTTOKENA/B/U` — the kernel
uppercases) at `decimals: 6`, resolving `ZSWAP_API` and falling back to
`http://127.0.0.1:9999`.

**In this stack that call cannot succeed, by design.** The mint rides the `offerfiles-deploy`
one-shot, which runs *before* the kernel exists (`kernel` waits on
`service_completed_successfully`), and that service is deliberately given no `ZSWAP_API` — so all
three POSTs hit the deploy container's own loopback and are refused. The one-shot's log therefore
carries, on every clean bring-up:

```
[mint-test-tokens] known-token registration skipped for TestTokenA (…); continuing
[mint-test-tokens] known-token registration skipped for TestTokenB (…); continuing
[mint-test-tokens] known-token registration skipped for TestTokenU (…); continuing
[mint-test-tokens] MINTED {"shieldedA":"…","shieldedB":"…","unshielded":"…"}
```

Upstream's helper catches every transport failure and only calls `log.warn`, so the mint itself
still succeeds and still publishes the receipt this stack reads. The names you actually get are
`DEVA`/`DEVB`/`DEVU`, registered afterwards by the `offerfiles-token-names` one-shot.

**Why it is left this way rather than "fixed".** Upstream also moved its own mint to a
post-kernel one-shot, so its stacks really are named `TESTTOKEN*`; adopting that topology here
would rename the tokens that `INTENTS_UI_TOKEN_NAMES`, the SPA's token picker,
`scripts/verify-solver.sh` and the kernel's name-keyed price map all expect. Leaving `ZSWAP_API`
unset is what makes the m1 names authoritative *by construction* — a loopback with nothing on it
can never win the race. Setting it to `http://kernel:9999` would not help (the kernel is not up
yet) and would arm the silent-mislabel failure instead.

**What protects it.** `offerfiles-token-names` reads `GET /v1/known-tokens` back on every `409`
and accepts it only when this stack's colour already carries this stack's name; anything else
fails the bring-up naming both names, with the registry dumped. `./verify.sh`'s `kernel` section
asserts the same property from the outside and fails on **any** `TESTTOKEN*` row. See
`docs/OPERATIONS.md`, "The dev-token names are guarded now".

## `issuer`

### The faucet SITE cannot be exercised headlessly — the browser mint is the owner's hand test

The site mints through a connected dApp-connector 4.x wallet (Lace) and **the wallet does the
proving**: it balances, proves and submits the transaction the page composes. There is no server,
no API and no key in the page, so there is nothing for a script to drive. That is upstream's
design and it is the right one for a public faucet.

The consequence for this stack is a split that is worth stating rather than discovering:
`./verify.sh` proves the site is SERVED correctly — the SPA shell, the registry with its
`Access-Control-Allow-Origin: *` and `max-age=300` headers and a matching revision, the v1
proving artifacts as binary bytes, and a real 404 for a missing artifact — and proves MINTING
through `issuer-fund`, which is the lane every automated consumer uses anyway. **Pressing a faucet
button in a browser is the owner's hand test**, and `docs/OPERATIONS.md` carries the steps.

### An amount is only unambiguous in BASE UNITS, and three of the six tokens are not 6 decimals

`TWBTC` and `UTWBTC` are 8 decimals, `TWETH` is **18**, the other three are 6. There is therefore
no "one coin" this stack can default to, and `issuer-fund` takes base units and refuses anything
that is not plain decimal digits. `TWETH`'s whole coin, `1000000000000000000`, is past
`Number.MAX_SAFE_INTEGER` by two orders of magnitude — every amount in the issuer's own code and
in `scripts/verify-issuer.sh` is handled as a `bigint` or as a decimal STRING, never as a number,
and comparisons are string equality.

This ends the whole-coin line's "6 decimals everywhere" simplification (kernel #63) for these six
colours. `DEVA`/`DEVB`/`DEVU` are still 6, and until phase C retires the kernel's faucet contract
both sets coexist — so a script that assumed 6 decimals is not yet WRONG, it is merely no longer
right for every token in the registry.

### Two facades on one seed: the caller must fund a wallet BEFORE the service that owns it starts

`issuer-fund` opens a wallet facade on the issuer's seed and one on the RECIPIENT's, and two
facades on one seed against one Midnight node force each other's connection down with no error
naming the cause (`wallets/wallets.json`). The issuer's own side is enforced — a `flock` on the
`issuer-state` volume serialises every issuer container, and the command refuses to mint to the
issuer's own seed — but the recipient's is not, and cannot be from inside this profile.

In practice this is not a constraint: every provisioning one-shot in the stack is already gated by
compose on `service_completed_successfully` before the long-lived service that holds that wallet
starts. It matters when an operator funds a wallet BY HAND on a running stack: stop the service
that owns it first, or fund a wallet nothing is holding.

An address-only mode (mint to a shielded address with no recipient facade, which upstream's own
site does) would remove the constraint entirely and is a plausible follow-up — but it cannot read
the balance back, which is the assertion this helper exists to make.

### A registry that outlives its chain is REFUSED, not repaired

`./down.sh -v` wipes the chain and both issuer volumes together, so the ordinary reset is clean.
If a registry survives a chain reset — you wiped only the node volume — the deploy runner sees a
different stack identity, marks the file `stale` and stops with an instruction rather than
redeploying. That is deliberate: replacing it discards six contracts' worth of identity and turns
every coin already minted into a different, unspendable token. `ISSUER_REDEPLOY_STALE=1` is the
operator's confirmation; `docs/OPERATIONS.md` has the procedure.

### The kernel's `canonical_token_registry_state` marker is left holding the Preprod colours

This is about the kernel pin phase C moves to, and is recorded now because the registrar is
already written for it. Kernel #69 adds an importer-ownership table beside the seed, recording the
colour a canonical PUBLIC import last committed for each of the six names. `issuer-registrar`
deliberately does not touch it, for two reasons: the column carries
`CHECK (network IN ('preview','preprod','stagenet'))`, so there is **no legal row** for an
`undeployed` colour; and leaving the Preprod marker in place is the honest state — an explicit
`TOKEN_REGISTRY_NETWORK=preprod` import on a locally-issued stack then refuses with *"managed token
TWBTC no longer matches canonical registry provenance"* and is skipped (non-fatal), which is
exactly right, because a database cannot hold both the public Preprod colours and this stack's own.
Deleting the marker rows would not change that outcome and would destroy a record this profile does
not own. On `undeployed` the import is skipped before any of it: `fetchRegistry()` throws
*"undeployed is a local network with no public canonical registry"*.

### `./verify.sh`'s issuer section leaves a coin behind, and mints one every run

The section funds `e2e-taker` with one whole `TWBTC` and reads the balance back; the coin stays in
that wallet. It is the last section `verify.sh` runs for exactly that reason — after every section
that makes assertions about that wallet — and the assertion is on the DELTA, so repeated runs
accumulate without failing. On a stack where `./verify.sh` has run three times, `e2e-taker` holds
three whole `TWBTC`.

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

### A healthy `solver` container does not mean the relay is connected (00015)

The healthcheck asks the solver's own `GET /health` for `ready`, which upstream implements as a
**startup latch** (`solverIsReady` in `packages/solver/src/run.ts`): true once the book mirror's
first sync, the kernel's backend projection and the wallet inventory have all come good, false
again only when the solver stops. It therefore answers *"this solver finished starting up and is
still running"* — and **not** "the relay socket is up", "a ladder is published", or "the backend
projection is still current". `docker compose stop relay` leaves the container `healthy`.

That is the right trade for a container healthcheck: the previous one probed the relay and
flipped 0/1 about once a minute on a working stack, because a fail-closed empty ladder is
indistinguishable from a missing solver when you ask from outside. The end-to-end claim lives in
`./verify.sh`'s `solver` section, which asserts that the relay advertises this solver's colours,
and in the monitor's health strip, whose last two stages are exactly *relay socket* and
*published ladder*. Use those to answer "is it quoting"; use the container's health to answer "is
it up".

## `poster`

### THE BOOK IS BOUNDED BY PRE-MINTED INVENTORY (00020 PR C)

The poster does not mint. Kernel #69 deleted the faucet circuit, and `selectInventoryCoin()`
replaced it: every tick either re-offers a coin that came back, or adopts one unjournaled
spendable coin whose value **equals** `OFFER_POSTER_GIVE_AMOUNT` — not one worth at least that
much. `poster-inventory` pre-mints `POSTER_PREMINT_COUNT` such coins through the `issuer`
profile before the poster starts.

**So the book grows to `POSTER_PREMINT_COUNT` offers and then stops.** At one offer per 60 s
tick, the default of 12 is twelve minutes of growth. After that, every tick with nothing to
re-offer answers:

```json
{"state":"degraded","lastMode":"degraded","lastFailure":"insufficient_inventory","freeCoins":0}
```

**That is a 200, and it is correct.** A poster with no inventory is not a poster a restart would
fix, so it stays up, keeps re-offering coins as they are released, and reports the condition
rather than dying. `./verify.sh --poster` treats it as expected only AFTER the budgeted count
has been produced; before that it diagnoses it as a pre-mint that did not land, which is a real
defect and usually the same one: `POSTER_PREMINT_COUNT` coins minted at a size that is not
`OFFER_POSTER_GIVE_AMOUNT`. Compose reads both from the same variable, so that needs an
override to happen.

**The refill needs no restart:**

```sh
docker compose run --rm issuer-fund TWBTC 1000000 \
  0000000000000000000000000000000000000000000000000000000000000041 10
```

**Why the default is 12 and not 50.** Each coin is its own proving transaction. Measured on this
stack: ≈ 9 s of fixed cost plus ≈ 23 s per coin, linear (5 coins finalised at 20/44/68/92/116 s;
3 at 23/42/66 s). Fifty coins is **19 minutes added to every bring-up**; twelve is about five.
Raise it for a long-running demo and pay the time once, or refill a running stack.

**What would remove the limitation** — and is deliberately NOT done here: a feeder loop that
tops the wallet up whenever free coins fall below a threshold. It is a second long-lived process
with its own failure modes and its own wallet facade, for a devnet demo whose book only has to
be non-empty. Recorded as an additive follow-up in the project's questions file (Q3, option B).

### A posted offer stops being SPONSORED as the reference price moves away from it

`sponsored` is `to_amount <= suggested_to_amount` (`packages/node/market-mock.ts`), and
`suggested` is recomputed from **today's** reference prices with `SPONSOR_DISCOUNT_BPS` already
applied. An offer's want leg is FIXED when it is posted. So any move in the give token's price
against the want token's, after the post, flips a perfectly good offer to `sponsored: false`
without anything being wrong.

**Kernel #69 made this much more visible here.** The poster used to mint a fresh coin every
tick, so the newest live offer was never older than ~60 s and the reference had no time to move.
It cannot mint now: once the `POSTER_PREMINT_COUNT` pre-minted coins are all live it reports
`insufficient_inventory` and posts nothing new — so on a long-running stack the newest live
offer can be tens of minutes old, and the `prices` profile is refreshing CoinGecko underneath it.

**Measured on this project's own gate:** the same assertion read `sponsored=true` on the first
`./verify.sh`, and `false` two price refreshes later on an offer asking **0.0453 %** above the
by-then-current suggestion.

`./verify.sh --poster` therefore asserts the property that is actually the poster's job —
**its own quote snapshot in the journal says the offer was sponsorable when it was built** — and
REPORTS the live reading with the drift. Refill the poster to get a fresh offer:

```sh
docker compose run --rm issuer-fund TWBTC 1000000 \
  0000000000000000000000000000000000000000000000000000000000000041 5
```

### A configured size RANGE is a filter now, not a draw

`OFFER_POSTER_GIVE_MIN`/`_GIVE_MAX` used to draw a log-uniform size per fresh mint. At this pin
they are an inclusive BASE-UNIT filter over coins the wallet ALREADY HOLDS, and
`OFFER_POSTER_SIZE_SEED` is deleted. So a spread of offer sizes needs a WALLET with a spread —
several `issuer-fund` calls at different sizes — and `poster-inventory` mints exactly one size.

### The first offer takes minutes, and nothing can make it faster

Before the poster's health server even binds, it has to sync a wallet, register its NIGHT for
DUST and wait (bounded) for that dust to appear; then the first tick adopts a coin, builds and
proves the offer (~30 s) and posts it. That is why the container healthcheck has a 15-minute
`start_period` and why `./verify.sh`'s poster section carries `POSTER_VERIFY_BUDGET_S` (420 s by
default) instead of a fixed wait. On a loaded host, raise it rather than reading a red section
as a defect. The pre-mint is ahead of all of it — about five minutes at the default count.

### The kernel does not serve a freshly accepted offer for 5–20 s, and the poster's journal says `live` anyway

The poster writes `status: "live"` into its journal the moment the kernel's `POST /v1/offers`
answers ACCEPTED. The kernel's book cannot answer for that offer yet: `GET /v1/offers/<id>` 404s
until the offer is indexed, which is **5–20 s later** on this stack. The poster is built around
exactly that wait — every tick logs `phase=live attempt=1 status=not_found` at +5 s and
`phase=verify … result=ok` at +10 s, and a tick is only good once the second line appears.

That window is normal kernel latency, not a fault, and nothing here tries to remove it. What it
means for anything reading the journal from outside — including your own tooling — is that **the
newest `live` journal entry is not yet a question the kernel can answer.** Either wait for it or
pick an older entry.

`./verify.sh`'s poster section waits, because it deliberately asserts the NEWEST offer: its
exact-coin probe polls `GET /v1/offers/<id>` every `POSTER_PROBE_POLL_S` (default 3 s) for up to
`POSTER_PROBE_WAIT_S` (default 90 s), reports the measured wait (`the kernel served <id> after
9.9s`), and only a terminal status (`consumed`/`cancelled`/`expired` — someone settled or
cancelled the offer meanwhile) ends the wait early, in which case it asserts the next-newest live
offer instead. If the budget runs out you get ONE failure naming the offer, the wait and the last
status, and the five assertions that read the kernel's view of the offer are SKIPPED rather than
evaluated on empty fields. Before this wait existed (issue 00017) a section that happened to
start inside the window reported six failures for that one cause — the offers themselves were
sound, and the section's own on-chain take passed in the same run.

### `degraded` answers **200**, on purpose

`GET /health` returns 200 while the poster is `starting` and while it is `degraded`; a 503
arrives only after `HEALTH_STALE_TICKS` consecutive FAILED ticks. `degraded` means either
`insufficient_inventory` (no coin matches the give size — see the budget entry above) or
`insufficient_dust` (the wallet has no NIGHT), and restarting a poster produces neither a coin
nor NIGHT, so failing the healthcheck would only produce a restart loop that hides the cause.

The consequence is that **a healthy poster container is not evidence that anything was ever
posted.** Only `inventoryAdoptions + reoffers` and `liveOffers` are, which is what `./verify.sh`
asserts — and separately `freeCoins + inventoryAdoptions >= POSTER_PREMINT_COUNT`, because a
poster given ONE coin posts it, re-offers it for ever, and satisfies the first check while the
book never grows.

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
passes for `genesis-2`'s DUST to settle after the deploy.

**The same condition has a second presentation, and on node 1.0.1 it is the one you will see.**
Measured on the 00020 PR A gate (node 1.0.1, 2026-09-08): the rejection came back as
`1010: Invalid Transaction: Custom error: **170**`, and the node's own log named the reason —
`🚫 Rejected transaction … Malformed(InvalidDustSpendProof)` — three times, once per absorbed
retry. So do not grep only for `196`: **grep the node log for `Dust`**, which catches both
`DustDoubleSpend(DustNullifier(...))` and `Malformed(InvalidDustSpendProof)`. Naming the reason
in the log at all is new in 1.0.1
([#961](https://github.com/midnightntwrk/midnight-node/pull/961), "add warning log when a
transaction is malformed"); on 1.0.0 the same rejection was silent about *why*. The remedy is
unchanged, and on that gate the image's own retry absorbed it: both round trips passed
`(retry x1)` and `./verify.sh` was green on its first invocation after a ten-minute gap. A few minutes' gap (which a
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

**The `shielded-night-token-name` one-shot patches it** with the kernel's own prescribed
`UPDATE known_tokens … WHERE name = 'SNIGHT'` (versioned as
`images/shielded-night/sql/snight-registry-patch.sql`), after the kernel is healthy, reports
itself synced and the chain is past block 1 — then registers as before. See
`docs/OPERATIONS.md`; every step logs. Nothing deletes a registry row any more (the exit-75
protocol and `up.sh`'s `DELETE FROM known_tokens` were both removed in 00015).

**What remains a limitation**: the patch runs only when BOTH `offerfiles` and `shielded-night`
are up, because it belongs to the `shielded-night` profile — the one that knows the colour. On an
`--with offerfiles`-only stack the phantom `SNIGHT` row stays in the registry, listed by
`GET /v1/known-tokens` and priceable, for a colour nothing on this chain holds. It is harmless
(no offer can reference it, and no coin of it can exist) but it is visible in the SPA's token
list. `./verify.sh`'s `kernel` section only asserts the row's absence when `shielded-night` is up,
for the same reason.

The upstream fix — stop seeding the row and let `price-map.ts`'s `SNIGHT` NAME entry price it
wherever it is registered — belongs to the kernel repository and is recorded there, not here.

### `undeployed` only

This profile deploys to `undeployed` and refuses any other `MN_ENV`. shielded-night's Preview
contract is already live and permanently locked; deploying another one from a demo stack with a
public dev seed would be noise on a real network at best.

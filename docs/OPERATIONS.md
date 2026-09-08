# Operations

> **Scope.** This file documents the **`issuer`** profile (the stack's own token source), the
> **`solver`** profile's monitor and status listener, the **`shielded-night`** profile, the
> `core` profile's own re-pins (the node image), and the `offerfiles`-profile notes that each
> kernel re-pin makes unavoidable for anyone running an existing stack forward. The rest of the
> `offerfiles` profile's operating notes are still to be written.

## Re-pin to kernel `main` @ `e3b9388` (00020 PR C) — **BREAKING. `./down.sh -v` is the upgrade path**

**Read this one first.** It is the newest re-pin, it is the only breaking one in project 00020,
and it changes where this stack's tokens come from.

```sh
git pull
./down.sh -v          # NOT optional — see "why" below
./up.sh --build --all
```

### What kernel [#69](https://github.com/effectstream/zswap-offerfiles-kernel/pull/69) removed

**The local faucet contract.** `packages/contracts-midnight/contract-offer-files` — the Compact
package whose `mint_shielded` circuit was this stack's only token source — is deleted, and with
it `deploy.ts`, `mint-test-tokens.ts`, `packages/node/zk-assets.ts` (so `GET /keys/*` and
`GET /zkir/*` no longer exist), and `deploy/scripts/lib/faucet-mint.ts`.
`GET /v1/midnight/config` no longer carries a `contractAddress`.

So this repository retired, in the same commit:

| gone | why, and what replaced it |
|---|---|
| the `offerfiles-deploy` service and its volume | there is no contract to deploy and no address to persist |
| the `offerfiles-token-names` service | it named the three colours the mint produced; there is no mint |
| `DEVA` / `DEVB` / `DEVU` | replaced by the **issuer's six**: `TWBTC` (8 dec) `TWETH` (18) `TWUSDC` (6) `TWUSDM` (6) `UTWUSDC` (6, unshielded) `UTWBTC` (8, unshielded) |
| the kernel image's whole Compact stage | nothing left to compile — and the ~20 minutes of proving-key generation goes with it |
| `TOKEN_NAME_SHIELDED_A/_B`, `TOKEN_NAME_UNSHIELDED` | the names are the issuer registry's and are not this repository's to choose |
| `OFFER_POSTER_SIZE_SEED`, `_MIN_DUST`, `_COIN_VISIBLE_TIMEOUT_MS`, `_DUST_WAIT_TIMEOUT_MS` | `poster-config.ts` no longer reads any of them |

### Why `./down.sh -v` is not optional

`packages/database/migrations/000-init.sql` has **no `IF NOT EXISTS`** and runs EXACTLY ONCE,
against an empty database. At this pin it moves the seeded sNight colour from Preview to
Preprod, **deletes the `USDC` and `USDM` rows**, adds the six canonical names at the public
Preprod colours, and adds a new `canonical_token_registry_state` table. Nothing migrates an
existing volume: the stack would come up healthy holding the OLD seed and merely lie about every
price. `./verify.sh` names that state directly — a `DEVA`/`USDC`/`USDM` row is reported as the
stale-volume signature with this command as the fix.

### Two profiles gained a dependency

**`poster` and `solver` now require `issuer`.** Their inventory one-shots run the issuer image
and their long-lived services read the token handoff that profile publishes. `./up.sh` adds it
for you and says so in one line:

```
    profile  poster needs `issuer` (its swap-token inventory is minted there) — adding it
```

A hand-rolled `docker compose -f compose/core.yml -f compose/offerfiles.yml -f compose/poster.yml`
refuses to render, naming `issuer-deploy`. That is deliberate and asserted by
`scripts/verify-compose-pins.sh`.

### The one-shots, and what each is for

| service | image | what it does |
|---|---|---|
| `poster-provision` · `maker-provision` | kernel | four large NIGHT UTXOs from genesis to that role's wallet, under the shared `genesis-lock` |
| `solver-provision` | kernel | the same NIGHT transfer, **and then** upstream's own `provision-solver-fees.ts`, which verifies it, registers it for DUST, and writes the ladder + the provisioning receipt |
| `poster-inventory` · `maker-inventory` · `solver-inventory` | **issuer** | the swap tokens, minted by the `issuer` profile — the only image carrying the token contracts |

They run one after another because three wallet facades are involved (genesis, the solver's
…0021, the maker's …0031) and one facade per seed is an SDK rule.

### What this pin costs, stated plainly

The zswap-da SPA's **Faucet tab is dead** on this pin: it proves a mint in the browser and
fetches its proving keys from `/keys/*`, which no longer exists. Nothing automated depended on
it — `issuer-fund` is the headless path and the browser mint was always an owner hand test — and
the `issuer` profile's own faucet site (`${FAUCET_HOST_PORT}`) mints the six issued tokens
through a connected wallet in exactly the same way. See `docs/KNOWN-LIMITATIONS.md`.

## Re-pin the node to `1.0.1` (00020 PR A) — **not breaking; an existing volume keeps working**

This is the newest re-pin and the one to read first. `NODE_IMAGE` is now
`docker.io/midnightntwrk/midnight-node@sha256:a340cdea456d58d79c0d0e6c8891a3988b472febc228496d33c8448cc1b5b632`
— the official multiarch index for **1.0.1**, which is the newest NON-PRERELEASE release on the
1.x line (1.0.2 exists only as alphas; 2.0.0/2.1.0 are the 2.x line this repository does not
follow). Nothing else moves with it: indexer 4.3.3, proof-server 8.1.0, `KERNEL_REF`,
`FRONTEND_REF`, `SHIELDED_NIGHT_REF` and `RELAY_REF` are all unchanged, and the release ships the
**same** toolkit 1.0.0 and runtime 1.0.0 — which is why `wallets/wallets.json`'s toolkit-derived
addresses needed no re-derivation.

**What you get.** midnight-ledger **8.0.2 → 8.1.0**. The rest of the stack was already on the 8.1
line (proof-server 8.1.0, the kernel's `@midnight-ntwrk/ledger-v8` 8.1.0, shielded-night's 8.1.0),
so this closes a gap rather than opening one. Two other changes are operator-visible:

* error-level logs no longer print the database host, port or name
  ([#1067](https://github.com/midnightntwrk/midnight-node/pull/1067));
* parity-db's WAL is drained on `SIGTERM`, removing a silent chain-state truncation after an
  unclean shutdown ([#1140](https://github.com/midnightntwrk/midnight-node/pull/1140)) — so
  `./down.sh` *without* `-v` is safer on this pin than it was on 1.0.0;
* a malformed transaction now says *why* in the node log
  ([#961](https://github.com/midnightntwrk/midnight-node/pull/961)) — see the DUST note in
  `docs/KNOWN-LIMITATIONS.md`, whose error code changed presentation because of it.

### Why it is not breaking, measured twice

1.0.1 adds a check that the chainspec's `networkId` matches the one the genesis state was built
with ([#1265](https://github.com/midnightntwrk/midnight-node/pull/1265)). That would matter if the
genesis this stack runs had moved. **It did not** — the two files `CFG_PRESET=dev` loads are
byte-identical in the two images:

| file | sha256, 1.0.0 **and** 1.0.1 |
|---|---|
| `res/genesis/genesis_state_undeployed.mn` | `bed6ed25287753e4fb7475ce8f13e9f423df87dc458a42503e1993de81cf6556` |
| `res/genesis/genesis_block_undeployed.mn` | `3556527e04be152a82abed8c0dfc2ad3d6e981da63907596aacfd0ccc59bbaff` |

`diff -rq` over the whole of `/res/dev` and `/res/cfg` between the two images is empty too —
`res/cfg/dev.toml`, which supplies the node's actual CLI arguments, included. Of the 20 files in
`/res/genesis` exactly two differ, and both are `preview`'s, regenerated for the C-to-M bridge's
Locked pool ([#1699](https://github.com/midnightntwrk/midnight-node/pull/1699)). Nothing here runs
`preview`.

**And then it was measured on a real volume** (00020 PR A, 2026-09-08, project `m1o00020v-v`):
`core` was brought up on **1.0.0**, left to produce blocks, torn down with plain `./down.sh` (which
keeps the chain volume), the `NODE_IMAGE` line swapped to 1.0.1, and the SAME project brought up
again on the SAME `node-data` volume:

| | on 1.0.0 (fresh volume) | on 1.0.1 (that volume) |
|---|---|---|
| `system_version` | `1.0.0-8af7d08a` | **`1.0.1-6d5d2363`** |
| `chain_getBlockHash(0)` (genesis) | `0xe72f7a21a0397844563b4206f887b779ffa0d937c2d1b2339441faa1f08b9846` | **identical** |
| `chain_getBlockHash(1)` | `0xe7cbc3fb32633a087d0090ed58d5ef9c05c7c1745bf5b6cfff7df70c17f69024` | **identical** — so this is the same chain, resumed, not a new one |
| best block | `#3` | `#4` and rising |
| node log on startup | `Initializing Genesis block/state … header-hash: 0xe72f…9846`, `Loading GRANDPA authority set from genesis on what appears to be first startup`, `📦 Highest known block at #0` | **`📦 Highest known block at #3`** — the existing database was opened at the height it was left; no "first startup" line, no networkId or genesis mismatch, no error |

`./up.sh` returned 0 in both phases, and `./down.sh -v` afterwards left `containers=0 volumes=0
networks=0`.

### Upgrading an existing stack

`./down.sh -v` is **not** required for this pin. `git pull`, then:

```sh
./down.sh          # keep your volumes — plain down.sh preserves the chain and indexer data
./up.sh --with …   # the same profiles you were running
```

Docker pulls the new digest on the next `up.sh`. If you have overridden `NODE_IMAGE` in your own
`.env`, update it there too — `.env` wins over the compose default, so a stale override is the one
way to end up still running 1.0.0 while the repository says 1.0.1. (For the same reason
`scripts/pick-ports.sh` emits the new digest: a generated `.env` carries its own `NODE_IMAGE`
line.)

## Re-pin to kernel `main` @ `a608fa6` (00018) — **not breaking**

This is the newest re-pin and the one to read first. `KERNEL_REF` is now
`a608fa67419c16188e9405417ecdf34f3f7c47a1`, one first-parent merge past `c293ebd`
([kernel #68](https://github.com/effectstream/zswap-offerfiles-kernel/pull/68), merged
2026-09-04). `FRONTEND_REF`, `SHIELDED_NIGHT_REF` and `RELAY_REF` do **not** move with it.

**Not breaking, and that is measured rather than asserted:** `git diff c293ebd..a608fa6 --
packages/database` is **empty**. No migration, no seed row, no schema change — so unlike the
`c293ebd` re-pin below, a stack whose `postgres` volume was created under `c293ebd` runs this pin
**without `./down.sh -v`**. (A volume older than `c293ebd` still needs it, for that re-pin's own
reasons.) You do still need to rebuild the kernel image, and the new `KERNEL_REF` re-runs the
Compact contract compile — budget ~20 minutes on a cold cache, once.

### What #68 brings, and what it means here

| # | Upstream change | What it means for this stack |
|---|---|---|
| 1 | **Blank-aware optional knobs** in `packages/price-feed` and `packages/batcher`: unset, empty **and whitespace-only** strings and numbers now all select the code's default, through new package-local `optionalString`/`optionalNumber` helpers. | `compose/prices.yml` passes `COINGECKO_BASE_URL` and the four `PRICE_FEED_*` knobs **blank on purpose**, so this is the one place the pin could have changed behaviour — and it does not: blank still means the default, and now whitespace does too. `COINGECKO_API_KEY` is deliberately **not** part of the change upstream, so `entrypoint-price-feed.sh`'s `unset_if_empty` stays exactly as it is. The batcher gets explicit values for every affected knob, so its new branch is never taken. `./verify.sh`'s `prices` section is the check. |
| 2 | **The mint's name registration is repaired.** `packages/contracts-midnight/mint-test-tokens.ts` no longer POSTs the dead `/api/known-tokens`; a new `register-known-tokens.ts` POSTs `POST /v1/known-tokens` with the exact colour, `TestTokenA/B/U` (the kernel uppercases to `TESTTOKENA/B/U`) and `decimals: 6`, non-fatally, resolving `ZSWAP_API` with a `http://127.0.0.1:9999` fallback. | **Expect three warnings on every fresh stack, and they are correct.** The mint rides `offerfiles-deploy`, which runs *before* the kernel exists (`kernel` waits on `service_completed_successfully`), and that service is given no `ZSWAP_API` — so the POSTs hit the deploy container's own loopback and are refused. The log reads `known-token registration skipped for TestTokenA (…); continuing`, three times, then the `MINTED {…}` receipt. Your tokens are still called **DEVA / DEVB / DEVU**, registered afterwards by the `offerfiles-token-names` one-shot. See "The dev-token names are guarded now" below. |
| 3 | **A new startup topology upstream** (contract deploy → healthy kernel → a post-kernel `mint-test-tokens` one-shot → compatibility registration → consumers), with `entrypoint-mint-test-tokens.sh` and `check-compose-topology.ts`. | Nothing here. This repository renders its own compose from `compose/*.yml` and does not use the kernel's `deploy/compose.yml` or its launchers; it keeps the mint inside `offerfiles-deploy` and names the colours from its own post-kernel one-shot. Every other upstream entrypoint/script #68 touched is comment-only. |

### The dev-token names are guarded now

`TOKEN_NAME_SHIELDED_A` / `TOKEN_NAME_SHIELDED_B` / `TOKEN_NAME_UNSHIELDED` (defaults `DEVA`,
`DEVB`, `DEVU`) are the names the three minted colours carry, and they are **load-bearing**:
`INTENTS_UI_TOKEN_NAMES`, the SPA's token picker, `scripts/verify-solver.sh` and the kernel's own
name-keyed price map — which is what makes these three `unpriced` for the sponsorship gate — all
expect them.

Since 00018 `offerfiles-token-names` no longer treats a `409` as unconditional success. It reads
`GET /v1/known-tokens` back and accepts the 409 **only** when this stack's colour already carries
this stack's name (the normal second-bring-up case). Otherwise it **fails the bring-up**, prints
both names and dumps the registry:

```
[token-names] REFUSING to accept this 409: this stack's shieldedA colour is registered under
[token-names]   a DIFFERENT name. expected DEVA, registry says TESTTOKENA.
```

A `TESTTOKEN*` name in that message means something gave the kernel's own mint a reachable
kernel API. Find what added a `ZSWAP_API` to `offerfiles-deploy` (or what re-ran the mint against
a live kernel), then `./down.sh -v` — the colours derive from the contract address, so a fresh
stack gets fresh ones. Nothing in this repository deletes a registry row.

`./verify.sh`'s `kernel` section asserts the other side of the same property: each minted colour
carries the expected name at `decimals: 6`, and **no** row anywhere in the registry has a name
starting `TESTTOKEN`.

Changing the names on a stack that has already run is therefore a deliberate act: rename with
`./down.sh -v`, or rename the rows by hand first.

| variable | default | what it does |
|---|---|---|
| `TOKEN_NAME_SHIELDED_A` | `DEVA` | the name registered for the first minted **shielded** colour |
| `TOKEN_NAME_SHIELDED_B` | `DEVB` | the name registered for the second minted **shielded** colour |
| `TOKEN_NAME_UNSHIELDED` | `DEVU` | the name registered for the minted **unshielded** colour |
| `MINTED_TOKEN_DECIMALS` | `6` | base units per coin, STATED on every registration rather than left to the column default. Mirrors the kernel's `DEFAULT_TOKEN_DECIMALS`; do not change it without changing what the faucet mints |

The kernel normalises a submitted name with `trim().toUpperCase().slice(0, 16)`, so `deva`
arrives as `DEVA`; `./verify.sh` and the one-shot both compare against the normalised form.

## Re-pin to kernel `main` @ `c293ebd` (00011 PR A) — **BREAKING for an EXISTING stack**

The previous re-pin. Still the one that decides whether an OLD volume can be carried forward.

This re-pin set `KERNEL_REF` to `c293ebd57937c0065663b08b2c244438be8989a5` (superseded by
`a608fa6…` above) and `FRONTEND_REF` to `58ab921be5513b77937a37be86bf724a41888302`, which is
still the pin today. **Those two moved together**, because the change was one change split
across two repositories.

### What moved

| Upstream | What it brings |
|---|---|
| kernel [#61](https://github.com/effectstream/zswap-offerfiles-kernel/pull/61) | sNight is SEEDED as a default known token — at the **preview** contract's colour. See the caveat below. |
| kernel [#63](https://github.com/effectstream/zswap-offerfiles-kernel/pull/63) | **The whole-coin line.** `known_tokens.decimals` DEFAULTS to **6** instead of 0; the seeded NIGHT/SNIGHT/USDC/USDM rows are all 6; every faucet mints **whole coins** scaled by 10^6. One faucet press is 1 000 coins = `1000000000` base units. Prices are served PER BASE UNIT, so `WBTC` reads `0.077387` (= 77387/10^6) and `WETH` `0.00239328` (= 2393.28/10^6). |
| kernel [#66](https://github.com/effectstream/zswap-offerfiles-kernel/pull/66) | the offer-poster's give-size range. Nothing in this repository runs the poster yet. |
| effectstream [#918](https://github.com/effectstream/effectstream/pull/918) | the **UI half** of #63: the SPA reads each token's `decimals` off `GET /v1/known-tokens`, scales every amount it displays and submits by `10^decimals`, sends an explicit `decimals` when registering a minted colour, and mints **1 000 whole coins**. |

(kernel #62 put ledger-v9 on `main` by mistake and #64 reverted it — net zero. #65 re-opens it
and is still OPEN; this repository stays on the v8 line and both images assert it at build.)

### Why it is BREAKING, and what breaks

`packages/database/migrations/000-init.sql` is **one file, applied fresh, exactly once**, against
an empty database. There is no migration runner and nothing here adds one. So a `postgres` volume
created under an older `KERNEL_REF`:

* keeps `known_tokens.decimals DEFAULT 0` forever — every colour registered afterwards without an
  explicit `decimals` lands at **0**, and prices for it are wrong by a factor of 10^6;
* keeps the old seed rows, and never gains the new ones.

Unlike the phase-G re-pin, **nothing fails loudly on its own**: the schema SHAPE did not change,
so the kernel starts, the healthcheck goes green, and the stack merely lies about every price.

`./verify.sh`'s `kernel` section is what catches it. Its `token decimals` block sweeps every row
of `GET /v1/known-tokens` and fails naming the offenders; a row at `0` is reported as
**STALE POSTGRES VOLUME** with this command as the fix:

```sh
./down.sh -v          # wipes the chain, Celestia and the DB schema together
./up.sh --all         # fresh contracts, fresh schema, fresh seed rows
```

On a devnet — which is all this repository ever runs — that is the correct and only upgrade path:
the book, the Celestia history and the deployed contracts are projections of the chain `down.sh
-v` already wipes, so wiping the schema alongside them loses nothing.

### The sNight seed caveat (kernel #61) — patched on every bring-up, and here is how

`000-init.sql` seeds a `SNIGHT` row at the colour derived from the **preview** shielded-night
contract (`793c29c9…`). That colour cannot exist on an `undeployed` devnet: this stack deploys its
own wrapper contract and derives a different colour every time. Because `known_tokens.name` is
UNIQUE and `POST /v1/known-tokens` upper-cases the name (and checks the name **before** the
colour), the seeded row would otherwise hold the name `SNIGHT` against a phantom colour and leave
this stack's real sNight unnamed — silently, because every registration path treats a 409 as
"already registered".

**The `shielded-night-token-name` one-shot patches it**, with the statement the kernel's own
comment beside that seed prescribes:

```sql
UPDATE known_tokens SET token_color = :'color', decimals = :decimals, asset_id = :'asset_id'
 WHERE upper(name) = upper(:'name')
   AND (token_color <> :'color' OR decimals <> :decimals OR asset_id IS DISTINCT FROM :'asset_id');
```

| | |
|---|---|
| the file | `images/shielded-night/sql/snight-registry-patch.sql` — versioned, shipped in the image at `/usr/local/lib/shielded-night/sql/snight-registry-patch.sql`, with the kernel's instruction quoted in its header |
| who runs it | `images/shielded-night/entrypoint-token-name.sh`, with `psql` (the `deploy` image carries `postgresql-client` for exactly this) |
| when | on every `./up.sh` that has BOTH `offerfiles` and `shielded-night` up — `up.sh` invokes the one-shot, as it always has |
| after what | the kernel answers `/v1/health`, **and** `/v1/health/sync` reports `status: ok`, **and** the midnight-node is past **block 1**. The seed is applied by the kernel while its database comes up, so a patch that won that race would simply be overwritten |
| the credentials | `PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE` on the service, from the same `OFFERFILES_PG_{USER,PASSWORD,DB}` variables the kernel and Postgres already use (defaults `offerfiles`). `psql` reads them itself; the password is never on a command line and never logged |
| then | the same `POST /v1/known-tokens` as always. On a seeded kernel that answers the **same-colour 409**, which is success; on a kernel that seeds no `SNIGHT` row it registers (201) and the UPDATE was a no-op |
| idempotence | the second and every later run reports `UPDATE 0`. It is idempotent by the statement's own `WHERE` clause, not by a marker file |

What it logs, in order — this is the sequence to look for when something is wrong:

```
[shielded-night-token-name] kernel is up
[shielded-night-token-name] kernel reports /v1/health/sync status=ok
[shielded-night-token-name] midnight-node has block #2
[shielded-night-token-name] midnight-node is at height <n> (> 1 — the kernel's seed has been applied)
[shielded-night-token-name] sNight colour <64 hex>
[shielded-night-token-name] patching the kernel's seeded SNIGHT row: psql -f /usr/local/lib/…
      UPDATE 1
      SNIGHT_REGISTRY_ROW id=2 color=<64 hex> name=SNIGHT kind=shielded decimals=6 asset_id=midnight-3
[shielded-night-token-name] registry patch: UPDATE 1 — the seeded SNIGHT row now carries this stack's colour
[shielded-night-token-name] sNight is already registered as <64 hex> — nothing to do
```

**Running it by hand** — safe at any time on a stack that is up, and the way to recover if the
bring-up warned about it:

```sh
docker compose run --rm --no-deps shielded-night-token-name
# or, through this repository's own wrapper so the fragments and .env are the ones up.sh used:
./up.sh --with offerfiles --with shielded-night     # re-runs it as part of bring-up
```

**Two things it will refuse to do**, both by design:

* if this stack's real colour is already registered under **another** name, it prints the whole
  registry and exits non-zero rather than patch (that would violate `UNIQUE(token_color)`) —
  decide by hand which name that colour should carry;
* it never DELETEs a registry row. Before 00015 `up.sh` answered an exit-75 protocol with
  `DELETE FROM known_tokens WHERE upper(name) = 'SNIGHT'`; that is gone, along with the exit code
  and the retry. A non-zero exit from the one-shot is now a real failure, and `up.sh` warns with
  the exit code and the command to re-run.

The upstream half is still open: the kernel would do better not to seed the row at all and let
`price-map.ts`'s NAME entry price sNight wherever it is registered. Until then, every m1 stack
patches its own database. An `offerfiles`-only stack (no `shielded-night`) never runs the one-shot
and therefore keeps the phantom row — see `docs/KNOWN-LIMITATIONS.md`.

### What `verify.sh` now measures on this line

* every row of `GET /v1/known-tokens` at exactly **6** decimals (and the stale-volume detector);
* the faucet **allotment**, read out of the running kernel image's own pinned tree: 1 000 whole
  coins = `1000000000` base units at 6 decimals;
* the two priced faucet presets registered at 6 decimals and priced per base unit as exact
  decimal strings — `WBTC` `0.077387`, `WETH` `0.00239328`;
* NIGHT still at 6 decimals with its per-base-unit price equal to its coin price / 10^6.

### The browser half — two thirds MEASURED, one third an owner hand test

Automated gates cannot press the SPA's faucet button, so this is recorded here. Open
`http://127.0.0.1:${FRONTEND_HOST_PORT:-10600}` and connect the in-page **JS Wallet** (the
`Connect wallet` dialog's third entry — it runs entirely in the browser and needs no extension;
Lace needs the default port block, see `docs/KNOWN-LIMITATIONS.md`, the JS wallet does not).

| # | What the browser must show | Status |
|---|---|---|
| 1 | the faucet reads **`1,000` coins** (not `1,000 units`, not `1,000,000,000`) | **MEASURED 2026-09-03** on the 00011 PR A gate — the Faucet screen reads `1,000 coins` |
| 2 | after minting, the wallet balance reads **`1,000`** of that token | **MEASURED 2026-09-03** — `Minted 1,000 WBTC`, colour `480b6163c0db…a9a2fb26`, and the wallet menu's shielded balance reads `WBTC 480b61…fb26  1,000`. That colour is exactly the one `verify-kernel.sh`'s faucet section derives and registers, so the SPA faucet and the headless probe land on the same colour by construction |
| 3 | creating and taking an offer moves the balance by **exactly the coin amount displayed** — the 00005 P3 `1000 → 999` measurement, re-done at 6 decimals | **OWNER HAND TEST** — it needs a second wallet to take the offer, so it is not something a single automated session can close. `./verify.sh`'s shielded-night `book` section proves the equivalent property on chain, with exact balances, for the sNight pair |

## Upgrading past the kernel re-pin to `main` (phase G) — BREAKING for an EXISTING stack

`KERNEL_REF` now pins `zswap-offerfiles-kernel` `main`, which carries kernel PR #54's seeded
reference-price tables (`asset_prices`, `price_feed_status`, two new `known_tokens` columns).
The kernel's schema is **one file, applied fresh** (`packages/database/migrations/000-init.sql`,
no `IF NOT EXISTS` anywhere) — there is no migration runner and nothing here adds one. An
**existing** stack's shared `postgres` volume still holds the OLD shape and the kernel will
fail loudly against it rather than silently degrade.

**The fix is `./down.sh -v`.** On a devnet — which is what this repository ever runs — that is
the correct and only upgrade path: the offer book, the Celestia history and the deployed
contracts are all projections of the same chain that command already wipes, so wiping the
Postgres schema alongside them loses nothing an operator was relying on. There is no
in-place-upgrade lane, and none is planned — a fresh chain always gets a fresh schema together.

```sh
./down.sh -v                                        # wipes the chain, Celestia, and the DB schema together
./up.sh --with offerfiles --with shielded-night      # fresh contracts, fresh schema, re-run the token-name one-shot
```

If you skip this and bring an old volume forward, `kernel`'s healthcheck fails and its logs
name the missing table/column rather than starting degraded.

The batcher's new **sponsorship gate** (`BATCHER_SPONSOR_POLICY=warn`,
`BATCHER_SPONSOR_UNPRICED=allow` by default) and the standalone price-feed refresh service
(**not run** by this repository — the seeded reference prices are enough offline) are covered
in `docs/COMPONENTS.md`'s "sNight is a PRICED asset" section.

## Re-pin to kernel PR #60 (phase H2) — a SILENT breaking change for an EXISTING stack

`KERNEL_REF` moved again, to `main` after kernel PR #60 (project 00007's own upstream fix,
question Q14): the seeded `known_tokens` row for NIGHT (and the USDC placeholder) changes its
`decimals` value from `0` to `6`. Unlike the phase-G re-pin above, this is **not** a schema
SHAPE change — no table or column is added — so an existing stack's `postgres` volume does
**not** fail loudly. It keeps running, healthcheck green, with the OLD row (`decimals: 0`)
untouched, because the seed file only runs on a fresh (empty) volume. The symptom is silent and
numeric, not an error: `GET /v1/prices` for NIGHT still answers `decimals: 0`, and a freshly
registered sNight would be priced 10^6 off from a genuinely 1:1 relationship — exactly the bug
kernel PR #60 fixed, reappearing on any stack that re-pins `KERNEL_REF` without also wiping its
volume.

**The fix is the same as above: `./down.sh -v`.** There is no in-place row-update lane in this
repository (an operator with direct DB access on a live, non-devnet deployment can instead run
the one-line `UPDATE known_tokens SET decimals = 6 WHERE name IN ('NIGHT', 'USDC');` that kernel
PR #60's own body documents — not applicable here, since this profile only ever runs a
disposable devnet).

## The `issuer` profile — bringing the stack's own tokens up, and funding wallets with them (00020 PR B)

**NOT BREAKING.** This is a NEW profile. It adds no pin to any existing image, changes no existing
service, and touches no existing volume; on the kernel pin this repository runs today its six
tokens **coexist** with the `DEVA`/`DEVB`/`DEVU` colours `offerfiles-deploy` still mints. Nothing
you already run needs `./down.sh -v` for it. (Phase C, which re-pins the kernel past #69 and
retires that faucet contract, IS breaking — this is not that.)

### Bring it up

```sh
./up.sh --with issuer                        # the tokens + the faucet site
./up.sh --with offerfiles --with issuer      # …and the kernel's registry learns all six colours
./up.sh --all                                # eight profiles, this one among them
```

What happens, in order, on a clean chain:

1. **`issuer-deploy`** waits for the node to produce a block and for the proof server and indexer
   to answer, then takes the shared **`genesis-lock`** and sends the dedicated `issuer` wallet
   (`…0051`) four NIGHT UTXOs of `5000000000000` each from `genesis-1`. It registers that NIGHT for
   DUST, waits (bounded) for the DUST to arrive, and **releases the lock** — the long half of this
   one-shot must not block `solver-provision`, `maker-offer` or `poster-provision`.
2. It then runs the pinned repository's **own** v1 deploy: six token contracts deployed, each
   verified against chain state, and `metadata.undeployed.json` published **atomically** onto the
   `issuer-registry` volume.
3. **`faucet`** starts only after that one-shot exits 0, and its healthcheck asserts the registry
   is really being served with `"status": "ready"` in the body — not merely that nginx bound.
4. When `offerfiles` is up too, `up.sh` runs **`issuer-registrar`**, which teaches the kernel the
   six colours. **A failure here fails the bring-up** (see `docs/COMPONENTS.md` for why it is
   fatal where the sNight one is a warning).

**Measured on this host, 2026-09-08** (`m1o00020b-b`, node 1.0.1 / indexer 4.3.3 / proof 8.1.0,
`--with offerfiles --with issuer` from clean): the whole bring-up **3 m 28 s**, of which the issuer
one-shot was ~3 minutes — wallet sync, the NIGHT transfer, the DUST registration, one 5-second dust
wait, then six contract deployments with proving. A SECOND `./up.sh` resumes all six in **9
seconds**.

### Open the faucet — the `?network=` is not optional

```
http://127.0.0.1:${FAUCET_HOST_PORT}/?network=undeployed
```

`FAUCET_HOST_PORT` is `10500` by default and whatever `scripts/pick-ports.sh` emitted on a
disposable stack; `up.sh` prints the URL at the end of every run. **Without `?network=undeployed`
the page defaults to Preprod** (effectstream #920's change to the SPA) and shows the PUBLIC tokens,
which do not exist on this chain.

### THE LACE HAND TEST — the one thing no automated gate here covers

The site mints through a connected browser wallet and **the wallet does the proving**, so there is
no headless path through it. `./verify.sh` therefore proves the site is SERVED correctly (the shell,
the registry with its CORS and cache headers, the proving artifacts as bytes, a real 404 for a
missing artifact) and proves MINTING through `issuer-fund` instead. The browser flow is the
owner's:

1. `./up.sh --with issuer` (add `--with frontend` if you also want the trading SPA).
2. Import the `lace-test` wallet into Lace — the seed is in `wallets/wallets.json`, and
   `docs/WALLETS.md` has the steps. It is funded at genesis, so it can pay for a mint.
3. Point Lace at this stack's node/indexer/proof-server host ports (Lace supplies those URLs to the
   page itself through the dApp connector; the page has no endpoint overrides and needs none).
4. Open `http://127.0.0.1:${FAUCET_HOST_PORT}/?network=undeployed` and connect the wallet. The
   header should report the network as **Local (undeployed)** and the registry revision.
5. Press a token's faucet button. The preset amounts are the registry's own
   (`faucetBaseUnits`): 1 twBTC, 5 twETH, 10 000 twUSDC, 10 000 twUSDM, 10 000 utwUSDC, 1 utwBTC.
6. **What to check:** the balance the card shows moves by exactly the preset, and — with
   `offerfiles` up — `GET /v1/known-tokens` already names that colour, so the trading SPA and the
   offer book show the token by NAME rather than as 64 hex characters.

If the page says the network is unavailable, the registry is not being served: check
`docker compose logs issuer-deploy` and `docker compose run --rm --no-deps issuer-registry`.

### `issuer-fund` — fund a wallet headlessly

This is the command every other profile's provisioning calls, and the one an operator uses to
refill a wallet:

```sh
docker compose run --rm issuer-fund <TOKEN> <base-units> <recipient-seed|@file>

# one whole twBTC (8 decimals) to e2e-taker
docker compose run --rm issuer-fund TWBTC 100000000 \
  0000000000000000000000000000000000000000000000000000000000000032

# five whole twETH (18 decimals) to the poster's wallet
docker compose run --rm issuer-fund TWETH 5000000000000000000 \
  0000000000000000000000000000000000000000000000000000000000000041

# TWELVE separate coins of exactly 1000000 base units — what the offer poster needs, because it
# adopts a coin BY EXACT VALUE. About 9 s of fixed cost plus 23 s per coin, measured.
docker compose run --rm issuer-fund TWBTC 1000000 \
  0000000000000000000000000000000000000000000000000000000000000041 12

# and with the seed in a file rather than on the command line
docker compose run --rm issuer-fund utwUSDC 10000000000 @/run/secrets/taker.hex
```

**BASE UNITS, NOT WHOLE COINS.** These tokens are 8, 18 and 6 decimals, so a whole coin is a
different number for each of them and there is no safe default. `TWETH` at 18 decimals is past
`Number.MAX_SAFE_INTEGER` by two orders of magnitude, so the amount is parsed, compared and printed
as a decimal STRING throughout; anything that is not plain digits is refused (exit 78) rather than
coerced.

The token may be given as the kernel's name (`TWBTC`) or the registry's symbol (`twBTC`),
case-insensitively. To see what this stack has:

```sh
docker compose run --rm --no-deps issuer-registry
```

**It reads the recipient's balance back**, and requires it to have moved by EXACTLY the amount
minted — "the transaction was accepted" and "the recipient can spend this coin" are different
claims, and a provisioning one-shot needs the second. The receipt is one greppable line:

```
ISSUER_FUND_RESULT token=TWBTC symbol=twBTC tokenId=<64 hex> privacy=shielded decimals=8 \
  amount=100000000 recipient=…0032 tx=<hash> balanceBefore=0 balanceAfter=100000000 \
  delta=100000000 verified=true
```

Exit codes: **0** minted and read back exactly · **78** a bad argument, an unknown token, or no
registry yet · **1** the mint failed or the balance did not move by exactly the amount.

**ONE AT A TIME, and fund a wallet BEFORE the service that owns it starts.** The command opens a
facade on the issuer's seed and one on the recipient's, and two facades on one seed against one
node force each other's connection down. It holds a `flock` so two `issuer-fund` runs (or a run
during `issuer-deploy`) cannot collide — but the RECIPIENT is the caller's responsibility. Every
provisioning one-shot in this stack is already gated that way by compose
(`service_completed_successfully`).

Measured: **32 seconds** for one mint on a warm stack, most of it the recipient wallet's first sync.

### Refilling

Nothing in this profile mints on a schedule; a wallet runs out when it runs out. Two cases worth
naming:

* **the offer poster** re-offers coins that come back and mints a fresh one otherwise, so on the
  kernel pin this repository runs today it CANNOT MINT AT ALL — kernel #69 deleted the faucet
  circuit — so its whole stock is what `poster-inventory` pre-minted, and refilling it is the
  command above with the poster's seed. The budget is in `docs/KNOWN-LIMITATIONS.md`.
* **the solver and the maker** — `solver-inventory` and `maker-inventory` stock them once per
  chain from `SOLVER_INVENTORY_SPEC` / `MAKER_INVENTORY_SPEC`. Top either up with `issuer-fund`
  against `SOLVER_SEED` (…0021) or `MAKER_OFFER_SEED` (…0031); nothing has to be restarted.
* **any wallet you funded by hand** — run `issuer-fund` again with the same arguments. It is not
  idempotent and is not meant to be: each call mints a NEW coin of exactly the amount asked for,
  and the receipt's `delta` says so.

### Knobs

| Variable | Default | What it does |
|---|---|---|
| `FAUCET_HOST_PORT` | `10500` | the faucet site's host port — the only port this profile publishes |
| `ISSUER_SEED` | `…0051` | the dedicated issuer wallet. Must equal no other seed in `wallets/wallets.json`; the provisioning script exits 78 if it is the genesis seed |
| `ISSUER_REF` | `7ecad008…` | the pinned `mint-test-tokens` commit. A full 40-hex SHA, enforced at build |
| `ISSUER_FUND_VERIFY` | `1` | read the recipient's balance back after every mint. Leave it on |
| `ISSUER_MN_TIMEOUT_MS` | `600000` | how long ONE SDK operation may take. The pinned runner's own default is 180 000, which is tight for a cold proof server |
| `ISSUER_DEPLOY_TIMEOUT_S` | `5400` | how long the six deployments may take before the one-shot gives up and leaves a reconcilable journal |
| `ISSUER_VERIFY_BUDGET_S` | `2400` | `./verify.sh`'s budget for the issuer section |
| `ISSUER_VERIFY_FUND_TOKEN` / `_AMOUNT` / `_SEED` | `TWBTC` / `100000000` / `…0032` | what `./verify.sh` mints to prove the funding lane |
| `ISSUER_VERIFY_ONCHAIN` | unset | `1` makes `./verify.sh` additionally run the pinned repository's own read-only on-chain verification of all six contracts (minutes) |
| `ISSUER_REDEPLOY_STALE` | unset | `1` lets the one-shot REPLACE a registry it has marked stale. Read the next section first |
| `ISSUER_CONFIRM_NO_DEPLOYMENT` | unset | `1` states that an in-flight deployment the journal remembers did NOT finalize. Reconcile the chain first |
| `ISSUER_SDK_LOG_LEVEL` | unset (silent) | `debug` brings the wallet SDK's own log back |
| `POSTER_PREMINT_COUNT` | `12` | how many coins of exactly `OFFER_POSTER_GIVE_AMOUNT` `poster-inventory` mints. ≈ 9 s + 23 s per coin, measured |
| `SOLVER_INVENTORY_SPEC` | `TWUSDC:100000000 TWUSDM:100000000` | what `solver-inventory` mints into the solver's wallet — BOTH sides of the pair, because a rung whose residual exceeds available tokenOut is withheld with every rung above it |
| `MAKER_INVENTORY_SPEC` | `TWUSDC:100000000` | what `maker-inventory` mints into the maker's wallet. Only the GIVE leg; generous, because `./verify.sh` re-seeds the book when the seeded offer is consumed |

### The maker and the poster trade DIFFERENT pairs, on purpose

`maker-offer` gives **TWUSDC** and wants **TWUSDM**; the poster gives **TWBTC** and wants
**TWETH**. That separation is load-bearing rather than cosmetic, and it was measured:

The solver's published ladder is derived from the **whole book** for a directed pair, and
`./verify.sh`'s solver section asserts `quote(WANT_AMOUNT) == GIVE_AMOUNT` **exactly** — which
holds only while the maker's offer is the only one on its pair. Before kernel #69 that was true
by construction (the poster minted faucet presets, the maker traded contract-derived colours).
Now every token comes from the issuer, so nothing stops both landing on the same two names — and
when they did, on the first `--all` gate at this pin, the poster's offers (want leg quoted from
real USD prices across an 8- and an 18-decimal token) sat in the maker's ladder at a price eleven
orders of magnitude away and the quote came back
`422 unfulfillable — amountIn is outside the published price range for this pair`.

TWUSDC and TWUSDM are both 6 decimals, both shielded and both priced, so
`MAKER_OFFER_GIVE_AMOUNT`/`_WANT_AMOUNT` (`500000`/`750000`, upstream's defaults) mean what they
meant when every token had 6 decimals. **If you re-point either service, keep the two pairs
disjoint.**

### Naming this stack's tokens for the intents UI

`INTENTS_UI_TOKEN_NAMES` is a BUILD argument by upstream's design — the UI labels a colour by
the `TOKEN_<NAME>` key baked into `index.html` — while the six colours only exist AFTER
`issuer-deploy` has run. The two passes cannot be merged; the second is one command:

```sh
./scripts/issuer-token-names.sh >> .env       # INTENTS_UI_TOKEN_NAMES=TWBTC=…,TWETH=…
./scripts/issuer-token-names.sh --table       # the same six with decimals and privacy
./up.sh --with offerfiles --with solver --build
```

Until then the UI labels each token by the last 8 characters of its colour, which is cosmetic.

### A stale registry, and why nothing here fixes it automatically

`./down.sh -v` wipes the chain and both issuer volumes together, so the ordinary reset leaves
nothing stale. The interesting case is a registry that SURVIVES a chain reset — you wiped only the
node volume, or hand-mounted a directory. The runner then reads a different stack identity
(`chain name + runtime version + genesis hash`), marks the file `stale`, and **refuses**:

```
Registry at /srv/issuer-registry/metadata.undeployed.json was marked stale after a
chain/runtime/genesis change. Confirm the reset, then rerun with MN_REDEPLOY_STALE=1.
```

That is the right answer, and this stack does not paper over it: posting stale token ids to the
kernel is precisely the failure this profile exists to prevent, and replacing the registry
**discards six contracts' worth of identity** — every coin minted from the old ones becomes a
different, unspendable token. When you have decided, bring the stack up once with
`ISSUER_REDEPLOY_STALE=1` in your `.env` (or
`docker compose run --rm -e ISSUER_REDEPLOY_STALE=1 issuer-deploy`), then take it out again.

If the runner was KILLED mid-deployment it leaves an uncertain in-flight marker instead, and
refuses until you have reconciled the node and indexer yourself. `ISSUER_CONFIRM_NO_DEPLOYMENT=1`
is how you tell it you have — only after proving that no contract finalized.

### Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `issuer-deploy` exits 78 with `missing required environment` | a `.env` that overrides one of the endpoint variables to empty. The container names which |
| `MISSING TOOL(S) IN THIS IMAGE` | a base-image change dropped `curl`, `git`, `psql`, `getent` or `flock`. The Dockerfile installs and asserts all five; this message means the image is not the one this repository builds |
| `the synchronized deployment wallet has no available DUST` | the provisioning step did not run or did not land. `docker compose logs issuer-deploy` — the `ISSUER_PROVISION_RESULT` line states the NIGHT and DUST it measured, and the one-shot refuses to write its marker without both |
| the faucet page says the network is unavailable | the registry is not being served. `curl -i http://127.0.0.1:${FAUCET_HOST_PORT}/metadata.undeployed.json` — a 404 means `issuer-deploy` published nothing; an `text/html` content type means the nginx exact-match location is gone |
| `issuer-registrar` says `no kernel on this network` and exits 0 | correct, and not an error: the `offerfiles` profile is not up. The registry is still published for the faucet and for `issuer-fund` |
| `issuer-registrar` dies with `<NAME> names a colour this stack did not issue` | something else registered that name between the patch and the POST. The one-shot dumps the whole kernel registry; decide by hand which name the colour should carry |
| `waiting for the issuer facade lock` for a long time | another issuer container is running. `docker compose ps -a` |

## The solver monitor, and reading the solver's status listener (00011 PR B)

```sh
./up.sh --with offerfiles --with solver
open http://127.0.0.1:${SOLVER_FRONTEND_HOST_PORT:-10800}     # the monitor
```

`up.sh` prints the URL as **`solver monitor`** when the stack is up. The page is read-only, has
no authentication of its own, and binds `BIND_ADDR` (127.0.0.1) like everything else here.

**Open it when the solver is misbehaving, not only when it is fine.** It depends on the kernel
alone, so it renders the book, the kernel's sync state and the token registry even with the
solver stopped — and says `SOLVER UNREACHABLE` with the time it was last seen instead of going
blank. The six-stage health strip (kernel sync → book cache → inventory → journal & DUST →
relay socket → published ladder) is designed to answer *which* stage is red, and an empty ladder
is labelled with the solver's own reason (`cache-not-current` = the fail-closed withdrawal;
`withdrawn` = a deliberate one) rather than as "no liquidity".

### Reading the status listener by hand

The listener is on `:9100` **inside the compose network only** — it is not published, because
`/status/*` serves the solver's entire internal state and the monitor is its intended reader:

```sh
# the open liveness route: no bearer, nothing internal in the body
docker compose … exec solver bun -e \
  'const r = await fetch("http://127.0.0.1:9100/health"); console.log(await r.text());'

# the full snapshot: bearer required, read from the container's own environment
docker compose … exec solver bun -e 'const r = await fetch(
  "http://127.0.0.1:9100/status/snapshot",
  { headers: { authorization: "Bearer " + process.env.SOLVER_STATUS_AUTH_TOKEN } });
  console.log(await r.text());'
```

To publish it for a debugging session, uncomment the `ports:` block in `compose/solver.yml`
(`SOLVER_STATUS_HOST_PORT`, default `19100`) — and never with a non-loopback `BIND_ADDR`: the
bearer would then be the only thing between the solver's whole internal state and the network.
`scripts/pick-ports.sh` deliberately emits no port for it. **`curl http://127.0.0.1:<port>/health`
from the host does not work** unless you have uncommented that block — the two ways in are the
`docker compose exec` above and the monitor.

### What "the solver is healthy" means (00015)

The `solver` container's healthcheck is the `GET /health` above: **200 with `ready: true`**, and
nothing else. `ready` is upstream's combined readiness and it is a **startup latch** — true once
the book mirror's first sync, the kernel's backend projection and the wallet inventory have all
come good; false again only when the solver stops. Read it as *"this solver finished starting up
and is still running"*.

| question | does a healthy `solver` container answer it? |
|---|---|
| did the solver start up completely? | **yes** — that is exactly the latch |
| is the process still alive and its listener answering? | **yes** |
| is the relay connected? | **no.** Stop the relay and this container stays healthy; the socket is not part of `ready` |
| is a ladder published right now? | **no**, and deliberately: a fail-closed empty ladder is the solver *working* |
| does the relay advertise this solver? | **not here** — `./verify.sh`'s `solver` section asserts it directly, which is where a three-service claim belongs |

Before 00015 the healthcheck probed the *relay's* `GET /tokens` and flipped 0/1 roughly once a
minute on a perfectly healthy stack, because a fail-closed empty ladder looks identical to a
missing solver from outside. Thirty consecutive unlucky samples would have marked a correct
solver `unhealthy`. If you are diffing an old stack against a new one, that is the behaviour
change; nothing else about the service moved.

To see it go red on purpose, and to time both transitions:

```sh
SOLVER_VERIFY_HEALTH_TRANSITION=1 ./scripts/verify-solver.sh
```

That stops the relay for a minute (and records that the solver stays healthy — the honest
measurement of what `ready` covers), then stops and starts the **solver** and reports how long
each transition took.

### Knobs

| variable | default | what it does |
|---|---|---|
| `SOLVER_FRONTEND_HOST_PORT` | `10800` | published port for the monitor (`BASE+11` from `pick-ports.sh`) |
| `SOLVER_STATUS_AUTH_TOKEN` | a committed devnet value, 49 chars | the ONE bearer both sides read. **≥ 32 characters, enforced at startup**: with the status port set, a missing or short value is one of the problems `start.solver.ts` lists before it binds. `pick-ports.sh` emits a random 64-hex one |
| `SOLVER_FRONTEND_POLL_MS` | blank → `4000` | kernel/relay poll interval (250–300 000). The solver half prefers SSE and polls only while the stream is down |
| `SOLVER_FRONTEND_HISTORY_LIMIT` | blank → `500` | transitions kept in memory (1–5000); never persisted |
| `SOLVER_MONITOR_BUDGET_S` | `180` | `verify.sh`: how long the monitor may take to report a relay-connected solver with a non-empty ladder |
| `SOLVER_LADDER_BUDGET_S` | `300` | `verify.sh`: how long the relay may take to advertise both colours after a re-seed |
| `SOLVER_VERIFY_RESEED` | `true` | `verify.sh`: re-seed the book when no live maker offer is left. `false` makes an empty book a FAILURE instead — never a skip |
| `MAKER_OFFER_RESEED` | `false` | the `maker-offer` one-shot: post another offer even though the marker exists. `verify.sh` sets it; an operator restart still JOINs |

**`SOLVER_REPO` / `SOLVER_REF` are retired.** The solver is the kernel commit; set either and
`scripts/lib/common.sh` warns that it is ignored. Move `KERNEL_REF` instead.

### Why `./verify.sh` sometimes posts an offer

The seeded maker offer is not permanent, and neither reason is a defect:

* **expiry** — on this chain an offer lives `min(ROOT_WINDOW_SECONDS, OFFER_TTL_SECONDS)` = **1
  hour**, whatever `MAKER_OFFER_TTL_MINUTES` asks for, because a shielded input can only be
  proved against a Merkle root still inside the chain's window. A long `./up.sh --all` plus a
  full `./verify.sh` can exceed that by itself;
* **consumption** — the kernel archives an offer the moment **any** on-chain transaction spends
  its input nullifier. A settled take does that, and so does an unrelated transfer from the
  maker's own wallet whose coin selection happens to pick the coin the offer reserved. That is
  what the `shielded-night` book chain's taker funding does on an `--all` run: it moves the
  maker's give colour out of the maker's own genesis wallet.

Before 00011 the `solver` section answered an empty book with a WARN and skipped its ladder and
exact-quote assertions — its strongest ones — while still exiting 0. It now reports the offer's
actual terminal status (by hash, from the one-shot's marker), re-seeds through
`maker-offer` with `MAKER_OFFER_RESEED=true`, and fails if that does not restore a ladder inside
`SOLVER_LADDER_BUDGET_S`.

## The offer poster (00011 PR C)

```sh
./up.sh --with offerfiles --with poster       # or --all
./verify.sh --poster                          # assert it is WORKING, not merely alive
```

THREE services come up since 00020 PR C — and the `issuer` profile with them, which `./up.sh`
adds for you:

| service | what it does |
|---|---|
| `poster-provision` | four large NIGHT UTXOs from genesis to the poster's dedicated wallet, then exits |
| `poster-inventory` | mints `POSTER_PREMINT_COUNT` coins of EXACTLY `OFFER_POSTER_GIVE_AMOUNT` through the issuer, then exits |
| `offer-poster` | the loop |

The poster registers that NIGHT for DUST itself and then posts one offer a minute.

**IT DOES NOT MINT ANY MORE.** Kernel #69 deleted the faucet circuit; `selectInventoryCoin()`
replaced the mint. Every tick either RE-OFFERS a coin that came back or ADOPTS one unjournaled
spendable coin whose value **equals** `OFFER_POSTER_GIVE_AMOUNT` — not one worth at least that
much. So `poster-inventory` mints N SEPARATE coins of that exact size, and a single large coin
would be worth exactly one offer to this poster.

**THE BOOK IS THEREFORE BOUNDED.** Once all `POSTER_PREMINT_COUNT` coins are live, a tick with
nothing to re-offer reports `degraded: insufficient_inventory` — a 200 on `/health`, by design,
because restarting would not produce a coin. Refill without a restart:

```sh
# ten more coins of the poster's exact give size, to the poster's wallet (…0041)
docker compose run --rm issuer-fund TWBTC 1000000 \
  0000000000000000000000000000000000000000000000000000000000000041 10
```

The next tick adopts one. **MEASURED cost:** about 9 s of fixed cost plus **23 s per coin**
(5 coins finalised at 20/44/68/92/116 s; 3 at 23/42/66 s) — which is why the default is 12 and
not the 50 the spec first suggested. The size MUST equal `OFFER_POSTER_GIVE_AMOUNT` exactly;
a mismatch presents as a full wallet and `insufficient_inventory` for ever, and
`./verify.sh --poster` says so by name.

**The first offer takes minutes, not seconds.** Wallet sync, DUST registration, the bounded
dust wait and ~30 s of proving all happen before anything reaches the book — which is why the
container healthcheck has a 15-minute `start_period` and why `POSTER_VERIFY_BUDGET_S` defaults
to 420. The pre-mint is ahead of all of it: ~5 minutes at the default count.

### Reading it

Everything the poster exposes is read-only and needs no bearer (`${POSTER_HEALTH_HOST_PORT}`,
loopback):

| route | what it answers |
|---|---|
| `GET /health` | `{state, ready, ticks, inventoryAdoptions, reoffers, degradedTicks, lastTickAt, lastOfferId, lastError, lastFailure, liveOffers, freeCoins, candidates, p50TickMs, p95TickMs, journal}` — `mints` was here and is gone with the mint it counted; `inventoryAdoptions` + `reoffers` is the number of offers this loop has produced, and `freeCoins` is how much inventory is left |
| `GET /metrics` | the same counters in Prometheus text format, plus tick p50/p95 and the overrun count |
| `GET /journal` | the journal as JSON — every coin, its nullifier, and every offer built from it |

```sh
curl -s http://127.0.0.1:19977/health
curl -s http://127.0.0.1:19977/journal      # .coins is keyed by coin nonce
docker compose logs -f offer-poster
```

**`degraded` is a 200 BY DESIGN, and so is `starting`.** A 503 arrives only after
`HEALTH_STALE_TICKS` consecutive FAILED ticks. A poster with nothing to post is not a poster a
restart would fix, so it says `degraded` — `insufficient_inventory` when no coin matches the
give size, `insufficient_dust` when it has no NIGHT — and keeps servicing re-offers rather than
dying. That is exactly why a green healthcheck is not evidence the poster is working, and why
`./verify.sh`'s poster section waits for `inventoryAdoptions + reoffers >= 2` and
`liveOffers >= 2`, and separately accounts for the pre-mint
(`freeCoins + inventoryAdoptions >= POSTER_PREMINT_COUNT`) — a poster given ONE coin posts it,
re-offers it for ever, and would satisfy the first check while the book never grows.

### Checking the exact-coin guarantee by hand

Every offer spends exactly one coin, whole. Compare the two sides:

```sh
# what the poster believes it did
curl -s http://127.0.0.1:19977/journal | grep -o '"nullifier":"[0-9a-f]*"' | tail -1

# what the kernel says the offer actually spends (offerId = the journal's own offerId)
curl -s http://127.0.0.1:9999/v1/offers/<offerId> | grep -o '"inputNullifiers":\[[^]]*\]'
```

One entry, and equal. `./verify.sh --poster` does this automatically.

**Expect a 404 on a fresh offer, and wait.** The journal says `live` as soon as the POST is
accepted; the kernel serves that offer 5–20 s later (its own indexing latency — the poster's log
shows the same wait as `phase=live … status=not_found` then `phase=verify … result=ok`). So the
second command above answers `404 NOT_FOUND` if you run it immediately on the newest entry.
Verify waits for it instead of guessing: the section polls `GET /v1/offers/<id>` every
`POSTER_PROBE_POLL_S` for up to `POSTER_PROBE_WAIT_S` and prints the measured wait —

```
==> poster: the exact-coin guarantee (kernel wait up to 90s, every 3s)
    OK   the kernel served offer 736e68af17537acd… after 9.9s (4 poll(s), budget 90s)
```

— and if the budget runs out it reports ONE failure naming the offer, the wait and the last
status, and says which assertions it skipped rather than failing five of them on empty fields
(issue 00017). Raise `POSTER_PROBE_WAIT_S` on a slow or loaded host; a red section is then about
the stack, not the clock.

### A dry run

`DRY_RUN=true` does the whole of startup — build the wallet, sync, register NIGHT for dust,
join the contract, derive both colours offline, register the token names, load the journal,
read one quote — then prints a JSON report and exits 0. It never mints and never posts. Run it
as a ONE-OFF, because the service restarts unless stopped:

```sh
docker compose run --rm -e DRY_RUN=true offer-poster
```

### Knobs

Every `OFFER_POSTER_*` variable in `.env.example` is a passthrough with upstream's own name and
upstream's own blank-means-code-default rule; the entrypoint UNSETS the blank ones so
`docker compose exec offer-poster env` shows what the process actually used. The ones worth
knowing:

| knob | default | effect |
|---|---|---|
| `OFFER_POSTER_GIVE_TOKEN` / `_WANT_TOKEN` | `WBTC` / `WETH` | the pair. The GIVE leg must be a faucet preset **NAME** — the poster mints it and the faucet derives the colour from the name. The WANT leg may be a name or a 64-hex colour, and must be SHIELDED. |
| `OFFER_POSTER_GIVE_AMOUNT` | `1000000` | base units per minted coin — one whole coin at 6 decimals |
| `OFFER_POSTER_GIVE_MIN` / `_GIVE_MAX` | unset | a RANGE in whole COINS instead of the fixed amount, drawn LOG-uniformly per fresh mint so the book carries a spread. **Both ends or neither**, and mutually exclusive with `GIVE_AMOUNT` — blank that line first, or the poster exits 78 naming both. `OFFER_POSTER_SIZE_SEED` makes the sequence reproducible. |
| `OFFER_POSTER_INTERVAL_MS` | `60000` | one tick a minute. An overrunning tick does not queue; the overrun is counted. |
| `OFFER_POSTER_TTL_MINUTES` | `60` | the WALLET's local deadline for an unconfirmed recipe — **not** how long a posted offer stays takeable. A live offer expires on the kernel's clock: `min(ROOT_WINDOW_SECONDS, OFFER_TTL_SECONDS)`, 1 h here, which no client can shorten. |
| `POSTER_PROVISION_ENABLED` | `true` | set false to bring the profile up without funding from genesis (an operator who funds out of band) |
| `POSTER_VERIFY_BUDGET_S` | `420` | how long `./verify.sh` waits for two mints and two live offers |
| `POSTER_VERIFY_SKIP_TAKE` | `false` | skip verify's real settlement of one poster offer (it costs two provings) |
| `POSTER_PROBE_WAIT_S` | `90` | how long `./verify.sh`'s exact-coin probe waits for the kernel to SERVE the newest offer (it is `live` in the journal 5–20 s before the book answers for it). Exhaustion is ONE failure naming the offer, the wait and the last status — the assertions that would read empty fields are skipped, not failed. |
| `POSTER_PROBE_POLL_S` | `3` | how often that probe asks. `POSTER_PROBE_WAIT_S=1` is the way to assert the exhaustion path itself. |

### The genesis-1 facade mutex

`poster-provision` drives the genesis wallet, and so do `solver-provision` and `maker-offer` in
the `solver` profile. Two wallet facades on one seed against one Midnight node force each
other's connection down, and the two fragments cannot `depends_on` each other (compose will not
render a dependency on a service that is not in the merged set, and `--with poster` alone is
supported). So all three take a `flock` on `/srv/genesis-lock/lock`, on a named volume both
fragments declare. If one of them hangs, the others say so:

```
[poster-provision] waiting for the genesis-1 facade lock (/srv/genesis-lock/lock, up to 1800s)
```

`GENESIS_LOCK_TIMEOUT_S` bounds the wait; exhausting it is a failure that names the three
services to check.

### One poster per stack

The service must never be scaled past one replica, for the same reason its seed is dedicated.
Two posters on one seed would fight over the same coins and force each other's connection down.

## The price feed (00014)

```sh
./up.sh --with offerfiles --with prices    # …and the reference prices refresh from CoinGecko
```

### Getting a key, and where it goes

The feed needs a **CoinGecko Demo key** — free, from
<https://www.coingecko.com/en/api> ("Demo" plan). It is **the only secret in this stack**;
every other credential here is a public devnet placeholder.

Put it in `.env` and nowhere else:

```sh
# .env  (gitignored — .gitignore covers .env and .env.*, and re-includes only .env.example)
COINGECKO_API_KEY=CG-xxxxxxxxxxxxxxxxxxxxxxxx
```

There is deliberately **no compose default** for it. Four rules go with it:

- **Header, never a query string.** The service sends `x-cg-demo-api-key`. A query parameter
  would put the key in every access, proxy and browser-devtools log.
- **Never printed.** The startup line renders the whole effective configuration with the key's
  field as the literal `key=present` or `key=ABSENT`, and that is the only thing anything here
  ever says about it. `scripts/verify-prices.sh` learns whether a key exists from the *exit
  code* of `test -n` run inside the container, never by reading the value.
- **Never in a rendered compose config.** `docker compose config` interpolates it. Do not
  render one with your real `.env` into a log or a paste. `scripts/verify-compose-pins.sh`
  renders with an empty env file and explicitly unsets the variable, so the repository's own
  audit path is safe regardless of your shell.
- **Rotate it if it leaks.** It is low-privilege — a read-only market-data key on a metered
  free plan — but rotating is one click in the CoinGecko dashboard, and the old key stops
  working immediately. Nothing in this stack caches it.

### A refresh now, instead of waiting a day

The loop's first cycle runs at startup and the next is `PRICE_FEED_INTERVAL_MS` (24 h) later,
so the useful command is the one-off:

```sh
docker compose --env-file .env -f compose/core.yml -f compose/offerfiles.yml \
  -f compose/prices.yml -p <project> run --rm --no-deps price-feed --once
```

or, with the repository's own env handling, simply what `./verify.sh` does. The exit code IS
the result:

| exit | meaning |
|---|---|
| `0` | every asset the cycle asked for was written |
| `2` | the cycle ran and at least one asset did not land — read `feed.last_error` |
| `64` | misconfiguration: no usable key, or a database without the kernel's `000-init.sql` schema |

### Reading it

```sh
# the five assets, their source and their age, through the kernel
curl -s "http://127.0.0.1:${KERNEL_HOST_PORT}/v1/prices?tokens=<NIGHT colour>,<WBTC colour>" | jq

# the feed's own last cycle
curl -s "http://127.0.0.1:${KERNEL_HOST_PORT}/v1/prices?tokens=0000000000000000000000000000000000000000000000000000000000000000" \
  | jq '.feed'
```

```json
{ "provider": "coingecko",
  "last_run_at": "2026-09-04T12:20:11.412Z",
  "last_ok_at":  "2026-09-04T12:20:11.412Z",
  "last_error":  null }
```

**`feed.last_error` is where a partial failure lives.** Failures in this service are graded and
deliberately non-fatal: one bad id fails only that id; a failed request is recorded against
every id it carried; a `429` stops the cycle where it stands and keeps what it already wrote.
None of that is an exit code and none of it is a crash, so a service that looks perfectly
healthy can be failing every cycle — and this field is what says so. An all-null `feed` block
means the feed has never run against this database.

`source` is the other thing to read. Before a refresh every row is `seed` (the schema's
2026-09-02 capture, which quotes correctly — that is why the profile is optional); after one it
is `feed`, and `GET /v1/quote` follows on both legs (`from_source`, `to_source`,
`prices_updated_at`).

### Rate limits, and what each `./verify.sh` costs

The demo plan allows roughly 30 requests a minute and 10 000 credits a month. One cycle is
`ceil(assets / PRICE_FEED_BATCH_SIZE)` = **one request**, once a day. **Each `./verify.sh` run
with a key present spends one more**, because the `prices` section takes a real `--once`. That
is the cost of the section proving anything at all, and it is recorded in
`docs/KNOWN-LIMITATIONS.md` so nobody meets it as a rate-limit error.

### What `./verify.sh`'s `prices` section asserts

```sh
./verify.sh                # runs the prices section if the profile is up
./verify.sh --prices       # …and FAILS if the profile is not up (the KEY is a separate matter
                           #   — with no key the section still reports SKIPPED, not failed)
./verify.sh --no-prices    # skip it entirely
```

With a key: one `--once` cycle exits 0; all five seeded assets read `source: feed` with an
`updated_at` within `PRICES_VERIFY_MAX_AGE_S`; `feed.last_error` is null, `feed.provider` is
`coingecko` and `feed.last_ok_at` is fresh; WBTC's and WETH's per-base-unit prices still equal
their asset's coin price divided by `10^decimals` **exactly, as decimal strings** — now on
fed values, which are far longer than the hand-picked seeds `verify-kernel.sh` checks; and
`GET /v1/quote` for WBTC → WETH reports `feed` on both legs with a fresh `prices_updated_at`
and a `market_rate` equal to the two fed prices' ratio.

### With no key, nothing breaks

The service comes up and **idles**: one warning at start, one on every tick, and no work.
It does not crash-loop — that is a considered choice, not an oversight (see
`docs/COMPONENTS.md`) — the stack keeps quoting from the seeds, and `./verify.sh` reports its
`prices` section **SKIPPED**, never passed:

```
    SKIP no COINGECKO_API_KEY — the feed idles by design; set the key in .env to test the refresh
    WARN prices SKIPPED — its assertions did NOT run (reason above); not counted as passed
…
    OK   verify.sh: every check that RAN passed — 1 section(s) SKIPPED: prices
```

`./verify.sh` still exits 0. A skipped section is not a failure — but it is never folded into
"all checks passed" either.

### Knobs

| variable | blank means | what it does |
|---|---|---|
| `COINGECKO_API_KEY` | no key → idle | the only secret here. `.env` only |
| `COINGECKO_BASE_URL` | `https://api.coingecko.com/api/v3` | point the service at a stub |
| `PRICE_FEED_INTERVAL_MS` | `86400000` (24 h) | between cycles, loop mode only |
| `PRICE_FEED_REQUEST_SPACING_MS` | `1000` | minimum gap between two requests in one cycle |
| `PRICE_FEED_BATCH_SIZE` | `50` | asset ids per `simple/price` request |
| `PRICE_FEED_REQUEST_TIMEOUT_MS` | `20000` | per-request timeout |
| `PRICE_FEED_ASSETS` | the five seeded ids | comma-separated CoinGecko ids |
| `PRICES_VERIFY_MAX_AGE_S` | `600` | how fresh `./verify.sh` requires a refreshed price to be |

`PRICE_FEED_MAP` is **not** one of these. It is a kernel/batcher knob (name/colour → asset id)
and lives with the sponsorship settings; the feed's own configuration never reads it.

## Bringing the `shielded-night` profile up

```sh
./up.sh --with shielded-night          # core + the dApp; nothing else is needed
```

`up.sh` blocks until the profile is genuinely usable, not merely started: the deploy one-shot
must exit 0, the web container must pass its healthcheck (`/`, `/config.js` **and** one
verifier key as non-empty bytes), and the published contract address must really be readable
on the volume. The summary line names it:

```
    Shielded NIGHT    http://127.0.0.1:10900   contract 80b89b9a…
```

On a shared machine, use a generated port block instead of the defaults:

```sh
./scripts/pick-ports.sh > .env.test
ENV_FILE=.env.test ./up.sh --with shielded-night
ENV_FILE=.env.test ./verify.sh --shielded-night
ENV_FILE=.env.test ./down.sh -v
```

`SHIELDED_NIGHT_HOST_PORT` is `BASE+10` in a generated block and `10900` by default.

## Redeploy semantics — read this before wondering why the address did not change

**The contract is deployed exactly once per stack.** The presence of `contract.json` on the
`shielded-night-deploy` volume IS the "already deployed" flag: a one-shot that finds one JOINs
that deployment and exits 0 without deploying. Three consecutive `./up.sh` runs and a
`--force-recreate` of the one-shot all yield the same address.

That is deliberate, and it protects more than an address. **The sNight token colour is derived
from the contract address**, so a silent redeploy would turn every sNight coin already minted
into a different token that nothing can spend — with no error anywhere, just a balance that
reads zero.

To force a new contract you must drop the volume:

```sh
./down.sh -v                            # wipes the chain AND this volume — a new chain gets a new contract
```

`./down.sh` without `-v` keeps the chain and the contract, so the next `./up.sh` resumes both.

**After a redeploy the web container must be restarted.** It reads the volume once, at start,
and writes `/config.js` from what it finds. A `./down.sh -v && ./up.sh --with shielded-night`
cycle recreates everything and is therefore fine. If you drop only that volume by hand, follow
it with:

```sh
docker compose … restart shielded-night     # or simply: ./up.sh --with shielded-night
```

`./verify.sh` catches this case for you: it compares `/config.js` byte-for-byte against the
volume's `contract.json` and fails if they have drifted apart.

## Verifying

```sh
./verify.sh                       # runs the shielded-night section if the profile is up
./verify.sh --shielded-night      # …and FAILS if it is not up
./verify.sh --no-shielded-night   # skip it
```

The section asserts, in order: the page serves HTML; `/config.js` is 200, carries **exactly**
the deployed address and is loaded before the module bundle; all 11 circuits' prover, verifier
and bzkir artifacts answer with non-empty bytes while a non-existent circuit answers 404; the
deployed contract's on-chain verifier keys are byte-identical to the served ones (upstream's
own `verify-deployment.ts`, run inside the compose network); and a funded driver wallet
completes both NIGHT ⇄ sNight round trips — atomic and two-step — with exact balance
assertions.

The last two run in a container from the same image the contract was deployed from:

```sh
docker compose … run --rm shielded-night-verify keys
docker compose … run --rm shielded-night-verify roundtrip
```

That service is never started by `up.sh` (it declares zero replicas), so those two commands are
the only way it runs.

**Budget several minutes for the round trips.** Each deploys its own contract instance and
performs real proofs; upstream's own timeout for each test is ten minutes.

## Knobs

| variable | default | what it does |
|---|---|---|
| `SHIELDED_NIGHT_HOST_PORT` | `10900` | published port for the page (`BASE+10` from `pick-ports.sh`) |
| `SHIELDED_NIGHT_REF` | the pinned commit | full 40-hex commit of `effectstream/shielded-night`; anything else fails the build |
| `SHIELDED_NIGHT_REPO` | the public repo URL | source of that commit |
| `SHIELDED_NIGHT_IMAGE` / `SHIELDED_NIGHT_DEPLOY_IMAGE` | `midnight-1-offers/shielded-night{,-deploy}:local` | one build context, two runtime targets, two tags |
| `SHIELDED_NIGHT_WALLET_SEED` | `genesis-2` | the deployer. **The genesis-1 seed is refused outright** (see `docs/WALLETS.md`) |
| `SHIELDED_NIGHT_DRIVER_SEED` | `genesis-2` (`0x…0002`) | the verify round trip's wallet, and the sNight maker in the book chain. Same seed as the deployer on purpose — that one-shot has exited by then (Q6 → D) |
| `SHIELDED_NIGHT_NAME` / `_SYMBOL` / `_DECIMALS` | `Shielded Night` / `sNight` / `6` | sealed into the contract at deploy; they cannot be changed afterwards |
| `SHIELDED_NIGHT_LOCK` | `false` | see below |
| `SHIELDED_NIGHT_WAIT_TIMEOUT` | `600` | how long the web container waits for `contract.json` before failing |
| `SNIGHT_BOOK_AMOUNT` | `1000000` | book chain: how much NIGHT is wrapped, and the size of the sNight leg of the offer. The taker receives it as ONE coin worth exactly this, which is what lets the unwrap step burn it whole |
| `SNIGHT_BOOK_WANT_AMOUNT` | `750000` | book chain: how much of the demo colour the offer asks for |
| `SNIGHT_BOOK_WANT_TOKEN` | `TWUSDC` | book chain: which ISSUED token the sNight offer asks for. It was `SNIGHT_BOOK_WANT_KEY=shieldedA`, a key into the deleted `minted-tokens.json`; the want leg must be a SHIELDED issuer token (so not `UTWUSDC`/`UTWBTC`), and `./verify.sh` credits the taker with it through `issuer-fund` before the take — genesis-1 holds none |
| `SNIGHT_BOOK_TAKER_SEED` | `e2e-taker` (`0x…0032`) | book chain: the wallet that takes the offer. Empty at genesis; the chain funds it |
| `SNIGHT_BOOK_FUNDER_SEED` | `genesis-1` | book chain: funds the taker. It is the faucet **and** the wallet the demo colours were minted to, so it is the only wallet that can hand the taker the token the offer demands |
| `SHIELDED_NIGHT_SKIP_BOOK` | unset (`0`) | `1`/`true` skips the WHOLE book-chain subsection (below) — not the round trips above it, which always run. For a gate on a time budget that still wants `offerfiles`+`shielded-night` wired together (compose renders, the cross-profile one-shot fires, the sNight pricing and quote are still checked from `verify-kernel.sh`) without paying the book chain's own ~12–20 min of proving |

## The book chain (`./verify.sh`, `book` subsection)

It runs **only** when the `offerfiles` profile is up; otherwise the section prints a SKIP and
the rest of the shielded-night assertions still run. `SHIELDED_NIGHT_SKIP_BOOK=1` skips it
unconditionally even when `offerfiles` IS up (see the Knobs table) — for a gate that wants
everything ELSE this subsection depends on (the cross-profile registration, the sNight pricing)
without its own ~12–20 min of proving. Bring both up with:

```sh
./up.sh --with offerfiles --with shielded-night
./verify.sh --shielded-night
```

Five steps, all in containers built from this stack's own images (no host `bun`, no host
`node`): wrap → post a real MIP-0005 offer file → find it in the book on the sNight colour →
take and settle it from a second wallet → unwrap what that wallet bought.

**Budget 12–20 minutes for it on a cold stack**, on top of the round trips. Seven real proofs
happen in it: the wrap, the offer, three funding transactions for the taker (NIGHT, the DUST
registration, the demanded token), the settlement, and the unwrap. Nothing here is
parallelisable — a wallet that submits twice before the first transaction confirms is rejected
outright (`1010: Custom error: 170`), which is why each funding step is retried rather than
pipelined.

The chain is re-runnable on a live stack: each run wraps fresh NIGHT and posts a new offer, and
the taker keeps the change from the previous run's demanded token.

## `SHIELDED_NIGHT_LOCK` — a one-way door

Setting it to `true` makes the one-shot run upstream's `deploy-and-lock.ts` instead of
`deploy.ts`: after deploying, it **dissolves the contract's maintenance committee** (empty
committee, threshold 1). No signature set can ever satisfy `committee < threshold` again, so no
verifier key and no rule can ever be changed. The circuits keep running; the contract simply
becomes permanently non-upgradeable.

It is **off by default and should stay off here.** It is meant for hosted releases — upstream's
live Preview contract is locked — and a throwaway devnet contract that dies with `./down.sh -v`
gains nothing from it. The knob exists because upstream's release path uses it.

`./verify.sh`'s on-chain-key check calls upstream's `scripts/verify-deployment.ts` with
`--allow-unlocked` (project 00007 phases F1/H2): the lock state is still measured and printed to
the `shielded-night-verify` container's log either way, but only the verifier-key/circuit-set
check decides the exit code — a devnet contract deliberately left unlocked (the default here)
no longer makes the strongest check in the profile read as a failure. This means `verify.sh` no
longer independently FAILS a bring-up where `SHIELDED_NIGHT_LOCK` was set but the contract
somehow came up unlocked (or vice versa); read the container's log line (`✓ LOCKED: …` / `ℹ NOT
locked: …`) if you need to confirm the authority state directly.

## Troubleshooting

| symptom | cause |
|---|---|
| the web container never becomes healthy, logs `waiting for /srv/shielded-night/contract.json` | the deploy one-shot has not finished (or failed). `docker compose … logs shielded-night-deploy`. |
| the one-shot exits 78 with `REFUSING to use the genesis-1 seed` | `SHIELDED_NIGHT_WALLET_SEED` was set to `0x…01`. That seed is the faucet, the offer-files deploy wallet and the kernel's. Use another. |
| the one-shot exits 78 with `missing required environment` | the fragment was rendered without `compose/shielded-night.yml`'s `environment:` block — usually a hand-built `docker compose` invocation rather than `./up.sh`. |
| the page loads but the network dropdown shows only *Preview* | `/config.js` was not served or carried no address. `curl http://127.0.0.1:${SHIELDED_NIGHT_HOST_PORT}/config.js`. |
| the page says the wallet does not support dApp proving | the connected wallet has no `getProvingProvider`. See `docs/KNOWN-LIMITATIONS.md`. |
| `verify.sh` reports the round trip failed on a wallet that never syncs | something else is holding a facade on the driver seed (`genesis-2` by default). Nothing in this repository does — check for a hand-started container or script of your own. See `docs/KNOWN-LIMITATIONS.md`. |
| the book subsection fails at step 0 with "the kernel's token registry does not name … sNight" | the `shielded-night-token-name` one-shot did not run (the profiles were brought up separately, so `up.sh` never saw both) or `ENABLE_TOKEN_REGISTRY` did not reach the kernel as the literal string `true`. Re-run `./up.sh --with offerfiles --with shielded-night`, or `docker compose … run --rm --no-deps shielded-night-token-name`. |
| the book subsection fails at step 4 with "no live offer gives …" | the offer expired (`TTL_MINUTES`, 120 by default) or a previous run already consumed it. Re-run the section; step 2 posts a fresh one each time. |
| the book subsection fails with `1010: Invalid Transaction: Custom error: 170` after every retry | the funder wallet is submitting faster than the chain confirms. It is retried 8 times, 15 s apart; if it still fails, the node is not producing blocks — check `docker compose … logs node`. |
| `verify.sh` reports the `prices` section SKIPPED | there is no `COINGECKO_API_KEY` in the `.env` this stack was brought up with. That is a supported configuration, not a fault — set the key and re-run to test the refresh. |
| `price-feed` logs `key=ABSENT` although `.env` has the key | the container was started before the key was added, or a different `ENV_FILE` was used. Compose reads `environment:` once, at create time: `docker compose … up -d --force-recreate price-feed`. |
| `--once` exits `64` with the missing-key warning | same cause. The key reached neither the container nor the `run`. |
| `--once` exits `64` naming `asset_prices` / `price_feed_status` | the database predates the kernel's 00005 schema. `000-init.sql` runs ONCE against an empty database and has no `IF NOT EXISTS`: `./down.sh -v` is the upgrade path. |
| `--once` exits `2`, or `feed.last_error` is non-null after a green-looking run | a graded failure — one retired CoinGecko id, one failed request, or a `429`. The message names which. A `429` means the monthly/minute budget is spent; wait, or raise `PRICE_FEED_INTERVAL_MS` and stop taking `--once` runs. |
| `GET /v1/prices` still says `source: seed` after the feed ran | the feed wrote a DIFFERENT database. Its `DB_*` must match the kernel's; `compose/prices.yml` states them identically to `compose/offerfiles.yml` on purpose, so this means a hand-edited fragment or a stray `.env` override. |
| the `prices` section fails with "source='feed' but its updated_at is N s old" | `feed` is a sticky flag: the row was written by an earlier run (or by another stack against a reused `postgres` volume) and this run's `--once` did not update it. Read `feed.last_error`. |

## The solver profile's private source

Moved here from the README on 2026-09-07; the README now states only that the `solver`
profile needs access to the private repository and how to point `RELAY_SOURCE_DIR` at it.

The relay and the intents UI come from **`shieldedtech/midnight-intents-swaps`**, which is a
**private** repository. This one is public, so their source is never fetched, vendored or
mirrored here. Instead:

- you clone the private repository yourself and point `RELAY_SOURCE_DIR` at the **workspace
  directory inside** that clone — the build context, not the clone's root:

  ```sh
  git clone git@github.com:shieldedtech/midnight-intents-swaps.git ./local/intents-swaps
  git -C ./local/intents-swaps checkout 061f4d3258e25b9f3a451b4b4358ed232349d96b
  echo 'RELAY_SOURCE_DIR=./local/intents-swaps/phase1-native-swaps' >> .env
  ```

  (The subdirectory is spelled out here and in `.env.example` rather than appended for you by
  a script: the leak scan below treats that directory's name as source content anywhere
  outside prose or a comment, so nothing in this repository is allowed to compose the path.)
- `up.sh` verifies your clone is at the pinned commit and has a clean tree **before** any
  build starts, and fails with a clear message when the variable is unset;
- the build reads it as a named build context; the `Dockerfile`s committed here are our own
  transcriptions and contain no copied code;
- the resulting `midnight-1-offers/relay:local` and `…/intents-ui:local` images are **never**
  pushed to any registry.

Everything else — `core`, `offerfiles`, `frontend` — builds from public sources with no
credentials at all, so the repository degrades gracefully: without private access you get the
whole stack except the intents lane.

Two mechanisms keep this honest, and they run from day one:

- `.gitignore` ignores `local/`, the conventional place to put your clone inside the checkout,
  so it cannot be staged by accident;
- `./scripts/verify-no-private-source.sh` (wired into `scripts/ci-check.sh`) scans every
  tracked file and fails on private-source markers. It distinguishes *naming* the upstream —
  fine in Markdown, in `#` comments, and in the pinned identity in
  `config/artifact-decisions.json` — from *carrying* its content, which is never fine.
  Run it with `--self-test` to see every rule reject a synthetic leak.

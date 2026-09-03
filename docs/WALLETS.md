# Wallets

> **Scope.** This file currently documents the wallets the **`shielded-night`** profile uses,
> and the browser hand test. The full roster — every seed, its measured genesis funding and its
> derived addresses — lives in `wallets/wallets.json`, which is the source of truth; the
> whole-stack narrative lands with 00005 P6.

## The rule that governs every wallet in this stack

**Two wallet facades built on ONE seed, connected to ONE node, force each other's connection
down.** The second to connect wins and the first silently stops syncing. There is no error
naming the cause: it presents as "the batcher stopped submitting", or "the round trip hangs",
hours later, and looks like a node fault. Every long-lived facade therefore gets its own seed,
and `wallets/wallets.json` records who owns which.

## The wallets this profile uses

| role | wallet | seed | why this one |
|---|---|---|---|
| **deployer** (`SHIELDED_NIGHT_WALLET_SEED`) | `genesis-2` | `0x…0002` | Genesis-funded and DUST-registered from block 0 (measured), and it is a **one-shot** facade: the deploy container proves, submits, publishes and exits, so it never holds a wallet open beside the kernel or the batcher. |
| **verify driver / sNight maker** (`SHIELDED_NIGHT_DRIVER_SEED`) | `genesis-2` — the same wallet | `0x…0002` | The deploy one-shot has **exited** before anything reads `contract.json`, so the two roles are sequential and never two facades at once. Owner decision (project 00007 question Q6 → D); the spec's original "distinct from the deployer" is amended with it. |
| **offer taker** (`TAKER_SEED`) | `e2e-taker` | `0x…0032` | Empty at genesis and provisioned by the book chain itself (NIGHT from the faucet, then DUST registration, then the demo colour it pays with). Only used when the `offerfiles` profile is up. |

`lace-test` is **not** in this table any more, and that is the point: nothing in this profile
and nothing in `./verify.sh` opens a facade on it, so an operator can keep a browser session
connected on it while the automated gates run.

### Why the deployer is NOT genesis-1

shielded-night's own scripts default to the genesis seed `0x…0001` on `undeployed`. In this
stack that seed is three things at once: the faucet (`MIDNIGHT_GENESIS_SEED`), the offer-files
contract deploy/mint wallet, and the offer-files kernel's `MIDNIGHT_WALLET_SEED`. Running a
second facade on it takes one of them offline with nothing naming the cause.

Because that default is *upstream's*, not ours, simply setting a different value would not be
enough — an operator who merely unsets the variable would get the forbidden wallet in silence.
So `images/shielded-night/entrypoint-deploy.sh` **refuses the genesis-1 seed outright** and
exits 78 (`EX_CONFIG`) with an explanation. The same refusal applies to the verify driver.

### Why the driver is the deployer's own wallet

On this line the `midnight-node` 1.0.0 dev preset funds exactly four wallets — `genesis-1`,
`genesis-2`, `batcher` (genesis seed 3) and `lace-test` — and only those four have DUST
registered at genesis. A wallet holding NIGHT with **no DUST registration cannot pay a fee at
all**, and this repository has no funding lane (no `fund-wallet.sh`, no pinned toolkit image)
to provision a fresh seed from nothing. Of the four, `genesis-1` is the kernel's, the faucet's
and the offer-files mint wallet's, and `genesis-3` is the batcher's — both long-lived facades.

That leaves `genesis-2` and `lace-test`, and the deciding argument is what each costs the
operator. Driving on `lace-test` cost a rule to remember (*never run verify while the browser
is connected*); driving on `genesis-2` costs nothing, because the only other facade on it —
the deploy one-shot — is `restart: "no"` and has already exited. So the driver is `genesis-2`.

`SHIELDED_NIGHT_DRIVER_SEED` remains a knob: point it at a different funded, DUST-registered
wallet and nothing in the fragment, the image or the verify script changes.

> **Behaviour change.** Until project 00007 phase D′ this defaulted to the `lace-test` seed. An
> operator who never set the variable now drives the round trips on `genesis-2` instead.

## The browser hand test (Lace)

The page has no in-page wallet — proving is wallet-owned by design — so the browser flow is a
hand test, and it needs the **default port block**: Lace has fixed `undeployed` endpoints
(`9944` / `8088` / `6300`) and no way to be told otherwise.

1. Bring the stack up on the **default** ports:
   ```sh
   ./up.sh --with shielded-night
   ```
   Note the contract address from the summary line.
2. In Lace, switch the network to **Undeployed** and import the `lace-test` wallet. Its BIP-39
   phrase is in `wallets/wallets.json` (23 × `abandon` + `diesel`) — Midnight's own canonical
   test wallet, funded at genesis. **Never use it for anything with real value.**
3. Wait for Lace to sync and show a NIGHT balance. (Nothing in this stack uses that wallet,
   so you can leave the session connected — `./verify.sh` will not disturb it.)
4. Open `http://127.0.0.1:10900`, choose **Local (undeployed)** in the network dropdown, and
   connect the wallet. If the page reports that the wallet does not support dApp proving, that
   Lace build has no `getProvingProvider` — see `docs/KNOWN-LIMITATIONS.md`.
5. Convert **1 NIGHT → sNight**. One approval later the sNight balance shows 1 sNight and NIGHT
   has dropped by exactly 1 (fees are paid in DUST, not NIGHT).
6. Convert back. NIGHT returns to its starting value.

Step 6 only works for coins minted **in this browser** — see `docs/KNOWN-LIMITATIONS.md`.

## Never

Every seed in `wallets/wallets.json` is public and belongs to a throwaway local chain. Never
reuse one anywhere else, and never fund one with real value on any network.

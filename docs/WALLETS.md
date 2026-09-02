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

## The two wallets this profile uses

| role | wallet | seed | why this one |
|---|---|---|---|
| **deployer** (`SHIELDED_NIGHT_WALLET_SEED`) | `genesis-2` | `0x…0002` | Genesis-funded and DUST-registered from block 0 (measured), and it is a **one-shot** facade: the deploy container proves, submits, publishes and exits, so it never holds a wallet open beside the kernel or the batcher. |
| **verify driver** (`SHIELDED_NIGHT_DRIVER_SEED`) | `lace-test` | the 64-byte Midnight/Lace test seed | Also genesis-funded and DUST-registered, distinct from the deployer as the spec requires, and — decisively — **held open by no container facade in any profile**. |

### Why the deployer is NOT genesis-1

shielded-night's own scripts default to the genesis seed `0x…0001` on `undeployed`. In this
stack that seed is three things at once: the faucet (`MIDNIGHT_GENESIS_SEED`), the offer-files
contract deploy/mint wallet, and the offer-files kernel's `MIDNIGHT_WALLET_SEED`. Running a
second facade on it takes one of them offline with nothing naming the cause.

Because that default is *upstream's*, not ours, simply setting a different value would not be
enough — an operator who merely unsets the variable would get the forbidden wallet in silence.
So `images/shielded-night/entrypoint-deploy.sh` **refuses the genesis-1 seed outright** and
exits 78 (`EX_CONFIG`) with an explanation. The same refusal applies to the verify driver.

### Why the driver is the Lace test wallet, and the one rule that comes with it

On this line the `midnight-node` 1.0.0 dev preset funds exactly four wallets — `genesis-1`,
`genesis-2`, `batcher` (genesis seed 3) and `lace-test` — and only those four have DUST
registered at genesis. A wallet holding NIGHT with **no DUST registration cannot pay a fee at
all**, and this repository has no funding lane (no `fund-wallet.sh`, no pinned toolkit image)
to provision a fresh seed. Of the four, three are already taken: genesis-1 is the kernel's,
genesis-2 is the deployer, genesis-3 is the batcher's.

**So: do not run `./verify.sh --shielded-night` while a Lace session is connected on
`lace-test`.** That would be two facades on one seed, and it would present as a round trip that
hangs on a wallet that never syncs. The verify run and the browser hand test are sequential,
not concurrent. `SHIELDED_NIGHT_DRIVER_SEED` is a knob precisely so a different wallet can be
pointed at it without touching the fragment or the image.

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
3. Wait for Lace to sync and show a NIGHT balance.
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

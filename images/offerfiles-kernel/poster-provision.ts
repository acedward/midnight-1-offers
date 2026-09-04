// poster-provision.ts — give the offer poster's DEDICATED wallet the one thing it cannot
// get for itself: unshielded NIGHT.
//
//   docker compose run --rm poster-provision      (compose/poster.yml, profile `poster`)
//
// Run by entrypoint-poster-provision.sh, ONCE per chain, behind a marker on the
// `poster-state` volume and under a `flock` on the shared `genesis-lock` volume.
//
// ── WHY THIS EXISTS AT ALL ───────────────────────────────────────────────────
// Upstream's stance is "the operator transfers NIGHT by hand" (kernel `deploy/README.md`,
// Funding). m1's contract is different and older than this profile: `./up.sh` on a clean
// host with no `.env` must reach a WORKING stack, so every wallet a profile needs is funded
// by a one-shot (`solver-provision`, `shielded-night-deploy`). This is the poster's.
//
// ── WHY NOT UPSTREAM'S provision-solver-fees.ts (00011 Q16) ──────────────────
// It is the worked example the kernel's own README points at, and it is the wrong tool here
// for four independent reasons:
//
//   1. it writes a solver LADDER CONFIG and a provisioning RECEIPT into /srv/solver-config,
//      a volume that belongs to the `solver` profile — which `--with poster` alone must not
//      have to mount;
//   2. it reads `minted-tokens.json` to name colours for that ladder, which the poster does
//      not use (its colours derive from faucet preset NAMES, offline);
//   3. it EXITS 1 when the recipient wallet holds ANY shielded token. The poster's wallet
//      holds exactly that by design — one faucet coin per un-offered tick — so re-running it
//      on a healthy stack (a lost marker, an operator re-run) would fail on the stack's
//      correct state;
//   4. it names the recipient `SOLVER_SEED`. Putting the POSTER's seed into a variable called
//      SOLVER_SEED is precisely the collision `poster-config.ts`'s COLLIDING_SEED_VARS check
//      exists to catch.
//
// So the four-large-UTXO transfer — the only part the poster needs — is reimplemented here,
// with the same two numbers and the same retry rationale as upstream's script.
//
// ── WHY IT DOES NOT REGISTER DUST ────────────────────────────────────────────
// Because the poster does that itself, and the kernel's README is explicit about it: "The
// poster needs unshielded NIGHT, and nothing else — it registers that NIGHT for DUST itself
// at startup and waits (bounded) for the dust to arrive". A second registration here would
// spend and re-create the same UTXOs a minute before the poster does the same thing, for no
// gain and one more proving round. NIGHT is the whole job.
//
// ── ONE FACADE PER SEED ──────────────────────────────────────────────────────
// Two facades open on the poster's seed at once (this script and `offer-poster`) would force
// each other's connection down, so compose gates the poster on this one-shot's
// `service_completed_successfully`, and this process stops both wallets before it exits.
// The GENESIS facade is the other half of the same rule — `solver-provision`, `maker-offer`
// and the `offerfiles-deploy` mint all drive genesis-1 — which is what the entrypoint's
// `flock` on the shared `genesis-lock` volume serialises.
//
// ── OUTPUT CONTRACT (read by the entrypoint's marker line; keep it stable) ───
//   POSTER_PROVISION_RESULT posterNight=<base units> funded=<true|false> utxos=<n> each=<n>
//
// DEVNET ONLY: it moves genesis NIGHT to a public dev seed on a throwaway chain.
//
// ── IMPORTS ──────────────────────────────────────────────────────────────────
// First-party by ABSOLUTE /app path, third-party by bare specifier. bun resolves a bare
// specifier by walking up from the IMPORTING FILE, so this file has to be run from inside
// /app for `@effectstream/*` to resolve at all — the entrypoint installs it there at runtime
// (see its header). `/app/packages/solver-core/wallet.ts` resolves its own bare imports from
// /app/node_modules either way, because it lives there.

import { midnightNetworkConfig as net } from "@effectstream/midnight-contracts/midnight-env";
import { setNetworkId } from "@midnight-ntwrk/midnight-js-network-id";

import {
  buildWallet,
  shieldedKeys,
  unshieldedAddressObj,
  unshieldedBalances,
  waitForSync,
} from "/app/packages/solver-core/wallet.ts";

globalThis.WebSocket = WebSocket;
setNetworkId(net.id as never);

const TAG = "[poster-provision]";
const log = (msg: string): void => console.error(`${TAG} ${msg}`);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const NIGHT = "0".repeat(64);
/** Identical to upstream's provision-solver-fees.ts and bootstrap-dev.ts: a dust coin's
 *  capacity is tied to the size of the NIGHT UTXO backing it, so a few LARGE UTXOs are
 *  usable immediately where many small ones are worthless for days. */
const NIGHT_PER_UTXO = 5_000_000_000_000n;
const NIGHT_UTXO_COUNT = 4;
/** How long to wait for the funded UTXOs to become visible on the poster's own view. */
const CONFIRM_TRIES = 36;
const CONFIRM_INTERVAL_MS = 5_000;

function requiredSeed(name: string): string {
  const value = (process.env[name] ?? "").trim().replace(/^0[xX]/, "").toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(value)) {
    log(`${name} must be a 64-hex seed`);
    process.exit(78); // EX_CONFIG, the same code the poster's own config parser uses
  }
  return value;
}

const POSTER_SEED = requiredSeed("POSTER_SEED");
const GENESIS_SEED = requiredSeed("MIDNIGHT_GENESIS_SEED");

// The collision the poster itself refuses to start on, checked HERE too — before any NIGHT
// moves. Funding the genesis wallet from the genesis wallet would "succeed" and leave a
// marker claiming a poster wallet was provisioned that does not exist.
if (POSTER_SEED === GENESIS_SEED) {
  log("POSTER_SEED is the GENESIS seed. One wallet facade per seed is an SDK rule, and the");
  log("poster would refuse to start (exit 78) even if this succeeded. Give it its own seed —");
  log("wallets/wallets.json records the roster and reserves …0041 for it.");
  process.exit(78);
}

let poster: any;
let genesis: any;
let exitCode = 1;

try {
  poster = await buildWallet(POSTER_SEED);
  await waitForSync(poster);
  log(`poster wallet synced (seed …${POSTER_SEED.slice(-4)})`);

  const before = (await unshieldedBalances(poster))[NIGHT] ?? 0n;
  log(`poster NIGHT before: ${before}`);

  let funded = false;
  if (before < NIGHT_PER_UTXO) {
    log(`funding ${NIGHT_UTXO_COUNT} x ${NIGHT_PER_UTXO} NIGHT from genesis`);
    genesis = await buildWallet(GENESIS_SEED);
    try {
      await waitForSync(genesis, { requireUnshieldedFunds: true });
      const available = (await unshieldedBalances(genesis))[NIGHT] ?? 0n;
      const needed = NIGHT_PER_UTXO * BigInt(NIGHT_UTXO_COUNT);
      if (available < needed) {
        throw new Error(`genesis holds ${available} NIGHT, needs ${needed}`);
      }

      const receiver = unshieldedAddressObj(poster);
      const outputs = Array.from({ length: NIGHT_UTXO_COUNT }, () => ({
        type: NIGHT,
        amount: NIGHT_PER_UTXO,
        receiverAddress: receiver as never,
      }));

      // Retried, for upstream's own reason: a transfer spends the previous one's change,
      // which only exists once that transaction confirms, so retrying self-synchronises on
      // it. Ten attempts at 15 s is the same ladder provision-solver-fees.ts uses.
      let lastErr: unknown;
      for (let attempt = 1; attempt <= 10; attempt++) {
        try {
          const recipe = await genesis.wallet.transferTransaction(
            [{ type: "unshielded", outputs } as never],
            shieldedKeys(genesis),
            { ttl: new Date(Date.now() + 30 * 60_000), payFees: true },
          );
          const signed = await genesis.wallet.signRecipe(recipe, (p: Uint8Array) =>
            genesis.unshieldedKeystore.signData(p),
          );
          await genesis.wallet.submitTransaction(await genesis.wallet.finalizeRecipe(signed));
          lastErr = undefined;
          break;
        } catch (err) {
          lastErr = err;
          log(`  NIGHT transfer attempt ${attempt}/10 failed: ${String(err).slice(0, 180)}`);
          await sleep(15_000);
        }
      }
      if (lastErr) throw lastErr;
      log(`sent ${NIGHT_UTXO_COUNT} x ${NIGHT_PER_UTXO} NIGHT to the poster`);
      funded = true;
    } finally {
      // Closed BEFORE the confirmation poll below, and before this process exits at all: the
      // genesis facade is the contended one, and the flock the entrypoint holds is only as
      // useful as the promptness with which the facade is given back.
      await genesis?.wallet?.stop?.().catch(() => {});
      genesis = undefined;
    }

    for (let i = 0; i < CONFIRM_TRIES; i++) {
      if (((await unshieldedBalances(poster))[NIGHT] ?? 0n) >= NIGHT_PER_UTXO) break;
      await sleep(CONFIRM_INTERVAL_MS);
    }
  } else {
    log("the poster already holds enough NIGHT — nothing to send");
  }

  const after = (await unshieldedBalances(poster))[NIGHT] ?? 0n;
  log(`poster NIGHT after: ${after}`);

  // FAIL LOUDLY rather than write a marker over a wallet that got nothing. A poster with no
  // NIGHT still starts and reports `degraded: insufficient_dust` on /health — 200, by design
  // — so an unfunded wallet would present as a permanently healthy poster that never mints.
  if (after < NIGHT_PER_UTXO) {
    log(`ERROR: the poster holds ${after} NIGHT after provisioning, expected >= ${NIGHT_PER_UTXO}.`);
    log("ERROR: it would start, report `degraded: insufficient_dust` on /health with a 200,");
    log("ERROR: and never mint. Refusing to record this as provisioned.");
    exitCode = 1;
  } else {
    console.log(
      `POSTER_PROVISION_RESULT posterNight=${after} funded=${funded} ` +
        `utxos=${NIGHT_UTXO_COUNT} each=${NIGHT_PER_UTXO}`,
    );
    log("the poster registers this NIGHT for DUST itself at startup — nothing else to do");
    exitCode = 0;
  }
} catch (err) {
  log(`FATAL: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}`);
  exitCode = 1;
} finally {
  await genesis?.wallet?.stop?.().catch(() => {});
  await poster?.wallet?.stop?.().catch(() => {});
}

process.exit(exitCode);

// night-provision.ts — give ONE named wallet the one thing it cannot get for itself:
// unshielded NIGHT, as a few LARGE UTXOs, from genesis.
//
//   M1_NIGHT_ROLE=poster M1_NIGHT_RECIPIENT_SEED=… bun run night-provision.ts
//
// Run by entrypoint-night-provision.sh (services `poster-provision` and `maker-provision`)
// and by images/cow-solver/entrypoint-solver-provision.sh, ONCE per chain per wallet, behind a
// marker on the consuming profile's own volume and under a `flock` on the shared
// `genesis-lock` volume.
//
// ── WHY THIS EXISTS AT ALL ───────────────────────────────────────────────────
// Upstream's stance is "the operator transfers NIGHT by hand" (kernel `deploy/README.md`,
// Funding), and since kernel #69 that is the stance of `provision-solver-fees.ts` too: it
// REFUSES to run unless the wallet already holds NIGHT ("SOLVER_SEED has no NIGHT. Prefund it
// externally; this deployment cannot fund the wallet"). m1's contract is different and older
// than any of these profiles: `./up.sh` on a clean host with no `.env` must reach a WORKING
// stack, so every wallet a profile needs is funded by a one-shot. This is that one-shot, for
// every wallet that needs it.
//
// ── IT WAS poster-provision.ts, AND WHY IT IS GENERIC NOW (00020 PR C) ───────
// Written for the poster in 00011 PR C, it is byte-for-byte the transfer the SOLVER and the
// MAKER now need as well — the solver because upstream stopped funding it, and the maker
// because it stopped being genesis-1 (the deleted faucet contract's mint credited exactly that
// wallet, which is the only reason the maker ever WAS the genesis wallet; with tokens coming
// from the issuer it gets its own roster seed …0031 instead). One script, three callers, one
// set of numbers — rather than three copies drifting apart.
//
// ── WHY NOT UPSTREAM'S provision-solver-fees.ts FOR THIS HALF (00011 Q16) ────
// It is the worked example the kernel's own README points at, and at `e3b9388…` it explicitly
// no longer does this job at all — it VALIDATES prefunding and refuses when there is none. It
// is also the wrong shape for the poster and the maker for reasons that predate #69:
//
//   1. it writes a solver LADDER CONFIG and a provisioning RECEIPT into /srv/solver-config,
//      a volume that belongs to the `solver` profile — which `--with poster` alone must not
//      have to mount;
//   2. it requires two explicit swap-token IDs, which the poster's NIGHT funding has no
//      business knowing;
//   3. it names the recipient `SOLVER_SEED`. Putting the POSTER's seed into a variable called
//      SOLVER_SEED is precisely the collision `poster-config.ts`'s COLLIDING_SEED_VARS check
//      exists to catch.
//
// So the four-large-UTXO transfer — the only part these wallets need — is here, with the same
// two numbers and the same retry rationale as upstream's own funding paths. The solver's
// entrypoint then runs upstream's check on top of it, which is the division of labour #69
// asks for: this deployment supplies the inventory, upstream's script verifies it.
//
// ── WHY IT DOES NOT REGISTER DUST ────────────────────────────────────────────
// Because each recipient wallet does that itself, and the kernel's README is explicit about the
// poster: "The poster needs unshielded NIGHT, and nothing else — it registers that NIGHT for
// DUST itself at startup and waits (bounded) for the dust to arrive". The solver's
// registration is `provision-solver-fees.ts`'s `ensureSolverDustReady()`, run immediately
// after this script by the same entrypoint. The maker's is `post-maker-offer.ts`'s own wallet
// build. A registration here would spend and re-create the same UTXOs a minute before the
// owner does the same thing, for no gain and one more proving round. NIGHT is the whole job.
//
// ── ONE FACADE PER SEED ──────────────────────────────────────────────────────
// Two facades open on the recipient's seed at once (this script and the service that owns the
// wallet) would force each other's connection down, so compose gates that service on this
// one-shot's `service_completed_successfully`, and this process stops both wallets before it
// exits. The GENESIS facade is the other half of the same rule — `solver-provision`,
// `poster-provision`, `maker-provision` and `issuer-deploy` all drive genesis-1 — which is
// what the entrypoint's `flock` on the shared `genesis-lock` volume serialises.
//
// ── OUTPUT CONTRACT (read by the entrypoint's marker line; keep it stable) ───
//   NIGHT_PROVISION_RESULT role=<name> night=<base units> funded=<true|false> utxos=<n> each=<n>
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

const ROLE = (process.env.M1_NIGHT_ROLE ?? "wallet").trim() || "wallet";
const TAG = `[night-provision/${ROLE}]`;
const log = (msg: string): void => console.error(`${TAG} ${msg}`);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const NIGHT = "0".repeat(64);
/** Identical to upstream's provision-solver-fees.ts and bootstrap-dev.ts: a dust coin's
 *  capacity is tied to the size of the NIGHT UTXO backing it, so a few LARGE UTXOs are
 *  usable immediately where many small ones are worthless for days. */
const NIGHT_PER_UTXO = 5_000_000_000_000n;
const NIGHT_UTXO_COUNT = 4;
/** How long to wait for the funded UTXOs to become visible on the RECIPIENT's own view. */
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

const RECIPIENT_SEED = requiredSeed("M1_NIGHT_RECIPIENT_SEED");
const GENESIS_SEED = requiredSeed("MIDNIGHT_GENESIS_SEED");

// The collision the poster itself refuses to start on, checked HERE too — before any NIGHT
// moves, and for every role rather than only the poster's. Funding the genesis wallet from
// the genesis wallet would "succeed" and leave a marker claiming a wallet was provisioned
// that does not exist.
if (RECIPIENT_SEED === GENESIS_SEED) {
  log(`the ${ROLE} seed IS the GENESIS seed. One wallet facade per seed is an SDK rule, and`);
  log("the owning service would refuse to start (exit 78) even if this succeeded. Give it its");
  log("own seed — wallets/wallets.json records the roster: …0021 solver, …0031 maker,");
  log("…0041 poster, …0051 issuer.");
  process.exit(78);
}

let recipient: any;
let genesis: any;
let exitCode = 1;

try {
  recipient = await buildWallet(RECIPIENT_SEED);
  await waitForSync(recipient);
  log(`${ROLE} wallet synced (seed …${RECIPIENT_SEED.slice(-4)})`);

  const before = (await unshieldedBalances(recipient))[NIGHT] ?? 0n;
  log(`${ROLE} NIGHT before: ${before}`);

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

      const receiver = unshieldedAddressObj(recipient);
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
      log(`sent ${NIGHT_UTXO_COUNT} x ${NIGHT_PER_UTXO} NIGHT to the ${ROLE}`);
      funded = true;
    } finally {
      // Closed BEFORE the confirmation poll below, and before this process exits at all: the
      // genesis facade is the contended one, and the flock the entrypoint holds is only as
      // useful as the promptness with which the facade is given back.
      await genesis?.wallet?.stop?.().catch(() => {});
      genesis = undefined;
    }

    for (let i = 0; i < CONFIRM_TRIES; i++) {
      if (((await unshieldedBalances(recipient))[NIGHT] ?? 0n) >= NIGHT_PER_UTXO) break;
      await sleep(CONFIRM_INTERVAL_MS);
    }
  } else {
    log(`the ${ROLE} already holds enough NIGHT — nothing to send`);
  }

  const after = (await unshieldedBalances(recipient))[NIGHT] ?? 0n;
  log(`${ROLE} NIGHT after: ${after}`);

  // FAIL LOUDLY rather than write a marker over a wallet that got nothing. A poster with no
  // NIGHT still starts and reports `degraded: insufficient_dust` on /health — 200, by design
  // — so an unfunded wallet would present as a permanently healthy poster that never mints.
  if (after < NIGHT_PER_UTXO) {
    log(`ERROR: the ${ROLE} holds ${after} NIGHT after provisioning, expected >= ${NIGHT_PER_UTXO}.`);
    log("ERROR: without NIGHT it cannot pay for a proving transaction at all — the poster");
    log("ERROR: would start and report `degraded` on /health with a 200, the solver's own");
    log("ERROR: prefunding check would refuse, and the maker could not post an offer.");
    log("ERROR: Refusing to record this as provisioned.");
    exitCode = 1;
  } else {
    console.log(
      `NIGHT_PROVISION_RESULT role=${ROLE} night=${after} funded=${funded} ` +
        `utxos=${NIGHT_UTXO_COUNT} each=${NIGHT_PER_UTXO}`,
    );
    log(`the ${ROLE} registers this NIGHT for DUST itself — nothing else to do here`);
    exitCode = 0;
  }
} catch (err) {
  log(`FATAL: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}`);
  exitCode = 1;
} finally {
  await genesis?.wallet?.stop?.().catch(() => {});
  await recipient?.wallet?.stop?.().catch(() => {});
}

process.exit(exitCode);

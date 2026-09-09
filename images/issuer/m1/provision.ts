// m1/provision.ts — give the ISSUER's dedicated wallet the two things it cannot get for
// itself on a fresh `undeployed` chain: unshielded NIGHT, and DUST generated from it.
//
//   node --import tsx /app/m1/provision.ts
//
// Run by entrypoint-deploy.sh, BEFORE `npm run deploy:v1`, once per chain, behind a marker on
// the `issuer-state` volume and under a `flock` on the shared `genesis-lock` volume.
//
// ── WHY THIS EXISTS AT ALL ───────────────────────────────────────────────────
// mint-test-tokens' v1 deploy runner refuses to submit anything until
// `waitForFundedDeploymentWallet()` sees a synced wallet with strictly positive DUST
// (`scripts/lib/deployment-wallet.ts`), and it asks nothing of a faucet — correctly, because
// its public-network path has a privately funded wallet and this stack's `undeployed` chain
// has no faucet service at all. m1's own contract is that `./up.sh` on a clean host with no
// `.env` reaches a WORKING stack, so every wallet a profile needs is funded by a one-shot.
// This is the issuer's, and it is the same shape as `poster-provision`
// (images/offerfiles-kernel/poster-provision.ts) down to the two numbers.
//
// ── WHY A DEDICATED SEED, AND NEVER genesis-1 (project 00020 question Q5) ────
// The deployer holds a wallet facade open for the length of six contract deployments with
// proving. genesis-1 is already the faucet, the kernel's MIDNIGHT_WALLET_SEED and the source
// every other provisioning one-shot draws from; a second facade on it would take one of those
// offline with no error naming the cause. So the roster gains `issuer` (…0051), this script
// refuses to run if the two seeds are equal, and the genesis facade is held for as little time
// as possible and closed before the DUST wait.
//
// ── WHY IT DOES REGISTER DUST, UNLIKE poster-provision ───────────────────────
// The poster registers its own NIGHT at startup (the kernel's README says so), so its
// provisioning one-shot deliberately does not. Nothing in mint-test-tokens registers anything
// — it is written for wallets that arrive already funded — so the registration has to happen
// here, and the DUST wait with it: a deployer with registered-but-not-yet-generated DUST fails
// the runner's own precondition and the failure reads as "no available DUST", several minutes
// into a bring-up.
//
// ── OUTPUT CONTRACT (read by the entrypoint's marker line; keep it stable) ───
//   ISSUER_PROVISION_RESULT issuerNight=<base units> dust=<base units> funded=<true|false> \
//                           registered=<true|false> utxos=<n> each=<n>
//
// DEVNET ONLY: it moves genesis NIGHT to a public dev seed on a throwaway chain.

import {
  NIGHT,
  buildFacade,
  dustBalance,
  log,
  readSeedFile,
  registerNightForDust,
  sleep,
  waitForDust,
  waitSynced,
  withTimeout
} from "./lib.js";

const ROLE = "issuer-provision";
const say = (message: string): void => log(ROLE, message);

/** Identical to `poster-provision.ts` and to upstream's own `provision-solver-fees.ts` /
 *  `bootstrap-dev.ts`: a dust coin's capacity is tied to the size of the NIGHT UTXO backing it,
 *  so a few LARGE UTXOs are usable immediately where many small ones are worthless for days. */
const NIGHT_PER_UTXO = 5_000_000_000_000n;
const NIGHT_UTXO_COUNT = 4;
/** How long to wait for the funded UTXOs to become visible on the issuer's own view. */
const CONFIRM_TRIES = 36;
const CONFIRM_INTERVAL_MS = 5_000;
/** How long to wait for DUST to appear after registration. Generous: this is the one wait that
 *  gates six contract deployments, and its failure mode is a bring-up that gets much further
 *  before failing for a reason that does not name this step. */
const DUST_WAIT_MS = Number(process.env.ISSUER_DUST_WAIT_MS ?? 600_000);

async function seedFromFile(variable: string): Promise<string> {
  const path = process.env[variable]?.trim();
  if (!path) {
    say(`${variable} must name a file containing a 32- or 64-byte hex master seed`);
    process.exit(78); // EX_CONFIG, the same code every other one-shot in this stack uses
  }
  try {
    return await readSeedFile(path, variable);
  } catch (error) {
    say(`${variable}: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(78);
  }
}

const issuerSeed = await seedFromFile("MN_SEED_FILE");
const genesisSeed = await seedFromFile("MN_GENESIS_SEED_FILE");

// The collision the poster refuses to start on, checked HERE too — before any NIGHT moves.
// Funding the genesis wallet from the genesis wallet would "succeed" and leave a marker
// claiming an issuer wallet was provisioned that does not exist.
if (issuerSeed === genesisSeed) {
  say("MN_SEED_FILE and MN_GENESIS_SEED_FILE carry the SAME seed.");
  say("One wallet facade per seed is an SDK rule (wallets/wallets.json), and the deploy runner");
  say("holds its facade open through six proving deployments. Give the issuer its own seed —");
  say("the roster reserves …0051 for it.");
  process.exit(78);
}

let issuer: Awaited<ReturnType<typeof buildFacade>> | undefined;
let genesis: Awaited<ReturnType<typeof buildFacade>> | undefined;
let exitCode = 1;

try {
  issuer = await buildFacade(ROLE, issuerSeed);
  const issuerState = await waitSynced(issuer.provider, "the issuer wallet");
  say(`issuer wallet synced (seed …${issuerSeed.slice(-4)})`);
  // The keystore's hex `UserAddress` — the value wallets/wallets.json records as
  // `addresses.userAddress`, so an operator can match this line against the roster.
  say(`issuer userAddress ${issuer.provider.unshieldedKeystore.getAddress()}`);

  const before: bigint = (issuerState?.unshielded?.balances?.[NIGHT] as bigint | undefined) ?? 0n;
  say(`issuer NIGHT before: ${before}`);

  let funded = false;
  if (before < NIGHT_PER_UTXO) {
    say(`funding ${NIGHT_UTXO_COUNT} x ${NIGHT_PER_UTXO} NIGHT from genesis`);
    genesis = await buildFacade("issuer-provision/genesis", genesisSeed);
    try {
      const genesisState = await waitSynced(genesis.provider, "the genesis wallet");
      const available: bigint = (genesisState?.unshielded?.balances?.[NIGHT] as bigint | undefined) ?? 0n;
      const needed = NIGHT_PER_UTXO * BigInt(NIGHT_UTXO_COUNT);
      if (available < needed) throw new Error(`genesis holds ${available} NIGHT, needs ${needed}`);

      // THE RECIPIENT IS AN `UnshieldedAddress` OBJECT, NOT A HEX STRING, and the two are easy
      // to confuse because both are "the unshielded address":
      //
      //   wallet.unshielded.getAddress()      -> UnshieldedAddress { data: Buffer }   <- THIS
      //   unshieldedKeystore.getAddress()     -> UserAddress (a hex string)
      //
      // `makeTransfer` does `output.receiverAddress.data.toString('hex')`
      // (@midnight-ntwrk/wallet-sdk-unshielded-wallet/dist/v1/Transacting.js), so the hex
      // string fails inside an `Array.map` as `Cannot read properties of undefined (reading
      // 'toString')` — a message that names neither the field nor the address. MEASURED on the
      // first live bring-up of this profile, which retried it ten times before giving up.
      //
      // The hex form IS the right value for a CONTRACT ARGUMENT (`m1/fund.ts` passes it as the
      // unshielded mint's `Either<ContractAddress, UserAddress>` right branch, exactly as the
      // pinned tree's own `scripts/v1-mint-wallet-test.ts` does). Two conventions, two uses.
      const recipient = await issuer.provider.wallet.unshielded.getAddress();
      const outputs = Array.from({ length: NIGHT_UTXO_COUNT }, () => ({
        type: NIGHT,
        amount: NIGHT_PER_UTXO,
        receiverAddress: recipient as never
      }));

      // Retried, for upstream's own reason: a transfer spends the previous one's change, which
      // only exists once that transaction confirms, so retrying self-synchronises on it. Ten
      // attempts at 15 s is the same ladder `provision-solver-fees.ts` and
      // `poster-provision.ts` use.
      let lastError: unknown;
      for (let attempt = 1; attempt <= 10; attempt += 1) {
        try {
          const recipe = await withTimeout(
            "genesis NIGHT transfer",
            genesis.provider.wallet.transferTransaction(
              [{ type: "unshielded", outputs } as never],
              {
                shieldedSecretKeys: genesis.provider.zswapSecretKeys,
                dustSecretKey: genesis.provider.dustSecretKey
              },
              { ttl: new Date(Date.now() + 30 * 60_000), payFees: true }
            )
          );
          const signed = await genesis.provider.wallet.signRecipe(recipe, (payload: Uint8Array) =>
            genesis!.provider.unshieldedKeystore.signData(payload)
          );
          const txId = await genesis.provider.wallet.submitTransaction(
            await genesis.provider.wallet.finalizeRecipe(signed)
          );
          say(`sent ${NIGHT_UTXO_COUNT} x ${NIGHT_PER_UTXO} NIGHT to the issuer, tx ${String(txId)}`);
          lastError = undefined;
          break;
        } catch (error) {
          lastError = error;
          say(`  NIGHT transfer attempt ${attempt}/10 failed: ${String(error).slice(0, 180)}`);
          await sleep(15_000);
        }
      }
      if (lastError) throw lastError;
      funded = true;
    } finally {
      // Closed BEFORE the confirmation poll and the DUST wait, and before this process exits at
      // all: the genesis facade is the contended one, and the flock the entrypoint holds is only
      // as useful as the promptness with which the facade is given back.
      await genesis.stop();
      genesis = undefined;
      say("genesis facade closed");
    }

    for (let i = 0; i < CONFIRM_TRIES; i += 1) {
      const state = await issuer.provider.wallet.waitForSyncedState().catch(() => undefined);
      const now: bigint = ((state as any)?.unshielded?.balances?.[NIGHT] as bigint | undefined) ?? 0n;
      if (now >= NIGHT_PER_UTXO) break;
      await sleep(CONFIRM_INTERVAL_MS);
    }
  } else {
    say("the issuer already holds enough NIGHT — nothing to send");
  }

  const afterState = await waitSynced(issuer.provider, "the issuer wallet");
  const after: bigint = (afterState?.unshielded?.balances?.[NIGHT] as bigint | undefined) ?? 0n;
  say(`issuer NIGHT after: ${after}`);

  // FAIL LOUDLY rather than write a marker over a wallet that got nothing. A deploy runner
  // started against an unfunded wallet does not fail here — it fails minutes later inside the
  // SDK, with an error that names DUST and not this step.
  if (after < NIGHT_PER_UTXO) {
    say(`ERROR: the issuer holds ${after} NIGHT after provisioning, expected >= ${NIGHT_PER_UTXO}.`);
    say("ERROR: the deploy runner would refuse with \"no available DUST\". Refusing to record");
    say("ERROR: this as provisioned.");
    throw new Error("issuer NIGHT funding did not land");
  }

  let dust = dustBalance(afterState);
  let registered = false;
  if (dust > 0n) {
    say(`issuer already has ${dust} spendable DUST — no registration needed`);
  } else {
    registered = await registerNightForDust(ROLE, issuer.provider);
    dust = await waitForDust(ROLE, issuer.provider, DUST_WAIT_MS);
  }
  say(`issuer DUST: ${dust}`);

  if (dust <= 0n) {
    say(`ERROR: no spendable DUST after ${Math.round(DUST_WAIT_MS / 1000)}s.`);
    say("ERROR: mint-test-tokens' deploy runner refuses to submit without it");
    say("ERROR: (scripts/lib/deployment-wallet.ts). Refusing to record this as provisioned.");
    throw new Error("issuer DUST generation did not start");
  }

  process.stdout.write(
    `ISSUER_PROVISION_RESULT issuerNight=${after} dust=${dust} funded=${funded} ` +
      `registered=${registered} utxos=${NIGHT_UTXO_COUNT} each=${NIGHT_PER_UTXO}\n`
  );
  exitCode = 0;
} catch (error) {
  say(`FATAL: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
  exitCode = 1;
} finally {
  await genesis?.stop();
  await issuer?.stop();
}

process.exit(exitCode);

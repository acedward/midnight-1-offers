// take-poster-offer.ts — a second wallet TAKES one of the offer poster's offers, and the
// settlement is asserted on the taker's own balances.
//
//   docker compose run --rm --no-deps -T \
//     -v "$REPO_ROOT/scripts/driver:/app/stack-driver:ro" \
//     -e TAKER_SEED=… -e FUNDER_SEED=… -e GIVE_TOKEN=<64hex> -e WANT_TOKEN=<64hex> \
//     -e GIVE_TOKEN_NAME=TWBTC -e WANT_TOKEN_NAME=TWETH \
//     --entrypoint bun kernel run stack-driver/take-poster-offer.ts
//
// Run by scripts/verify-poster.sh's last assertion (spec FR-014 / SC-005). It is the
// strongest claim that section makes: the poster's offers are not merely LISTED, they are
// SETTLE-ABLE by somebody else, and the taker is credited exactly what the offer gives.
//
// ── WHY IT IS MOUNTED INTO /app RATHER THAN BAKED INTO AN IMAGE ─────────────
// Same reason as its sibling take-snight-offer.ts: taking an Offer File needs the MIP-0005
// bech32m codec, ledger-v8's `Transaction` and the wallet facade the kernel tree already
// installs. bun resolves npm dependencies by walking up from the importing FILE, so a mount
// anywhere other than under /app would look in /node_modules and find nothing.
//
// ── WHERE THE TAKER'S WANT-SIDE INVENTORY COMES FROM (00020 PR C) ──────────
// Up to `KERNEL_REF=a608fa6…` the taker MINTED the token the offer demanded, itself, through
// the kernel's own faucet circuit (`mintFaucetToken`) — because the poster's want leg was a
// FAUCET PRESET and nothing else on the chain held one.
//
// Kernel #69 deleted that contract, `deploy/scripts/lib/faucet-mint.ts` and
// `packages/solver-core/offer-files.ts` with it. There is no mint of any kind left in this
// image, so the taker must ARRIVE HOLDING the want token, minted by the `issuer` profile:
//
//   docker compose run --rm issuer-fund <WANT_TOKEN_NAME> <base units> <taker-seed>
//
// scripts/verify-poster.sh does exactly that before invoking this driver. If the balance is
// still short when the offer is picked, this script fails with the shortfall and that command
// rather than proceeding — a settlement that cannot pay is not a failure worth diagnosing
// twice.
//
// NIGHT (hence DUST, hence a fee) still comes from genesis by TRANSFER, which is the one thing
// genesis can give it and the one step this driver kept.
//
// ── THE TWO LEGS ARE 64-HEX IDS, NOT NAMES ─────────────────────────────────
// They used to be NAMES, because a preset colour derived from the contract address offline and
// both sides could compute it. Issued colours derive from each token's own deployed contract
// instead, so the ids come in from the caller — which reads them from the issuer's registry,
// the one place they are defined.
//
// ── WHICH OFFER IT TAKES ────────────────────────────────────────────────────
// The FIRST live offer that gives the poster's give colour and wants its want colour, with
// both amounts read FROM THE KERNEL rather than from configuration — so a poster running
// with a size RANGE (OFFER_POSTER_GIVE_MIN/_GIVE_MAX) is taken correctly at whatever size
// that particular offer happens to carry. The poster spends each coin WHOLE, so there is
// exactly one input and no change: taking one offer removes exactly one offer from the book.
//
// ── OUTPUT CONTRACT (parsed by scripts/verify-poster.sh; keep it stable) ────
//   POSTER_TAKE_RESULT offerId=<64hex> status=consumed giveToken=<64hex> giveAmount=<n>
//     wantToken=<64hex> wantAmount=<n> giveBefore=<n> giveAfter=<n> wantBefore=<n>
//     wantAfter=<n>
//
// DEVNET ONLY.

import { registerNightForDust, waitForDustFunds } from "@effectstream/midnight-contracts";
import { midnightNetworkConfig as net } from "@effectstream/midnight-contracts/midnight-env";
import { OfferFiles } from "@effectstream/mip-zswap-offer/mip5";
import { Transaction } from "@midnight-ntwrk/ledger-v8";
import { setNetworkId } from "@midnight-ntwrk/midnight-js-network-id";

import {
  buildWallet,
  shieldedBalances,
  shieldedKeys,
  unshieldedAddressObj,
  unshieldedBalances,
  waitForShielded,
  waitForSync,
} from "../packages/solver-core/wallet.ts";

globalThis.WebSocket = WebSocket;
setNetworkId(net.id as never);

const API = (process.env["ZSWAP_API"] ?? "http://kernel:9999").replace(/\/$/, "");
const TAKER_SEED = required("TAKER_SEED");
/** The only wallet that can give the taker NIGHT — and therefore DUST, and therefore a fee. */
const FUNDER_SEED = required("FUNDER_SEED");
/** The poster's two legs, as this chain's 64-hex token ids. REQUIRED: they are issued per
 *  chain and there is nothing sensible to default them to. */
const GIVE_TOKEN = requiredTokenId("GIVE_TOKEN");
const WANT_TOKEN = requiredTokenId("WANT_TOKEN");
/** Display only — the caller knows the names, this script only ever compares ids. */
const GIVE_TOKEN_NAME = (process.env["GIVE_TOKEN_NAME"] ?? "").trim() || GIVE_TOKEN.slice(0, 8);
const WANT_TOKEN_NAME = (process.env["WANT_TOKEN_NAME"] ?? "").trim() || WANT_TOKEN.slice(0, 8);

const NIGHT = "0".repeat(64);
/** The same two numbers the kernel tree's own e2e driver funds its taker with. */
const NIGHT_PER_UTXO = 5_000_000_000_000n;
const NIGHT_UTXO_COUNT = 2;
/** One undeployed block between two submits from the SAME wallet: the SDK's dust-spend
 *  accounting has not yet seen the chain notification for the previous one, and a
 *  transaction built against that state is rejected outright (`1010: Custom error: 170`). */
const SUBMIT_SETTLE_MS = 8_000;
/** How many 5-second polls to give a just-credited want balance. The mint that produced it is
 *  a separate transaction submitted by the ISSUER, so the taker's own view of it arrives on the
 *  indexer's schedule rather than on this script's. */
const WANT_WAIT_TRIES = Number(process.env["TAKE_WANT_WAIT_TRIES"] ?? "60");
const DUST_WAIT_MS = Number(process.env["TAKE_DUST_WAIT_MS"] ?? "300000");
const STATUS_TIMEOUT_MS = Number(process.env["TAKE_STATUS_TIMEOUT_MS"] ?? "300000");
const BALANCE_TIMEOUT_MS = Number(process.env["TAKE_BALANCE_TIMEOUT_MS"] ?? "300000");

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (msg: string): void => console.error(`[take-poster] ${msg}`);
const die = (msg: string): never => {
  console.error(`[take-poster] FATAL: ${msg}`);
  process.exit(1);
};

function required(name: string): string {
  const v = process.env[name]?.trim();
  if (!v) return die(`missing required environment: ${name}`);
  return v;
}

/** A token id, validated to the shape every consumer at this pin validates it to. Lowercased,
 *  because the kernel's book reports colours in lower case and this script compares strings. */
function requiredTokenId(name: string): string {
  const v = required(name).toLowerCase().replace(/^0x/, "");
  if (!/^[0-9a-f]{64}$/.test(v)) {
    return die(
      `${name} must be a 64-hex token id, got "${v.slice(0, 24)}…". ` +
        "Read this stack's six ids with: docker compose run --rm --no-deps issuer-registry",
    );
  }
  return v;
}

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(`${API}${path}`, { signal: AbortSignal.timeout(30_000) });
  const text = await res.text();
  if (!res.ok) die(`GET ${path} -> ${res.status}: ${text.slice(0, 300)}`);
  return JSON.parse(text) as T;
}
async function postJson<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  if (!res.ok) die(`POST ${path} -> ${res.status}: ${text.slice(0, 300)}`);
  return JSON.parse(text) as T;
}

interface Leg {
  token: string;
  amount: string;
  type: string;
}
interface OfferRow {
  offerId: string;
  computed: { gives: Leg[]; wants: Leg[] };
}

let funder: any;
let taker: any;

/** NIGHT, so the taker can register for DUST and therefore pay a fee at all. */
async function fundTakerNight(): Promise<void> {
  const held = (await unshieldedBalances(taker))[NIGHT] ?? 0n;
  if (held >= NIGHT_PER_UTXO) {
    log(`taker already holds ${held} NIGHT`);
    return;
  }
  log(`taker holds ${held} NIGHT — funding ${NIGHT_UTXO_COUNT} x ${NIGHT_PER_UTXO}`);
  funder = await buildWallet(FUNDER_SEED);
  await waitForSync(funder, { requireUnshieldedFunds: true });
  log(`funder wallet synced (seed …${FUNDER_SEED.slice(-4)})`);
  const receiver = unshieldedAddressObj(taker);
  const outputs = Array.from({ length: NIGHT_UTXO_COUNT }, () => ({
    type: NIGHT,
    amount: NIGHT_PER_UTXO,
    receiverAddress: receiver as any,
  }));
  // Retried: a transfer spends the previous one's change, which exists only once that
  // transaction confirms, so retrying self-synchronises on it.
  let lastErr: unknown;
  for (let attempt = 1; attempt <= 8; attempt++) {
    try {
      const recipe = await funder.wallet.transferTransaction(
        [{ type: "unshielded", outputs } as any],
        shieldedKeys(funder),
        { ttl: new Date(Date.now() + 30 * 60_000), payFees: true },
      );
      const signed = await funder.wallet.signRecipe(recipe, (p: Uint8Array) =>
        funder.unshieldedKeystore.signData(p),
      );
      await funder.wallet.submitTransaction(await funder.wallet.finalizeRecipe(signed));
      lastErr = undefined;
      break;
    } catch (err) {
      lastErr = err;
      log(`  NIGHT transfer attempt ${attempt}/8 failed: ${String(err).slice(0, 160)}`);
      await sleep(15_000);
    }
  }
  if (lastErr) die(`could not fund the taker with NIGHT: ${String(lastErr).slice(0, 300)}`);
  // The genesis facade is contended (solver-provision, maker-offer and poster-provision all
  // want it), so it is given back the moment its job is done rather than at process exit.
  await funder?.wallet?.stop?.().catch(() => {});
  funder = undefined;

  const deadline = Date.now() + BALANCE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (((await unshieldedBalances(taker))[NIGHT] ?? 0n) >= NIGHT_PER_UTXO) break;
    await sleep(5_000);
  }
  log(`taker NIGHT: ${(await unshieldedBalances(taker))[NIGHT] ?? 0n}`);
  await sleep(SUBMIT_SETTLE_MS);
}

async function main(): Promise<void> {
  const giveColour = GIVE_TOKEN;
  const wantColour = WANT_TOKEN;
  log(`kernel   : ${API}`);
  log(`network  : ${net.id}`);
  log(`give     : ${GIVE_TOKEN_NAME} ${giveColour}  (the taker receives it)`);
  log(`want     : ${WANT_TOKEN_NAME} ${wantColour}  (the taker pays it from issuer-minted stock)`);

  // THE offer, chosen from the kernel's live book on BOTH legs. `?direction=GIVING` on the
  // give colour is not enough on its own: a stack whose SPA faucet was used by hand could
  // hold somebody else's WBTC offer wanting something entirely different.
  const { offers } = await getJson<{ offers: OfferRow[] }>(
    `/v1/offers?token=${giveColour}&direction=GIVING&limit=100`,
  );
  const match = offers.find(
    (o) =>
      o.computed.gives.some((g) => g.token === giveColour) &&
      o.computed.wants.some((w) => w.token === wantColour),
  );
  if (!match) {
    return die(
      `no live offer gives ${GIVE_TOKEN_NAME} for ${WANT_TOKEN_NAME} ` +
        `(the book holds ${offers.length} offer(s) giving that colour)`,
    );
  }
  const giveAmount = BigInt(match.computed.gives.find((g) => g.token === giveColour)!.amount);
  const wantAmount = BigInt(match.computed.wants.find((w) => w.token === wantColour)!.amount);
  log(`offer ${match.offerId.slice(0, 16)}… gives ${giveAmount} for ${wantAmount}`);

  const detail = await getJson<{ offerBech32?: string }>(`/v1/offers/${match.offerId}`);
  const blob = detail.offerBech32;
  if (typeof blob !== "string" || !blob.startsWith("swapoffer1")) {
    die(`GET /v1/offers/${match.offerId} returned no swapoffer1… blob`);
  }

  taker = await buildWallet(TAKER_SEED);
  await waitForSync(taker);
  log(`taker wallet synced (seed …${TAKER_SEED.slice(-4)})`);

  await fundTakerNight();
  await registerNightForDust(taker as any);
  log("taker registered NIGHT for DUST");

  // THE DUST HAS TO BE THERE BEFORE THE SETTLEMENT, and this wait used to be implicit: it sat
  // in front of the taker's own faucet mint, which was itself a fee-paying contract call. With
  // the mint gone (00020 PR C) the first thing the taker pays for is the settlement, so the
  // wait moves here rather than disappearing — `balanceFinalizedTransaction` with no DUST is a
  // failure whose message names neither DUST nor the registration that had not landed yet.
  const dust = await waitForDustFunds(taker.wallet as any, {
    timeoutMs: DUST_WAIT_MS,
    waitNonZero: true,
  });
  log(`taker DUST balance: ${dust}`);

  // THE TOKEN THE OFFER DEMANDS — held already, or this run cannot settle (00020 PR C).
  //
  // The taker used to mint it. Kernel #69 deleted the faucet circuit and its helper, so the
  // stock comes from the `issuer` profile instead and the only thing left to do here is to
  // check it and to say EXACTLY how to fix a shortfall. `waitForShielded` is given one short
  // window rather than none: verify-poster.sh funds the taker moments before this runs, and a
  // wallet that has just been credited may still be catching up.
  let wantHeld = (await shieldedBalances(taker))[wantColour] ?? 0n;
  if (wantHeld < wantAmount) {
    log(`taker holds ${wantHeld} ${WANT_TOKEN_NAME}, needs ${wantAmount} — waiting for the balance`);
    wantHeld = await waitForShielded(taker, wantColour, wantAmount, WANT_WAIT_TRIES, 5_000);
  }
  if (wantHeld < wantAmount) {
    return die(
      `the taker holds ${wantHeld} base units of ${WANT_TOKEN_NAME} (${wantColour.slice(0, 16)}…) ` +
        `and the offer demands ${wantAmount}. This stack does not mint from the taker any more — ` +
        `fund it from the issuer:\n` +
        `  docker compose run --rm issuer-fund ${WANT_TOKEN_NAME} ${wantAmount - wantHeld} <taker-seed>`,
    );
  }
  log(`taker holds ${wantHeld} ${WANT_TOKEN_NAME} (needs ${wantAmount})`);

  const balancesBefore = await shieldedBalances(taker);
  const giveBefore = balancesBefore[giveColour] ?? 0n;
  const wantBefore = balancesBefore[wantColour] ?? 0n;
  log(`taker before: ${GIVE_TOKEN_NAME} ${giveBefore}, ${WANT_TOKEN_NAME} ${wantBefore}`);

  log("balancing the poster's offer file and settling it on chain (proving…)");
  const offerTx = Transaction.deserialize("signature", "proof", "binding", OfferFiles.decode(blob!));
  const recipe = await (taker.wallet as any).balanceFinalizedTransaction(offerTx, shieldedKeys(taker), {
    ttl: new Date(Date.now() + 30 * 60_000),
  });
  const settleTx = await taker.wallet.finalizeRecipe(recipe);
  await (taker.wallet as any).submitTransaction(settleTx);
  log("settlement submitted");

  // THE KERNEL'S OWN VERDICT, not ours: `consumed` means it observed the offer's input
  // nullifier spent on chain. A balance that moved without this would be some other transfer.
  let status = "";
  const deadline = Date.now() + STATUS_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(5_000);
    ({ status } = await postJson<{ status: string }>("/v1/offers/status", { offer: blob }));
    log(`  offer status: ${status}`);
    if (status === "consumed") break;
    if (status === "cancelled" || status === "expired") die(`offer ended as "${status}" instead of consumed`);
  }
  if (status !== "consumed") die(`offer never reached "consumed" (last: "${status}")`);

  // EXACT deltas, both directions. "+give" alone would also be satisfied by a taker that
  // paid nothing, which is exactly the failure an unbalanced settlement would be.
  const giveAfter = await waitForShielded(taker, giveColour, giveBefore + giveAmount, 60, 5_000);
  const wantAfter = (await shieldedBalances(taker))[wantColour] ?? 0n;
  if (giveAfter !== giveBefore + giveAmount) {
    die(`taker ${GIVE_TOKEN_NAME} went ${giveBefore} -> ${giveAfter}, expected +${giveAmount}`);
  }
  if (wantAfter !== wantBefore - wantAmount) {
    die(`taker ${WANT_TOKEN_NAME} went ${wantBefore} -> ${wantAfter}, expected -${wantAmount}`);
  }
  log(`taker after: ${GIVE_TOKEN_NAME} ${giveAfter} (+${giveAmount}), ${WANT_TOKEN_NAME} ${wantAfter} (-${wantAmount})`);

  console.log(
    `POSTER_TAKE_RESULT offerId=${match.offerId} status=${status} ` +
      `giveToken=${giveColour} giveAmount=${giveAmount} ` +
      `wantToken=${wantColour} wantAmount=${wantAmount} ` +
      `giveBefore=${giveBefore} giveAfter=${giveAfter} ` +
      `wantBefore=${wantBefore} wantAfter=${wantAfter}`,
  );
}

main().then(
  async () => {
    await funder?.wallet?.stop?.().catch(() => {});
    await taker?.wallet?.stop?.().catch(() => {});
    process.exit(0);
  },
  async (e: unknown) => {
    console.error(`[take-poster] failed: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`);
    await funder?.wallet?.stop?.().catch(() => {});
    await taker?.wallet?.stop?.().catch(() => {});
    process.exit(1);
  },
);

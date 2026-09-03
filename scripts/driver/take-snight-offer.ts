// take-snight-offer.ts — the LAST link of the book chain: a second wallet takes the sNight
// offer file the maker posted, and the settlement is asserted on the taker's own balances.
//
//   docker compose run --rm --no-deps -T \
//     -v "$REPO_ROOT/scripts/driver:/app/stack-driver:ro" \
//     -e SNIGHT_COLOR=… -e WANT_TOKEN=… -e GIVE_AMOUNT=… -e WANT_AMOUNT=… \
//     --entrypoint bun kernel run stack-driver/take-snight-offer.ts
//
// ── WHY IT IS MOUNTED INTO /app RATHER THAN BAKED INTO AN IMAGE ─────────────
// It has to run in the KERNEL image: taking an Offer File needs the MIP-0005 bech32m codec
// (`@effectstream/mip-zswap-offer/mip5`), ledger-v8's `Transaction`, and the wallet facade the
// kernel tree already installs — none of which the shielded-night image has. Baking it in
// would mean rebuilding the `offerfiles` image for a file only `./verify.sh` runs, i.e.
// changing a profile this project is not changing. Mounted at /app/stack-driver instead: bun
// resolves npm dependencies by walking up from the importing FILE, so a mount anywhere else
// (/mnt/…, /srv/…) would look in /node_modules and find nothing.
//
// ── WHAT "TAKING AN OFFER FILE" IS ──────────────────────────────────────────
// The maker's offer is a deliberately UNBALANCED transaction: it inputs sNight and outputs the
// demanded token back to the maker, and it was finalized with `payFees:false`. The taker
// balances it — supplying the demanded token, claiming the sNight, and paying the fee — and
// submits the result. That is the whole protocol; no relay, no solver, no intermediary is
// involved, which is precisely why an Offer File is worth having.
//
// It follows the MAINTAINED path (`packages/tests/full-lifecycle-e2e.ts`,
// `api-examples/11-settle-offer.ts`): deserialize → `balanceFinalizedTransaction` →
// `finalizeRecipe` → `submitTransaction`, then wait for the kernel to report the offer
// `consumed` (its nullifier spent on chain).

import { registerNightForDust } from "@effectstream/midnight-contracts";
import { midnightNetworkConfig as net } from "@effectstream/midnight-contracts/midnight-env";
import { OfferFiles } from "@effectstream/mip-zswap-offer/mip5";
import { Transaction } from "@midnight-ntwrk/ledger-v8";
import { setNetworkId } from "@midnight-ntwrk/midnight-js-network-id";

import {
  buildWallet,
  shieldedBalances,
  shieldedKeys,
  transferShielded,
  unshieldedAddressObj,
  unshieldedBalances,
  waitForShielded,
  waitForSync,
} from "../packages/solver-core/wallet.ts";

globalThis.WebSocket = WebSocket;
setNetworkId(net.id as never);

const API = (process.env["ZSWAP_API"] ?? "http://kernel:9999").replace(/\/$/, "");
const TAKER_SEED = required("TAKER_SEED");
/** The wallet the demo colours were minted to — the only one that can hand the taker some. */
const FUNDER_SEED = required("FUNDER_SEED");
const SNIGHT_COLOR = hex64("SNIGHT_COLOR");
const WANT_TOKEN = hex64("WANT_TOKEN");
const GIVE_AMOUNT = amount("GIVE_AMOUNT");
const WANT_AMOUNT = amount("WANT_AMOUNT");

const NIGHT = "0".repeat(64);
/** A dust coin's capacity is tied to the size of the NIGHT UTXO backing it, so a couple of
 *  large UTXOs are usable immediately where many tiny ones are worthless for days. The same
 *  two numbers the kernel tree's own e2e driver funds its taker with. */
const NIGHT_PER_UTXO = 5_000_000_000_000n;
const NIGHT_UTXO_COUNT = 2;
/** One undeployed block between two submits from the SAME wallet: the SDK's dust-spend
 *  accounting has not yet seen the chain notification for the previous one, and a transaction
 *  built against that state is rejected outright (`1010: Custom error: 170`). */
const SUBMIT_SETTLE_MS = 8_000;
const STATUS_TIMEOUT_MS = Number(process.env["TAKE_STATUS_TIMEOUT_MS"] ?? "300000");
const BALANCE_TIMEOUT_MS = Number(process.env["TAKE_BALANCE_TIMEOUT_MS"] ?? "300000");

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (msg: string): void => console.error(`[take-snight] ${msg}`);
const die = (msg: string): never => {
  console.error(`[take-snight] FATAL: ${msg}`);
  process.exit(1);
};

function required(name: string): string {
  const v = process.env[name]?.trim();
  if (!v) return die(`missing required environment: ${name}`);
  return v;
}
function hex64(name: string): string {
  const v = required(name).toLowerCase().replace(/^0x/, "");
  if (!/^[0-9a-f]{64}$/.test(v)) return die(`${name} must be 64 hex characters, got "${v}"`);
  return v;
}
/** `BigInt("")` is 0n rather than an error — a knob left blank must be fatal, not a take of nothing. */
function amount(name: string): bigint {
  const v = required(name);
  if (!/^[0-9]+$/.test(v)) return die(`${name} must be a non-negative integer, got "${v}"`);
  const n = BigInt(v);
  if (n <= 0n) return die(`${name} must be greater than zero`);
  return n;
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

/** THE offer: the live one giving exactly GIVE_AMOUNT of sNight for WANT_AMOUNT of WANT_TOKEN.
 *  Matched on all four values, not on "the first offer in the book": a stack that also ran the
 *  DEVA/DEVB seeding offer has more than one, and taking the wrong one would still settle. */
async function findOffer(): Promise<OfferRow> {
  const { offers } = await getJson<{ offers: OfferRow[] }>(
    `/v1/offers?token=${SNIGHT_COLOR}&direction=GIVING&limit=100`,
  );
  const match = offers.find(
    (o) =>
      o.computed.gives.some((g) => g.token === SNIGHT_COLOR && BigInt(g.amount) === GIVE_AMOUNT) &&
      o.computed.wants.some((w) => w.token === WANT_TOKEN && BigInt(w.amount) === WANT_AMOUNT),
  );
  if (!match) {
    return die(
      `no live offer gives ${GIVE_AMOUNT} sNight for ${WANT_AMOUNT} of ${WANT_TOKEN.slice(0, 12)}… ` +
        `(the book has ${offers.length} offer(s) on that colour)`,
    );
  }
  return match;
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
  const deadline = Date.now() + BALANCE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (((await unshieldedBalances(taker))[NIGHT] ?? 0n) >= NIGHT_PER_UTXO) break;
    await sleep(5_000);
  }
  log(`taker NIGHT: ${(await unshieldedBalances(taker))[NIGHT] ?? 0n}`);
  await sleep(SUBMIT_SETTLE_MS);
}

/** The token the offer DEMANDS. Without it the taker cannot balance the maker's transaction. */
async function fundTakerWantToken(): Promise<void> {
  const held = (await shieldedBalances(taker))[WANT_TOKEN] ?? 0n;
  if (held >= WANT_AMOUNT) {
    log(`taker already holds ${held} of the demanded token (needs ${WANT_AMOUNT})`);
    return;
  }
  const funding = WANT_AMOUNT * 4n;
  log(`taker holds ${held} of the demanded token — transferring ${funding}`);
  const takerShielded = await taker.wallet.shielded.getAddress();
  let lastErr: unknown;
  for (let attempt = 1; attempt <= 8; attempt++) {
    try {
      await transferShielded(funder, WANT_TOKEN, funding, takerShielded);
      lastErr = undefined;
      break;
    } catch (err) {
      lastErr = err;
      log(`  token transfer attempt ${attempt}/8 failed: ${String(err).slice(0, 160)}`);
      await sleep(15_000);
    }
  }
  if (lastErr) die(`could not fund the taker with the demanded token: ${String(lastErr).slice(0, 300)}`);
  const got = await waitForShielded(taker, WANT_TOKEN, WANT_AMOUNT, 60, 5_000);
  if (got < WANT_AMOUNT) die(`taker holds ${got} of the demanded token, needs ${WANT_AMOUNT}`);
  log(`taker demanded-token balance: ${got}`);
  await sleep(SUBMIT_SETTLE_MS);
}

async function main(): Promise<void> {
  log(`kernel   : ${API}`);
  log(`network  : ${net.id}`);
  log(`sNight   : ${SNIGHT_COLOR}  (the taker receives ${GIVE_AMOUNT})`);
  log(`demanded : ${WANT_TOKEN}  (the taker pays ${WANT_AMOUNT})`);

  const offer = await findOffer();
  log(`offer ${offer.offerId.slice(0, 16)}… is live and matches on all four legs`);
  const detail = await getJson<{ offerBech32?: string }>(`/v1/offers/${offer.offerId}`);
  const blob = detail.offerBech32;
  if (typeof blob !== "string" || !blob.startsWith("swapoffer1")) {
    die(`GET /v1/offers/${offer.offerId} returned no swapoffer1… blob`);
  }

  funder = await buildWallet(FUNDER_SEED);
  await waitForSync(funder, { requireUnshieldedFunds: true });
  log(`funder wallet synced (seed …${FUNDER_SEED.slice(-4)})`);
  taker = await buildWallet(TAKER_SEED);
  await waitForSync(taker);
  log(`taker wallet synced (seed …${TAKER_SEED.slice(-4)})`);

  await fundTakerNight();
  await registerNightForDust(taker as any);
  log("taker registered NIGHT for DUST");
  await fundTakerWantToken();

  const snightBefore = (await shieldedBalances(taker))[SNIGHT_COLOR] ?? 0n;
  const wantBefore = (await shieldedBalances(taker))[WANT_TOKEN] ?? 0n;
  log(`taker before: sNight ${snightBefore}, demanded token ${wantBefore}`);

  log("balancing the maker's offer file and settling it on chain (proving…)");
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

  // EXACT deltas, both directions. "+sNight" alone would also be satisfied by a taker that
  // paid nothing, which is exactly the failure an unbalanced settlement would be.
  const snightAfter = await waitForShielded(taker, SNIGHT_COLOR, snightBefore + GIVE_AMOUNT, 60, 5_000);
  const wantAfter = (await shieldedBalances(taker))[WANT_TOKEN] ?? 0n;
  if (snightAfter !== snightBefore + GIVE_AMOUNT) {
    die(`taker sNight went ${snightBefore} -> ${snightAfter}, expected +${GIVE_AMOUNT}`);
  }
  if (wantAfter !== wantBefore - WANT_AMOUNT) {
    die(`taker demanded-token went ${wantBefore} -> ${wantAfter}, expected -${WANT_AMOUNT}`);
  }
  log(`taker after: sNight ${snightAfter} (+${GIVE_AMOUNT}), demanded token ${wantAfter} (-${WANT_AMOUNT})`);

  console.log(
    `SNIGHT_TAKE_RESULT offerId=${offer.offerId} status=${status} ` +
      `snightBefore=${snightBefore} snightAfter=${snightAfter} ` +
      `wantBefore=${wantBefore} wantAfter=${wantAfter} ` +
      `giveAmount=${GIVE_AMOUNT} wantAmount=${WANT_AMOUNT}`,
  );
}

main().then(
  async () => {
    await funder?.wallet?.stop?.().catch(() => {});
    await taker?.wallet?.stop?.().catch(() => {});
    process.exit(0);
  },
  async (e: unknown) => {
    console.error(`[take-snight] failed: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`);
    await funder?.wallet?.stop?.().catch(() => {});
    await taker?.wallet?.stop?.().catch(() => {});
    process.exit(1);
  },
);

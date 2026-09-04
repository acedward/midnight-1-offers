// take-poster-offer.ts — a second wallet TAKES one of the offer poster's offers, and the
// settlement is asserted on the taker's own balances.
//
//   docker compose run --rm --no-deps -T \
//     -v "$REPO_ROOT/scripts/driver:/app/stack-driver:ro" \
//     -e TAKER_SEED=… -e FUNDER_SEED=… -e GIVE_TOKEN_NAME=WBTC -e WANT_TOKEN_NAME=WETH \
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
// ── WHY IT IS NOT take-snight-offer.ts WITH DIFFERENT COLOURS ───────────────
// One step differs, and it is the step that decides whether this can work at all: HOW THE
// TAKER GETS THE TOKEN THE OFFER DEMANDS.
//
// The sNight chain's taker is funded by a TRANSFER from genesis-1, because genesis-1 is the
// wallet the deploy one-shot's mint credited and therefore the only one holding the demanded
// colour. The poster's want leg is a FAUCET PRESET (WETH by default), and NOTHING on this
// stack holds one: the deploy one-shot mints DEVA/DEVB/DEVU, and the presets exist only when
// somebody presses the SPA faucet or the poster mints its give leg. So there is no funder to
// transfer from — the taker MINTS the demanded token itself, through the same faucet circuit
// and the same `mintFaucetToken` helper the poster uses for its give leg. It still needs
// NIGHT (hence DUST, hence a fee) from genesis, which is the one thing genesis can give it.
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

import { readFileSync } from "node:fs";

import { registerNightForDust, waitForDustFunds } from "@effectstream/midnight-contracts";
import { midnightNetworkConfig as net } from "@effectstream/midnight-contracts/midnight-env";
import { OfferFiles } from "@effectstream/mip-zswap-offer/mip5";
import { Transaction } from "@midnight-ntwrk/ledger-v8";
import { setNetworkId } from "@midnight-ntwrk/midnight-js-network-id";

import {
  expectedColour,
  freshNonce,
  mintFaucetToken,
} from "../deploy/scripts/lib/faucet-mint.ts";
import { joinOfferFiles } from "../packages/solver-core/offer-files.ts";
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
/** The poster's two legs, as NAMES: the colours derive from the contract address offline,
 *  exactly as the poster derives them, so the two sides cannot disagree. */
const GIVE_TOKEN_NAME = (process.env["GIVE_TOKEN_NAME"] ?? "WBTC").trim() || "WBTC";
const WANT_TOKEN_NAME = (process.env["WANT_TOKEN_NAME"] ?? "WETH").trim() || "WETH";
const CONTRACT_SHARE_DIR = process.env["CONTRACT_SHARE_DIR"] ?? "/srv/offerfiles-deploy";

const NIGHT = "0".repeat(64);
/** The same two numbers the kernel tree's own e2e driver funds its taker with. */
const NIGHT_PER_UTXO = 5_000_000_000_000n;
const NIGHT_UTXO_COUNT = 2;
/** One undeployed block between two submits from the SAME wallet: the SDK's dust-spend
 *  accounting has not yet seen the chain notification for the previous one, and a
 *  transaction built against that state is rejected outright (`1010: Custom error: 170`). */
const SUBMIT_SETTLE_MS = 8_000;
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

/** MIDNIGHT_CONTRACT_ADDRESS if the caller knows it, else the deploy one-shot's own file on
 *  the shared volume — the same two sources, in the same order, entrypoint-common.sh uses. */
function contractAddress(): string {
  const fromEnv = process.env["MIDNIGHT_CONTRACT_ADDRESS"]?.trim();
  if (fromEnv) return fromEnv;
  const file = `${CONTRACT_SHARE_DIR}/contract-offer-files.${net.id}.json`;
  try {
    const json = JSON.parse(readFileSync(file, "utf-8")) as { contractAddress?: string };
    if (typeof json.contractAddress === "string" && json.contractAddress.length > 0) {
      return json.contractAddress;
    }
    return die(`${file} carries no string contractAddress`);
  } catch (err) {
    return die(`cannot read ${file}: ${String(err).slice(0, 200)}`);
  }
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
  const address = contractAddress();
  const giveColour = expectedColour(GIVE_TOKEN_NAME, address);
  const wantColour = expectedColour(WANT_TOKEN_NAME, address);
  log(`kernel   : ${API}`);
  log(`network  : ${net.id}`);
  log(`contract : ${address}`);
  log(`give     : ${GIVE_TOKEN_NAME} ${giveColour}  (the taker receives it)`);
  log(`want     : ${WANT_TOKEN_NAME} ${wantColour}  (the taker mints it and pays it)`);

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

  // The token the offer DEMANDS. A MINT rather than a transfer — see this file's header.
  // Minting is a contract call and therefore pays a fee, so the DUST has to be there first;
  // upstream's poster waits the same way before its own first mint.
  const wantHeld = (await shieldedBalances(taker))[wantColour] ?? 0n;
  if (wantHeld < wantAmount) {
    const dust = await waitForDustFunds(taker.wallet as any, {
      timeoutMs: DUST_WAIT_MS,
      waitNonZero: true,
    });
    log(`taker DUST balance: ${dust}`);
    // Twice the demand, so the balancer has room for a change output and the taker is not
    // left needing a second mint if the offer it takes is a large one from a size range.
    const mintAmount = wantAmount * 2n;
    log(`taker holds ${wantHeld} ${WANT_TOKEN_NAME} — minting ${mintAmount} from the faucet circuit (proving…)`);
    const deployed = await joinOfferFiles(taker as never, address);
    const minted = await mintFaucetToken(deployed as never, WANT_TOKEN_NAME, mintAmount, freshNonce(), {
      contractAddress: address,
      coinSecretKey: () => (taker as any).zswapSecretKeys.coinSecretKey,
    });
    if (minted.colour !== wantColour) {
      die(`the mint landed on colour ${minted.colour}, expected ${wantColour}`);
    }
    const got = await waitForShielded(taker, wantColour, wantAmount, 60, 5_000);
    if (got < wantAmount) die(`taker holds ${got} ${WANT_TOKEN_NAME}, needs ${wantAmount}`);
    log(`taker ${WANT_TOKEN_NAME} balance: ${got}`);
    await sleep(SUBMIT_SETTLE_MS);
  } else {
    log(`taker already holds ${wantHeld} ${WANT_TOKEN_NAME} (needs ${wantAmount})`);
  }

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

// m1/fund.ts — mint an EXACT, caller-chosen amount of ONE named issuer token to ONE wallet,
// headlessly. THE FUNDING PRIMITIVE every other profile's provisioning calls.
//
//   docker compose run --rm issuer-fund TWBTC 100000000 <recipient-seed-hex>
//   docker compose run --rm issuer-fund TWETH 5000000000000000000 @/run/secrets/taker.hex
//   docker compose run --rm issuer-fund TWBTC 1000000 <poster-seed-hex> 12   <- TWELVE coins
//
// ── COUNT: N SEPARATE COINS OF THE SAME EXACT SIZE (00020 PR C) ─────────────
// The 4th argument mints the same amount N times in ONE process, i.e. N DISTINCT COINS each
// worth exactly `amount`, and asserts the recipient's balance moved by exactly `N x amount`
// AND that N new coins of exactly that value appeared in its `availableCoins`.
//
// That is not a convenience: since kernel #69 the offer poster never mints, and
// `selectInventoryCoin()` picks one unjournaled spendable coin whose value EQUALS
// `OFFER_POSTER_GIVE_AMOUNT` — not one worth at least that much. A single large coin is
// therefore useless to it, N coins of the exact size are its whole inventory, and the
// difference between "the balance is right" and "there are N spendable coins of the right
// size" is the difference between a poster that posts and one that reports
// `degraded: insufficient_inventory` for ever.
//
// ONE PROCESS, N MINTS, because the fixed cost dominates: building and syncing two wallet
// facades is most of a single `issuer-fund` call, and paying it N times would put tens of
// minutes into a bring-up. Each mint is still its own proving transaction with its own fresh
// nonce and its own tx hash; they are submitted in sequence, never in parallel, because they
// all spend the issuer's DUST and a second recipe built before the first confirms is rejected
// outright (`1010 … Custom error: 170` — the same hazard upstream's own funding retries).
//
// Invoked through entrypoint-fund.sh (`issuer-fund`), which parses the CLI, writes the seeds
// to a tmpfs and holds a `flock` so two runs cannot open two facades on the issuer's seed.
//
// ── WHY NOT `npm run test:wallet:v1` ────────────────────────────────────────
// That runner is the code pattern this file follows, and it is not a funding tool:
//   * it mints each token's FIXED faucet preset (`definition.faucet.baseUnits`) — a caller
//     cannot size a coin, and the poster/solver/e2e provisioning all need specific sizes;
//   * it walks ALL SIX tokens unless MN_TOKEN_SYMBOL narrows it;
//   * it reads the registry from `metadata/metadata.<network>.json` inside the repository,
//     not from the shared volume this stack publishes to;
//   * it then SPENDS the minted coin back to the deployer, which is the point of a round-trip
//     test and the opposite of funding;
//   * it requires the recipient to be reachable as a SEED FILE and syncs it — which this does
//     too, deliberately, because that is how the balance is read back.
//
// The contract's own `mint` circuit is what makes an exact mint possible at all: upstream
// documents it as "a positive, caller-selected `Uint<64>` mint amount" and "Website faucet
// presets are registry metadata and are not enforced by the contracts".
//
// ── THE RECEIPT IS THE INTERFACE (phase C reads this line) ───────────────────
//   ISSUER_FUND_RESULT token=<NAME> symbol=<symbol> tokenId=<64 hex> privacy=<shielded|unshielded>
//                      decimals=<n> amount=<base units> count=<n> minted=<base units>
//                      recipient=<…last 4 of seed> tx=<hash of the LAST mint>
//                      balanceBefore=<base units> balanceAfter=<base units>
//                      delta=<base units> coinsBefore=<n> coinsAfter=<n> coinsAdded=<n>
//                      verified=<true|false> seconds=<n>
//
// `count`/`coinsAdded` are 1 for an ordinary single mint, so a caller that only greps
// `delta=` keeps working.
//
// EXIT CODES: 0 minted and (unless verification was switched off) read back exactly;
//             78 EX_CONFIG — a bad argument, an unknown token, no registry;
//             1  the mint or the read-back failed.
//
// ── AMOUNTS ARE STRINGS AND BIGINTS, NEVER NUMBERS ──────────────────────────
// twETH has 18 decimals, so one whole coin is 10^18 base units — past `Number.MAX_SAFE_INTEGER`
// by two orders of magnitude. Every amount here is parsed with `BigInt`, compared as `bigint`
// and printed with `String`, and the argument is required to be plain decimal digits so a
// caller cannot smuggle `1e18` past it.

import { randomBytes } from "node:crypto";
import { resolve } from "node:path";
import { CompiledContract } from "@midnight-ntwrk/compact-js";
import { findDeployedContract, withContractScopedTransaction } from "@midnight-ntwrk/midnight-js-contracts";
import { initializeMidnightProviders } from "@midnight-ntwrk/testkit-js";
import { filter, firstValueFrom, timeout } from "rxjs";
import * as Shielded from "../contracts/v1/managed/shielded/contract/index.js";
import * as Unshielded from "../contracts/v1/managed/unshielded/contract/index.js";
import {
  ROOT,
  TIMEOUT_MS,
  buildFacade,
  findToken,
  loadReadyRegistry,
  log,
  readSeedFile,
  walletEnv,
  waitSynced,
  withTimeout
} from "./lib.js";

const ROLE = "issuer-fund";
const say = (message: string): void => log(ROLE, message);
const bail = (message: string): never => {
  say(message);
  process.exit(78);
};

const wantedToken = (process.env.ISSUER_FUND_TOKEN ?? "").trim();
const wantedAmount = (process.env.ISSUER_FUND_AMOUNT ?? "").trim();
const wantedCount = (process.env.ISSUER_FUND_COUNT ?? "1").trim();
const verifyReadBack = (process.env.ISSUER_FUND_VERIFY ?? "1").trim() !== "0";

if (!wantedToken) bail("ISSUER_FUND_TOKEN is empty — usage: issuer-fund <TOKEN> <base-units> <recipient-seed>");
// Plain decimal digits only. `BigInt("1e18")` throws and `BigInt(" 10 ")` does not, so the
// shape is checked here rather than left to the constructor's own idea of leniency.
if (!/^[0-9]+$/.test(wantedAmount)) {
  bail(`ISSUER_FUND_AMOUNT must be plain decimal base units, got "${wantedAmount}"`);
}
const amount = BigInt(wantedAmount);
// The contract's own precondition ("a positive, caller-selected Uint<64> amount"), checked
// before a wallet is built so a zero costs no sync time. The upper bound is the circuit's.
if (amount <= 0n) bail(`ISSUER_FUND_AMOUNT must be positive, got ${amount}`);
if (amount >= 1n << 64n) bail(`ISSUER_FUND_AMOUNT ${amount} does not fit the contract's Uint<64>`);
// The count is a small integer, and it is bounded because each unit of it is a proving
// transaction: 200 mints is over an hour of bring-up, which is a mistake worth refusing
// rather than discovering. The refill command is in docs/OPERATIONS.md for anyone who wants
// more than that.
if (!/^[0-9]+$/.test(wantedCount)) {
  bail(`ISSUER_FUND_COUNT must be plain decimal digits, got "${wantedCount}"`);
}
const count = Number(wantedCount);
if (count < 1) bail(`ISSUER_FUND_COUNT must be at least 1, got ${count}`);
if (count > 200) {
  bail(`ISSUER_FUND_COUNT ${count} is above the cap of 200 — each coin is a separate proving transaction`);
}
const totalAmount = amount * BigInt(count);
if (totalAmount >= 1n << 64n) {
  bail(`ISSUER_FUND_COUNT ${count} x ${amount} = ${totalAmount} does not fit a Uint<64> balance`);
}

const { registry, path: registryFile } = await loadReadyRegistry().catch((error) =>
  bail(`${error instanceof Error ? error.message : String(error)}`)
);
const token = (() => {
  try {
    return findToken(registry, wantedToken);
  } catch (error) {
    return bail(`${error instanceof Error ? error.message : String(error)}`);
  }
})();

const issuerSeed = await readSeedFile(
  process.env.MN_SEED_FILE?.trim() || bail("MN_SEED_FILE must name the issuer's seed file"),
  "MN_SEED_FILE"
).catch((error) => bail(`MN_SEED_FILE: ${error instanceof Error ? error.message : String(error)}`));

const recipientSeed = await readSeedFile(
  process.env.MN_RECIPIENT_SEED_FILE?.trim() || bail("MN_RECIPIENT_SEED_FILE must name the recipient's seed file"),
  "MN_RECIPIENT_SEED_FILE"
).catch((error) => bail(`MN_RECIPIENT_SEED_FILE: ${error instanceof Error ? error.message : String(error)}`));

// ONE FACADE PER SEED (wallets/wallets.json). Minting to the issuer's own wallet would open two
// facades on one seed inside this very process; refuse rather than deadlock.
if (issuerSeed === recipientSeed) {
  bail("the recipient seed IS the issuer seed — one wallet facade per seed; nothing to fund");
}

const artifactPath = resolve(ROOT, "contracts", "v1", "managed", token.privacy);
const contractModule = token.privacy === "shielded" ? Shielded : Unshielded;
const zero = new Uint8Array(32);
const bytes = (hex: string): Uint8Array => Uint8Array.from(Buffer.from(hex, "hex"));

say(`registry ${registryFile} revision ${registry.registryRevision.slice(0, 16)}…`);
say(
  `${token.name} (${token.symbol}) ${token.privacy} ${token.decimals} decimals ` +
    `id ${token.tokenId} at ${token.contractAddress}`
);
if (count === 1) {
  say(`minting ${amount} base units (= ${formatWhole(amount, token.decimals)} ${token.name})`);
} else {
  say(
    `minting ${count} SEPARATE coins of ${amount} base units each ` +
      `(= ${formatWhole(amount, token.decimals)} ${token.name} per coin, ` +
      `${formatWhole(totalAmount, token.decimals)} ${token.name} in total)`
  );
}

/** Exact decimal rendering, for the log only. String arithmetic: 10n ** 18n as a Number would
 *  lose digits, and this line is read by humans deciding whether a number looks right. */
function formatWhole(value: bigint, decimals: number): string {
  if (decimals === 0) return value.toString();
  const scale = 10n ** BigInt(decimals);
  const whole = value / scale;
  const fraction = (value % scale).toString().padStart(decimals, "0").replace(/0+$/, "");
  return fraction ? `${whole}.${fraction}` : whole.toString();
}

function balanceOf(state: any, privacy: "shielded" | "unshielded", tokenId: string): bigint {
  const balances = privacy === "shielded" ? state?.shielded?.balances : state?.unshielded?.balances;
  return (balances?.[tokenId] as bigint | undefined) ?? 0n;
}

/**
 * How many SPENDABLE COINS of exactly `value` this wallet holds for `tokenId`.
 *
 * The balance is not the assertion a poster needs. `selectInventoryCoin()` in the pinned
 * kernel picks one unjournaled spendable coin whose `value` EQUALS the configured
 * `GIVE_AMOUNT`, so "10 000 000 base units" split as one coin and as ten coins of 1 000 000
 * are completely different inventories and only the second one is postable.
 *
 * `availableCoins` is the same field the poster's own wallet facade reads. It is read
 * defensively because a wallet state that has not produced the array yet must count as zero
 * rather than throw — the caller compares BEFORE and AFTER, so an unavailable field simply
 * makes the coin assertion vacuous instead of wrong, and the balance assertion still holds.
 * `coinsAvailable=false` is then reported in the receipt rather than hidden.
 *
 * ── THE ENTRY IS A WRAPPER, AND THE TWO SIDES WRAP DIFFERENTLY ──────────────
 * MEASURED on facade 4.0.1 against this stack rather than assumed, after the first version of
 * this function read `entry.type` / `entry.value` and counted ZERO coins for a mint that had
 * in fact landed perfectly (balance and coin count both correct on chain):
 *
 *   shielded    { coin: { type, nonce, value, mt_index }, commitment, nullifier }
 *   unshielded  { utxo: { value, owner, type, intentHash, outputNo }, meta: {…} }
 *
 * So the token id and the amount live one level down, under a DIFFERENT key on each side, and
 * `value` is a decimal STRING rather than a bigint. `entry.coin ?? entry.utxo ?? entry` covers
 * both shapes and still works if a future facade flattens them; the `type`/`tokenType` and
 * `value`/`amount` alternatives cost nothing and mean a field rename degrades to
 * `coinsAvailable=false` rather than to a wrong count.
 */
function coinsOf(
  state: any,
  privacy: "shielded" | "unshielded",
  tokenId: string,
  value: bigint
): { count: number; available: boolean } {
  const side = privacy === "shielded" ? state?.shielded : state?.unshielded;
  const coins = side?.availableCoins;
  if (!Array.isArray(coins)) return { count: 0, available: false };
  let matched = 0;
  let shapeSeen = false;
  for (const entry of coins) {
    const inner = (entry as any)?.coin ?? (entry as any)?.utxo ?? entry;
    const type = String(inner?.type ?? inner?.tokenType ?? "").toLowerCase();
    if (!type) continue;
    shapeSeen = true;
    if (type !== tokenId.toLowerCase()) continue;
    let amountValue: bigint;
    try {
      amountValue = BigInt(inner?.value ?? inner?.amount ?? 0);
    } catch {
      continue;
    }
    if (amountValue === value) matched += 1;
  }
  // An EMPTY array is a legitimate "this wallet holds nothing" and must count as available —
  // that is the BEFORE reading of every first mint. A NON-empty array whose entries expose no
  // recognisable token id is a shape this function does not understand, and saying so is the
  // honest answer: the assertion then goes vacuous instead of failing a correct mint.
  if (coins.length > 0 && !shapeSeen) return { count: 0, available: false };
  return { count: matched, available: true };
}

let issuer: Awaited<ReturnType<typeof buildFacade>> | undefined;
let recipient: Awaited<ReturnType<typeof buildFacade>> | undefined;
let exitCode = 1;

try {
  // Built in parallel and started in parallel: two different seeds, and the sync of a fresh
  // recipient wallet on a live chain is the slowest part of this command.
  [issuer, recipient] = await Promise.all([
    buildFacade("issuer-fund/issuer", issuerSeed),
    buildFacade("issuer-fund/recipient", recipientSeed)
  ]);

  const [issuerState, recipientState] = await Promise.all([
    waitSynced(issuer.provider, "the issuer wallet"),
    waitSynced(recipient.provider, "the recipient wallet")
  ]);
  const issuerDust = (issuerState?.dust && typeof issuerState.dust.balance === "function"
    ? issuerState.dust.balance(new Date())
    : 0n) as bigint;
  say(`issuer synced, spendable DUST ${issuerDust}`);
  if (issuerDust <= 0n) {
    // Named here rather than discovered inside the SDK: a mint is a proving transaction and it
    // is paid for in DUST. The remedy is the issuer-deploy one-shot, which registers the
    // issuer's NIGHT — see docs/OPERATIONS.md.
    throw new Error(
      "the issuer wallet has no spendable DUST, so it cannot pay for a mint. " +
        "Re-run the issuer-deploy one-shot (it funds and DUST-registers this wallet)."
    );
  }

  const before = balanceOf(recipientState, token.privacy, token.tokenId);
  const coinsBefore = coinsOf(recipientState, token.privacy, token.tokenId, amount);
  say(
    `recipient balance before: ${before}` +
      (coinsBefore.available ? ` (${coinsBefore.count} coin(s) of exactly ${amount})` : "")
  );

  const providers = initializeMidnightProviders(issuer.provider, walletEnv, {
    // Under `.local`, which is the `issuer-state` volume: the same place the deploy runner keeps
    // its own private state, so "start over" stays ONE operation (`./down.sh -v`).
    privateStateStoreName: resolve(ROOT, ".local", "private-state", "m1-fund"),
    zkConfigPath: artifactPath
  });
  const compiled = CompiledContract.make(
    `mint-test-token-${token.privacy}`,
    (contractModule as any).Contract as never
  ).pipe(CompiledContract.withVacantWitnesses, CompiledContract.withCompiledFileAssets(artifactPath));
  const contract = await withTimeout(
    `${token.name} contract join`,
    findDeployedContract(providers as never, {
      compiledContract: compiled as never,
      contractAddress: token.contractAddress
    } as never)
  );

  // ── THE MINT ──────────────────────────────────────────────────────────────
  // The two unions are ordered DIFFERENTLY on purpose, and upstream says so
  // ("The different union ordering is intentional"):
  //   shielded    mint(Either<ZswapCoinPublicKey, ContractAddress>, Uint<64>, Bytes<32> nonce)
  //   unshielded  mint(Either<ContractAddress, UserAddress>,        Uint<64>)
  // So `is_left: true` means "a shielded user" for the shielded issuer and "a contract" for the
  // unshielded one. Getting this backwards mints to a 32-byte zero recipient, which the
  // contract's own `recipientIsZero` guard rejects — loudly, which is why it is safe to say so.
  //
  // `additionalCoinEncPublicKeyMappings` is what makes a THIRD-PARTY shielded mint DISCOVERABLE:
  // midnight-js then creates the normal encrypted Zswap output for that recipient, and the
  // recipient's own chain scan finds it. Without it the coin exists and no wallet can see it.
  const coinPublicKey = recipient.provider.getCoinPublicKey();
  const encryptionPublicKey = recipient.provider.getEncryptionPublicKey();
  const userAddress = recipient.provider.unshieldedKeystore.getAddress();

  /** ONE mint of exactly `amount`, with its own fresh nonce. */
  const mintOne = (): Promise<unknown> => {
    const nonce = Uint8Array.from(randomBytes(32));
    return token.privacy === "shielded"
      ? withContractScopedTransaction(
          providers as never,
          async (txContext: never) => {
            await (contract as any).callTx.mint(
              txContext,
              { is_left: true, left: { bytes: bytes(coinPublicKey) }, right: { bytes: zero } },
              amount,
              nonce
            );
          },
          { additionalCoinEncPublicKeyMappings: new Map([[coinPublicKey, encryptionPublicKey]]) } as never
        )
      : withContractScopedTransaction(providers as never, async (txContext: never) => {
          await (contract as any).callTx.mint(
            txContext,
            { is_left: false, left: { bytes: zero }, right: { bytes: bytes(userAddress) } },
            amount
          );
        });
  };

  // SEQUENTIAL, never parallel. Every mint spends the issuer's DUST, and a recipe built
  // before the previous submit's chain notification has been observed is rejected outright
  // (`1010: Invalid Transaction: Custom error: 170`) — upstream's own funding paths retry for
  // exactly this reason. `withContractScopedTransaction` awaits finalisation, so awaiting each
  // call in turn IS the serialisation; nothing extra is needed and no sleep is guessed at.
  const mintStart = Date.now();
  const txIds: string[] = [];
  for (let index = 0; index < count; index += 1) {
    const finalized: any = await withTimeout(
      count === 1 ? `${token.name} mint` : `${token.name} mint ${index + 1}/${count}`,
      mintOne() as Promise<any>
    );
    const txId = String(finalized?.public?.txId ?? "");
    txIds.push(txId);
    if (count === 1) {
      say(`mint finalized, tx ${txId || "<unreported>"}`);
    } else {
      say(
        `mint ${index + 1}/${count} finalized after ${Math.round((Date.now() - mintStart) / 1000)}s, ` +
          `tx ${txId || "<unreported>"}`
      );
    }
  }
  const txId = txIds[txIds.length - 1] ?? "";

  let after = before;
  let coinsAfter = coinsBefore;
  let verified = false;
  if (verifyReadBack) {
    // THE READ-BACK IS THE POINT. "The transaction was accepted" and "the recipient can spend
    // this coin" are different claims, and only the second one is what a provisioning one-shot
    // needs. Waited for on the RECIPIENT's own view, which is the wallet that will spend it.
    //
    // The predicate waits for the WHOLE total: with count > 1 the intermediate states are all
    // legitimate partial credits, and stopping at the first one would report a wrong delta.
    const state: any = await firstValueFrom(
      recipient.provider.wallet.state().pipe(
        filter(
          (value: any) =>
            value.isSynced === true &&
            balanceOf(value, token.privacy, token.tokenId) >= before + totalAmount
        ),
        timeout({ first: TIMEOUT_MS })
      )
    ).catch((error) => {
      throw new Error(
        `the recipient's ${token.name} balance did not reach ${before + totalAmount}: ` +
          `${error instanceof Error ? error.message : String(error)}`
      );
    });
    after = balanceOf(state, token.privacy, token.tokenId);
    // EXACTLY the amount, not merely at least it. A mint that credited more than it was asked
    // for is as much a defect as one that credited less, and this helper's whole promise is
    // "exact".
    if (after - before !== totalAmount) {
      throw new Error(
        `the recipient's ${token.name} balance moved by ${after - before}, not the ${totalAmount} minted`
      );
    }
    coinsAfter = coinsOf(state, token.privacy, token.tokenId, amount);
    // THE COIN COUNT, and it is not the same claim as the balance. A poster whose GIVE_AMOUNT
    // is 1000000 cannot post a single coin of 12000000, so a caller that asked for 12 coins
    // and got the right total in the wrong shape has NOT been provisioned. Only asserted when
    // the wallet actually exposed `availableCoins` — see coinsOf().
    if (coinsBefore.available && coinsAfter.available) {
      const added = coinsAfter.count - coinsBefore.count;
      if (added !== count) {
        throw new Error(
          `the recipient gained ${added} spendable coin(s) of exactly ${amount} ${token.name}, ` +
            `not the ${count} minted (before ${coinsBefore.count}, after ${coinsAfter.count}). ` +
            `A consumer that selects a coin BY EXACT VALUE — the offer poster does — needs ${count}`
        );
      }
    }
    verified = true;
    say(
      `recipient balance after: ${after} (delta ${after - before})` +
        (coinsAfter.available
          ? `, ${coinsAfter.count} coin(s) of exactly ${amount} (was ${coinsBefore.count})`
          : ", availableCoins not exposed by this wallet state")
    );
  } else {
    say("ISSUER_FUND_VERIFY=0 — not reading the recipient's balance back");
  }

  process.stdout.write(
    `ISSUER_FUND_RESULT token=${token.name} symbol=${token.symbol} tokenId=${token.tokenId} ` +
      `privacy=${token.privacy} decimals=${token.decimals} amount=${amount} count=${count} ` +
      `minted=${totalAmount} recipient=…${recipientSeed.slice(-4)} tx=${txId} ` +
      `balanceBefore=${before} balanceAfter=${after} delta=${after - before} ` +
      `coinsBefore=${coinsBefore.count} coinsAfter=${coinsAfter.count} ` +
      `coinsAdded=${coinsAfter.count - coinsBefore.count} coinsAvailable=${coinsAfter.available} ` +
      `verified=${verified} seconds=${Math.round((Date.now() - mintStart) / 1000)}\n`
  );
  exitCode = 0;
} catch (error) {
  say(`FATAL: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
  exitCode = 1;
} finally {
  await recipient?.stop();
  await issuer?.stop();
}

process.exit(exitCode);

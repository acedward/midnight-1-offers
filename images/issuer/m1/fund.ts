// m1/fund.ts — mint an EXACT, caller-chosen amount of ONE named issuer token to ONE wallet,
// headlessly. THE FUNDING PRIMITIVE every other profile's provisioning calls.
//
//   docker compose run --rm issuer-fund TWBTC 100000000 <recipient-seed-hex>
//   docker compose run --rm issuer-fund TWETH 5000000000000000000 @/run/secrets/taker.hex
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
//                      decimals=<n> amount=<base units> recipient=<…last 4 of seed>
//                      tx=<hash> balanceBefore=<base units> balanceAfter=<base units>
//                      delta=<base units> verified=<true|false>
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
say(`minting ${amount} base units (= ${formatWhole(amount, token.decimals)} ${token.name})`);

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
  say(`recipient balance before: ${before}`);

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
  const nonce = Uint8Array.from(randomBytes(32));
  const coinPublicKey = recipient.provider.getCoinPublicKey();
  const encryptionPublicKey = recipient.provider.getEncryptionPublicKey();
  const userAddress = recipient.provider.unshieldedKeystore.getAddress();

  const mint =
    token.privacy === "shielded"
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

  const finalized: any = await withTimeout(`${token.name} mint`, mint as Promise<any>);
  const txId = String(finalized?.public?.txId ?? "");
  say(`mint finalized, tx ${txId || "<unreported>"}`);

  let after = before;
  let verified = false;
  if (verifyReadBack) {
    // THE READ-BACK IS THE POINT. "The transaction was accepted" and "the recipient can spend
    // this coin" are different claims, and only the second one is what a provisioning one-shot
    // needs. Waited for on the RECIPIENT's own view, which is the wallet that will spend it.
    const state: any = await firstValueFrom(
      recipient.provider.wallet.state().pipe(
        filter(
          (value: any) =>
            value.isSynced === true && balanceOf(value, token.privacy, token.tokenId) >= before + amount
        ),
        timeout({ first: TIMEOUT_MS })
      )
    ).catch((error) => {
      throw new Error(
        `the recipient's ${token.name} balance did not reach ${before + amount}: ` +
          `${error instanceof Error ? error.message : String(error)}`
      );
    });
    after = balanceOf(state, token.privacy, token.tokenId);
    // EXACTLY the amount, not merely at least it. A mint that credited more than it was asked
    // for is as much a defect as one that credited less, and this helper's whole promise is
    // "exact".
    if (after - before !== amount) {
      throw new Error(
        `the recipient's ${token.name} balance moved by ${after - before}, not the ${amount} minted`
      );
    }
    verified = true;
    say(`recipient balance after: ${after} (delta ${after - before})`);
  } else {
    say("ISSUER_FUND_VERIFY=0 — not reading the recipient's balance back");
  }

  process.stdout.write(
    `ISSUER_FUND_RESULT token=${token.name} symbol=${token.symbol} tokenId=${token.tokenId} ` +
      `privacy=${token.privacy} decimals=${token.decimals} amount=${amount} ` +
      `recipient=…${recipientSeed.slice(-4)} tx=${txId} balanceBefore=${before} ` +
      `balanceAfter=${after} delta=${after - before} verified=${verified}\n`
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

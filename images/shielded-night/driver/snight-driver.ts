// snight-driver.ts — the three things the BOOK CHAIN needs from the shielded-night side of
// this stack, and nothing else:
//
//   color    print the sNight token colour derived from the contract THIS STACK deployed
//   wrap     NIGHT -> sNight for the driver wallet, against that same deployed contract
//   unwrap   sNight -> NIGHT for a named wallet, from coins it discovered in its own state
//
// ── WHY THIS FILE EXISTS AT ALL, next to a green `roundtrip` mode ────────────
// `entrypoint-verify.sh roundtrip` runs UPSTREAM's integration suite, which is the right gate
// for "does the contract work": it deploys a FRESH contract per test and ends with every
// balance back where it started. Both of those are wrong for the offer-book chain, which needs
// (a) THIS stack's contract — its address is what /config.js injects and what the kernel's
// token registry is told about — and (b) an sNight coin that OUTLIVES the driver, because the
// next step of the chain spends it into an offer file.
//
// It is not a transcription of the suite either. Every primitive below is imported from the
// pinned tree's own `test/support/*`: the contract factory, the wallet builder, the provider
// wiring, the balance observers and the coin discovery. This file only sequences them.
//
// ── NO COIN IS EVER CARRIED BETWEEN STEPS ───────────────────────────────────
// `unwrap` does not receive the coin `wrap` minted. It discovers coins from the wallet's own
// synced state (`discoverCoins`), exactly as the multi-party integration test has the
// RECEIVERS of a transfer do — which is what makes it usable on the taker's wallet, whose
// sNight arrived from a stranger's offer file and was never minted here.

import * as ledger from '@midnight-ntwrk/ledger-v8';

import { networkFor, type EnvName, isEnvName } from '../test/support/network.js';
import { awaitWalletReady, buildWallet, type WalletContext } from '../test/support/wallet-builder.js';
import { setupContract } from '../test/support/setup-contract.js';
import * as contract from '../test/support/shielded-night.js';
import {
  getCoinPublicKey,
  getNightBalance,
  getUserAddress,
  randomBytes32,
  tokenColorHex,
  waitForShieldedBalance,
  waitForUnshieldedBalance,
} from '../test/support/wallet-observations.js';
import { coinsTotal, discoverCoins, waitForCoins } from '../test/support/wallet-transfer.js';

const NIGHT_HEX = ledger.unshieldedToken().raw;
const WRAPPER_DOMAIN = 'shielded-night:wrapper';

const log = (msg: string): void => {
  console.error(`[snight-driver] ${msg}`);
};

/** The one machine-readable line of this program. stdout, once, at the end. */
const result = (fields: Record<string, string | bigint>): void => {
  const body = Object.entries(fields)
    .map(([k, v]) => `${k}=${typeof v === 'bigint' ? v.toString() : v}`)
    .join(' ');
  console.log(`SNIGHT_RESULT ${body}`);
};

const die = (msg: string): never => {
  console.error(`[snight-driver] FATAL: ${msg}`);
  process.exit(1);
};

/**
 * The sNight colour, derived off-chain from a contract address — byte-for-byte the frontend's
 * `deriveWrapperColorHex` (`frontend/src/lib/tokens.ts`), which in turn mirrors the contract's
 * own `tokenType(pad(32,"shielded-night:wrapper"), self())`. The `wrap` mode below cross-checks
 * this against the contract's `tokenColor()` circuit, so the two can never drift apart
 * silently: a derivation that stopped matching the chain would fail there, not here.
 */
const deriveColorHex = (contractAddress: string): string => {
  const domain = new Uint8Array(32);
  domain.set(new TextEncoder().encode(WRAPPER_DOMAIN));
  const raw = ledger.rawTokenType(domain, contractAddress);
  if (typeof raw !== 'string' || !/^[0-9a-fA-F]{64}$/.test(raw)) {
    return die(`rawTokenType returned an unusable colour for ${contractAddress}: ${String(raw)}`);
  }
  return raw.toLowerCase();
};

/** The address the deploy one-shot published, read from the shared volume. */
const publishedAddress = async (): Promise<string> => {
  const file = process.env['CONTRACT_FILE'] ?? `${process.env['CONTRACT_SHARE_DIR'] ?? '/srv/shielded-night'}/contract.json`;
  let json: { address?: unknown };
  try {
    json = (await Bun.file(file).json()) as { address?: unknown };
  } catch (err) {
    return die(`cannot read ${file} (${String(err)}) — the deploy one-shot published nothing`);
  }
  const address = json.address;
  if (typeof address !== 'string' || !/^[0-9a-f]{16,128}$/i.test(address)) {
    return die(`${file} carries no usable string address`);
  }
  return address;
};

const requiredEnv = (name: string): string => {
  const v = process.env[name]?.trim();
  if (!v) return die(`missing required environment: ${name}`);
  return v;
};

const amountEnv = (name: string, fallback: bigint): bigint => {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  // `BigInt("")` is 0n rather than an error, which is how a knob left blank in .env becomes a
  // wrap of nothing. Blank is already handled above; a non-numeric value must be fatal.
  if (!/^[0-9]+$/.test(raw)) return die(`${name} must be a non-negative integer, got "${raw}"`);
  const v = BigInt(raw);
  if (v <= 0n) return die(`${name} must be greater than zero`);
  return v;
};

const resolveEnvName = (): EnvName => {
  const raw = process.env['MN_ENV'] ?? 'undeployed';
  if (!isEnvName(raw)) return die(`invalid MN_ENV "${raw}"`);
  // `undeployed` only, exactly as the deploy entrypoint enforces: every other network is a
  // real one where this dApp's own contract is already live.
  if (raw !== 'undeployed') return die(`this driver runs on undeployed only, not "${raw}"`);
  return raw;
};

/** Build + sync the wallet for `seed`, and return it with a stopper. */
const openWallet = async (seed: string, label: string): Promise<WalletContext> => {
  const network = networkFor(resolveEnvName());
  log(`${label} wallet: building and syncing (indexer ${network.indexer})`);
  const raw = await buildWallet(network, seed);
  const ctx = await awaitWalletReady(raw, { requireFunds: true });
  log(`${label} wallet: synced, NIGHT ${await getNightBalance(ctx)}`);
  return ctx;
};

// ── color ────────────────────────────────────────────────────────────────────
const cmdColor = async (): Promise<void> => {
  const address = await publishedAddress();
  const color = deriveColorHex(address);
  log(`contract ${address}`);
  log(`sNight colour ${color}`);
  result({ mode: 'color', address, color });
};

// ── wrap ─────────────────────────────────────────────────────────────────────
//
// Deltas, never absolutes. The upstream round-trip test can assert `wrapped === N` because it
// deploys a fresh contract into a wallet that holds none of its token; this runs against a
// long-lived stack contract on a wallet that may already hold sNight from an earlier
// `./verify.sh`. An absolute assertion here would pass exactly once per `./down.sh -v`.
const cmdWrap = async (): Promise<void> => {
  const address = await publishedAddress();
  const derived = deriveColorHex(address);
  const amount = amountEnv('SNIGHT_AMOUNT', 1_000_000n);
  const seed = requiredEnv('SNIGHT_SEED');

  const ctx = await openWallet(seed, 'maker');
  try {
    const { connect } = await setupContract(contract.factory, {
      network: networkFor(resolveEnvName()),
      walletCtx: ctx,
    });
    log(`connecting to the deployed contract ${address}`);
    const deployed = await connect(address);

    // THE CROSS-CHECK that makes the off-chain derivation trustworthy: the colour this driver
    // computed from the address must be the colour the CONTRACT reports. The kernel's token
    // registry is fed the derived value, and a page labelling the wrong colour is worse than
    // one labelling none.
    const onChain = tokenColorHex((await contract.tokenColor(deployed)).private.result);
    if (onChain !== derived) {
      return die(`tokenColor() says ${onChain} but rawTokenType(pad32("${WRAPPER_DOMAIN}"), address) says ${derived}`);
    }
    log(`colour agrees on and off chain: ${onChain}`);

    const night0 = await getNightBalance(ctx);
    const snight0 = await waitForShieldedBalance(ctx.wallet, onChain, () => true);
    log(`before: NIGHT ${night0}, sNight ${snight0}`);
    if (night0 < amount) return die(`wallet holds ${night0} NIGHT, needs ${amount}`);

    log(`convertToShielded(${amount}) — one transaction, proving…`);
    const coin = (
      await contract.convertToShielded(deployed, amount, await getCoinPublicKey(ctx), randomBytes32())
    ).private.result;
    if (coin.value !== amount) return die(`the minted coin is ${coin.value}, expected ${amount}`);
    if (tokenColorHex(coin.color) !== onChain) return die('the minted coin has the wrong colour');

    const snight1 = await waitForShieldedBalance(ctx.wallet, onChain, (b) => b >= snight0 + amount);
    const night1 = await waitForUnshieldedBalance(ctx.wallet, NIGHT_HEX, (b) => b <= night0 - amount);
    if (snight1 !== snight0 + amount) return die(`sNight went ${snight0} -> ${snight1}, expected +${amount}`);
    if (night1 !== night0 - amount) return die(`NIGHT went ${night0} -> ${night1}, expected -${amount}`);

    log(`after: NIGHT ${night1} (-${amount}), sNight ${snight1} (+${amount})`);
    result({
      mode: 'wrap',
      address,
      color: onChain,
      amount,
      nightBefore: night0,
      nightAfter: night1,
      snightBefore: snight0,
      snightAfter: snight1,
    });
  } finally {
    await ctx.wallet.stop().catch(() => undefined);
  }
};

// ── unwrap ───────────────────────────────────────────────────────────────────
//
// Discovers the coin rather than being handed one — see the file header. `convertToUnshielded`
// consumes ONE coin whole, so the wallet must hold a coin of exactly the requested value;
// asking for a partial amount would silently unwrap more than requested.
const cmdUnwrap = async (): Promise<void> => {
  const address = await publishedAddress();
  const color = deriveColorHex(address);
  const amount = amountEnv('SNIGHT_AMOUNT', 1_000_000n);
  const seed = requiredEnv('SNIGHT_SEED');

  const ctx = await openWallet(seed, 'holder');
  try {
    const { connect } = await setupContract(contract.factory, {
      network: networkFor(resolveEnvName()),
      walletCtx: ctx,
    });
    const deployed = await connect(address);

    const night0 = await getNightBalance(ctx);
    const coins = await waitForCoins(ctx, color, (cs) => cs.some((c) => c.value === amount), {
      timeoutMs: Number(process.env['SNIGHT_COIN_TIMEOUT_MS'] ?? '300000'),
    });
    const snight0 = coinsTotal(coins);
    log(`before: NIGHT ${night0}, sNight ${snight0} in ${coins.length} coin(s)`);
    const coin = coins.find((c) => c.value === amount);
    if (coin === undefined) {
      return die(
        `this wallet holds no single sNight coin worth exactly ${amount} ` +
          `(has ${coins.map((c) => c.value).join(',') || 'none'}) — convertToUnshielded burns one coin whole`,
      );
    }

    log(`convertToUnshielded(${amount}) — one transaction, proving…`);
    await contract.convertToUnshielded(deployed, coin, contract.rightUserAddress(getUserAddress(ctx).bytes));

    const night1 = await waitForUnshieldedBalance(ctx.wallet, NIGHT_HEX, (b) => b >= night0 + amount);
    if (night1 !== night0 + amount) return die(`NIGHT went ${night0} -> ${night1}, expected +${amount}`);
    const remaining = coinsTotal(await discoverCoins(ctx, color));
    if (remaining !== snight0 - amount) {
      return die(`sNight went ${snight0} -> ${remaining}, expected -${amount}`);
    }

    log(`after: NIGHT ${night1} (+${amount}), sNight ${remaining} (-${amount})`);
    result({
      mode: 'unwrap',
      address,
      color,
      amount,
      nightBefore: night0,
      nightAfter: night1,
      snightBefore: snight0,
      snightAfter: remaining,
    });
  } finally {
    await ctx.wallet.stop().catch(() => undefined);
  }
};

const MODES: Record<string, () => Promise<void>> = {
  color: cmdColor,
  wrap: cmdWrap,
  unwrap: cmdUnwrap,
};

const mode = process.argv[2] ?? '';
const run = MODES[mode];
if (run === undefined) {
  console.error(`[snight-driver] usage: bun run driver/snight-driver.ts <${Object.keys(MODES).join('|')}>`);
  process.exit(64); // EX_USAGE
}

run().then(
  () => process.exit(0),
  (e: unknown) => {
    console.error(`[snight-driver] failed: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`);
    process.exit(1);
  },
);

// m1/lib.ts — the small first-party layer between this stack's one-shots and
// mint-test-tokens' own code. SHARED, never run directly.
//
// ── WHAT IS FIRST-PARTY HERE AND WHAT IS NOT ─────────────────────────────────
// Nothing in this directory reimplements a contract, a registry format, an endpoint default or
// a token definition. Every one of those is IMPORTED from the pinned tree:
//
//   ../scripts/lib/network-config.js   the `undeployed` endpoint defaults and their MN_* overrides
//   ../scripts/lib/wallet-seed.js      the 32/64-byte master-seed validator
//   ../packages/registry/src/tokens.js the six canonical token definitions, in canonical order
//   ../packages/registry/src/semantic.js the browser-safe registry validator
//   ../contracts/v1/managed/*          the committed, byte-verified contract artifacts
//
// What IS first-party is the three things upstream has no reason to ship, because they only
// exist for a compose-hosted throwaway devnet:
//
//   1. funding a fresh deployer wallet from the chain's genesis wallet, and registering that
//      NIGHT for DUST so it can pay for anything at all (provision.ts);
//   2. minting an EXACT, caller-chosen amount of ONE named token to ONE wallet, headlessly
//      (fund.ts) — upstream's own runner mints the site's fixed faucet PRESETS to a synthetic
//      recipient and spends them back, which is a test, not a funding tool;
//   3. validating and dumping THIS stack's `undeployed` registry (registry.ts) — upstream's
//      `npm run check` deliberately validates only the three TRACKED public registries.
//
// ── IMPORTS ARE RELATIVE, AND THIS FILE LIVES INSIDE THE TREE ────────────────
// node resolves a bare specifier by walking up from the IMPORTING FILE. This directory is
// COPYd to /app/m1 (inside the pinned tree) precisely so `@midnight-ntwrk/*` resolves in
// /app/node_modules and the relative imports above resolve to the pinned sources. Run from
// anywhere else, nothing here resolves. See images/issuer/Dockerfile.

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { setNetworkId } from "@midnight-ntwrk/midnight-js-network-id";
import { MidnightWalletProvider } from "@midnight-ntwrk/testkit-js";
import { NetworkId } from "@midnight-ntwrk/wallet-sdk";
import pino from "pino";
import { filter, firstValueFrom, timeout } from "rxjs";
import { validateRegistry } from "../packages/registry/src/semantic.js";
import { TOKEN_DEFINITIONS } from "../packages/registry/src/tokens.js";
import type { DeploymentRecord, TokenRecord, TokenRegistry } from "../packages/registry/src/types.js";
import { endpointConfig } from "../scripts/lib/network-config.js";
import { validateMasterSeedHex } from "../scripts/lib/wallet-seed.js";

/** The repository root — this file is at <root>/m1/lib.ts. */
export const ROOT = resolve(new URL("..", import.meta.url).pathname);

/** `undeployed` only. Everything in this image is gated on it: pointing a dev seed at a public
 *  network would deploy six issuer contracts there with a publicly known key. */
export const NETWORK = "undeployed" as const;

export const TIMEOUT_MS = Number(process.env.MN_TIMEOUT_MS ?? 300_000);

/** NIGHT's colour is 32 zero bytes on every network (kernel `000-init.sql`, ledger
 *  `structure.rs`). Stated once. */
export const NIGHT = "0".repeat(64);

export const endpoints = endpointConfig(NETWORK);

export const log = (role: string, message: string): void => {
  process.stderr.write(`[${role}] ${message}\n`);
};

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

export async function withTimeout<T>(label: string, operation: Promise<T>, timeoutMs = TIMEOUT_MS): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs);
      })
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/**
 * The wallet environment every facade in this image is built with.
 *
 * `faucet: undefined` is not an omission: `undeployed` here is a midnight-node `CFG_PRESET=dev`
 * chain with no faucet service at all, which is the whole reason this stack needs an issuer.
 * Upstream's own public-network path passes the same `undefined`, and `MidnightWalletProvider`
 * then never asks anything of a faucet.
 */
export const walletEnv = {
  walletNetworkId: NetworkId.NetworkId.Undeployed,
  networkId: endpoints.networkId,
  indexer: endpoints.indexer,
  indexerWS: endpoints.indexerWS,
  node: endpoints.node,
  nodeWS: endpoints.nodeWS,
  proofServer: endpoints.proofServer,
  faucet: undefined
} as const;

/** Silent, on purpose: the SDK's own pino stream would interleave megabytes of sync progress
 *  with the one-shot's own log lines, and the lines this stack asserts on are the ones the
 *  entrypoints print. Set ISSUER_SDK_LOG_LEVEL to bring it back while debugging. */
export const sdkLogger = pino({ level: process.env.ISSUER_SDK_LOG_LEVEL ?? "silent" });

/**
 * Read a master seed out of a FILE, never out of an argument or an environment value.
 *
 * That is upstream's rule (`MN_SEED_FILE`, "Keep the file outside the repository with
 * owner-only permissions") and this stack keeps it for its own reason: an argument is visible
 * in `docker inspect`, in `ps`, and in every compose log line that echoes a command. The
 * validator is the pinned tree's own, so "what counts as a seed" has one definition.
 */
export async function readSeedFile(path: string, variableName = "MN_SEED_FILE"): Promise<string> {
  return validateMasterSeedHex((await readFile(resolve(path), "utf8")).trim(), variableName);
}

export interface Facade {
  provider: MidnightWalletProvider;
  stop(): Promise<void>;
}

/**
 * Build and start ONE wallet facade.
 *
 * ONE FACADE PER SEED. Two facades on one seed against one Midnight node force each other's
 * connection down — the second to connect wins and the first silently stops syncing, with no
 * error naming the cause (wallets/wallets.json). Every caller here therefore builds at most one
 * facade per seed and stops it before it exits; `entrypoint-fund.sh` additionally holds a
 * `flock` so two concurrent `issuer-fund` runs cannot open two facades on the issuer's seed.
 */
export async function buildFacade(role: string, seedHex: string): Promise<Facade> {
  setNetworkId(endpoints.networkId);
  const provider = await withTimeout(`${role} wallet build`, MidnightWalletProvider.build(sdkLogger, walletEnv, seedHex));
  await withTimeout(`${role} wallet start`, provider.start(false));
  return {
    provider,
    stop: async () => {
      await provider.stop().catch(() => undefined);
    }
  };
}

/** The facade's combined state, once every subtree reports itself synced. */
export async function waitSynced(provider: MidnightWalletProvider, label: string): Promise<any> {
  return firstValueFrom(
    provider.wallet.state().pipe(
      filter((state: any) => state.isSynced === true),
      timeout({ first: TIMEOUT_MS })
    )
  ).catch((error) => {
    throw new Error(`${label} never reported a synced state: ${error instanceof Error ? error.message : String(error)}`);
  });
}

/**
 * Spendable DUST, read the way the pinned deploy runner reads it
 * (`scripts/lib/deployment-wallet.ts`: `state.dust.balance(now) <= 0n` is its refusal).
 *
 * The `.state?.progress` fallback below is not defensive coding for its own sake: facade 4.0.1
 * exposes `FacadeState.dust` as the DustWalletState itself, while the published
 * `@effectstream/midnight-contracts` reads `s.dust.state.progress` — an older shape. Reading
 * whichever is present means a facade minor bump does not turn "no dust yet" into a crash.
 */
export function dustBalance(state: any, at: Date = new Date()): bigint {
  const dust = state?.dust;
  if (!dust) return 0n;
  const balance = typeof dust.balance === "function" ? dust.balance(at) : undefined;
  return typeof balance === "bigint" ? balance : BigInt(balance ?? 0);
}

function isStrictlyComplete(subtree: any): boolean {
  const progress = subtree?.progress ?? subtree?.state?.progress;
  return progress?.isStrictlyComplete?.() ?? false;
}

/** Wait until spendable DUST is strictly positive, or give up with the last value seen. */
export async function waitForDust(
  role: string,
  provider: MidnightWalletProvider,
  timeoutMs: number
): Promise<bigint> {
  const deadline = Date.now() + timeoutMs;
  let last = 0n;
  while (Date.now() < deadline) {
    const state = await provider.wallet.waitForSyncedState().catch(() => undefined);
    last = dustBalance(state);
    if (last > 0n) return last;
    log(role, `dust is ${last} — waiting (${Math.max(0, Math.round((deadline - Date.now()) / 1000))}s left)`);
    await sleep(5_000);
  }
  return last;
}

/**
 * Register every unregistered NIGHT UTXO this wallet holds for DUST generation.
 *
 * ── WHY THIS IS HERE AND NOT IMPORTED ───────────────────────────────────────
 * The kernel-side stacks in this repository call `registerNightForDust()` from
 * `@effectstream/midnight-contracts`, which is a dependency of the KERNEL tree, not of
 * mint-test-tokens. Installing it here would put a SECOND ledger-v8 wasm instance in this
 * image's dependency graph, and two instances fail `instanceof` during proving — the exact
 * hazard images/shielded-night's Dockerfile asserts against.
 *
 * So the three-line recipe is expressed against the wallet facade that mint-test-tokens
 * already installs. It is the same recipe: read that published package's own
 * `src/get-wallet-info.ts` (0.103.1) beside `@midnight-ntwrk/wallet-sdk-facade`'s
 * `registerNightUtxosForDustGeneration(nightUtxos, nightVerifyingKey, signDustRegistration)`.
 *
 * `getPublicKey()` on the unshielded keystore IS the `SignatureVerifyingKey` that method wants
 * (`KeyStore.d.ts`), and `signData` is the signer. Nothing is invented.
 */
export async function registerNightForDust(role: string, provider: MidnightWalletProvider): Promise<boolean> {
  const state: any = await withTimeout(
    `${role} unshielded+dust sync for dust registration`,
    (async () => {
      return firstValueFrom(
        provider.wallet.state().pipe(
          filter((value: any) => isStrictlyComplete(value?.dust) && isStrictlyComplete(value?.unshielded)),
          timeout({ first: TIMEOUT_MS })
        )
      );
    })()
  );

  const unregistered = (state?.unshielded?.availableCoins ?? []).filter(
    (coin: any) => coin?.meta?.registeredForDustGeneration === false
  );
  if (unregistered.length === 0) {
    // Not a failure: either every NIGHT UTXO is already registered (a re-run) or the wallet
    // holds none at all, and the caller decides what that means for IT.
    log(role, "no unregistered NIGHT UTXOs — nothing to register");
    return false;
  }

  log(role, `registering ${unregistered.length} NIGHT UTXO(s) for DUST generation`);
  const wallet = provider.wallet as any;
  const recipe = await withTimeout(
    `${role} dust registration recipe`,
    wallet.registerNightUtxosForDustGeneration(
      unregistered,
      provider.unshieldedKeystore.getPublicKey(),
      (payload: Uint8Array) => provider.unshieldedKeystore.signData(payload)
    )
  );
  const txId = await withTimeout(
    `${role} dust registration submission`,
    provider.wallet.submitTransaction(await wallet.finalizeRecipe(recipe))
  );
  log(role, `dust registration submitted, tx ${String(txId)}`);
  return true;
}

// ── the registry ─────────────────────────────────────────────────────────────

/** The one filename every consumer of this stack reopens BY PATH — never bind-mounted as a
 *  single file, because atomic publication replaces its inode (upstream docs/registry.md). */
export const registryFileName = `metadata.${NETWORK}.json` as const;

export function registryDir(): string {
  return resolve(process.env.MN_METADATA_OUTPUT_DIR?.trim() || resolve(ROOT, "metadata"));
}

export function registryPath(): string {
  return resolve(registryDir(), registryFileName);
}

export interface LoadedRegistry {
  registry: TokenRegistry;
  path: string;
}

/**
 * Read the registry and require it to be a VALID, READY, v1 registry for this network.
 *
 * The validator is upstream's own browser-safe `validateRegistry`, so "valid" means exactly
 * what the faucet site means by it. `status: ready` is upstream's documented consumer contract
 * ("Consumers must validate the file and require registry `status` `ready`").
 */
export async function loadReadyRegistry(): Promise<LoadedRegistry> {
  const path = registryPath();
  let raw: string;
  try {
    raw = await readFile(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error(`no registry at ${path} — the issuer-deploy one-shot has published nothing`);
    }
    throw error;
  }
  const value = JSON.parse(raw) as TokenRegistry;
  const validation = validateRegistry(value, NETWORK);
  if (!validation.ok) throw new Error(`${path} is not a valid registry:\n${validation.errors.join("\n")}`);
  if (value.status !== "ready") throw new Error(`${path} is "${value.status}", not "ready"`);
  if (value.network.protocolFamily !== "midnight-1.x") {
    throw new Error(`${path} is ${value.network.protocolFamily}, and this stack is midnight-1.x`);
  }
  return { registry: value, path };
}

export interface ResolvedToken {
  /** The registry's own symbol, e.g. `twBTC`. */
  symbol: string;
  /** The kernel's name for it — the registry symbol upper-cased, e.g. `TWBTC`. The kernel
   *  itself upper-cases and truncates to 16 characters on POST /v1/known-tokens, and its
   *  `000-init.sql` seeds these exact upper-case names. */
  name: string;
  decimals: number;
  privacy: "shielded" | "unshielded";
  /** 64 hex characters: the token COLOUR, `rawTokenType(domainSeparator, contractAddress)`. */
  tokenId: string;
  contractAddress: string;
  faucetBaseUnits: string;
  token: TokenRecord;
  deployment: DeploymentRecord;
}

/** The one place `name` is derived from `symbol`. `toUpperCase()` and nothing else — it is what
 *  the kernel does to whatever it is sent, so any other transformation here would produce a
 *  name that can never match the row the kernel seeds. */
export const kernelName = (symbol: string): string => symbol.toUpperCase();

export function activeDeployment(token: TokenRecord): DeploymentRecord {
  const record = token.deployments.find(
    (item) => item.deploymentId === token.activeDeploymentId && item.status === "active"
  );
  if (!record) throw new Error(`${token.symbol}: the registry selects no active deployment`);
  return record;
}

/** Every token in the registry, in the pinned tree's canonical order — not the file's order,
 *  so a consumer's output is stable even if a future publisher reorders the array. */
export function resolvedTokens(registry: TokenRegistry): ResolvedToken[] {
  return TOKEN_DEFINITIONS.map((definition) => {
    const token = registry.tokens.find((item) => item.symbol === definition.symbol);
    if (!token) throw new Error(`the registry has no ${definition.symbol}`);
    if (token.decimals !== definition.decimals || token.privacy !== definition.privacy) {
      throw new Error(
        `${token.symbol}: the registry says decimals=${token.decimals} privacy=${token.privacy}, ` +
          `the pinned definition says decimals=${definition.decimals} privacy=${definition.privacy}`
      );
    }
    const deployment = activeDeployment(token);
    if (!/^[0-9a-f]{64}$/.test(deployment.tokenId)) {
      throw new Error(`${token.symbol}: tokenId ${deployment.tokenId} is not 64 hex characters`);
    }
    return {
      symbol: token.symbol,
      name: kernelName(token.symbol),
      decimals: token.decimals,
      privacy: token.privacy,
      tokenId: deployment.tokenId,
      contractAddress: deployment.contractAddress,
      faucetBaseUnits: token.faucet.baseUnits,
      token,
      deployment
    };
  });
}

/** Find one token by EITHER the registry symbol (`twBTC`) or the kernel name (`TWBTC`), so a
 *  caller never has to know which convention it is holding. Case-insensitive on purpose. */
export function findToken(registry: TokenRegistry, wanted: string): ResolvedToken {
  const key = wanted.trim().toUpperCase();
  const found = resolvedTokens(registry).find((item) => item.name === key);
  if (!found) {
    throw new Error(
      `unknown token "${wanted}" — this registry holds ${resolvedTokens(registry)
        .map((item) => `${item.name}(${item.symbol})`)
        .join(" ")}`
    );
  }
  return found;
}

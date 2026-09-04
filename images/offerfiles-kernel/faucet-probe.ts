// faucet-probe.ts — read the FAUCET ALLOTMENT out of the pinned kernel tree this image was
// built from, and make the two canonical faucet colours nameable and priceable.
//
//   docker compose exec -T kernel bun run /usr/local/lib/offerfiles/faucet-probe.ts
//
// Run by scripts/verify-kernel.sh's `faucet` section. It is a PROBE, not a service: it holds
// no wallet, signs nothing, proves nothing and mints nothing on chain.
//
// ── WHAT IT PROVES, AND WHY IT LIVES INSIDE THE IMAGE ────────────────────────
//
// Kernel PR #63 ("every token has 6 decimals, faucets mint whole coins") is the change
// KERNEL_REF c293ebd… brings, and the number this stack has to be able to state is the faucet
// ALLOTMENT: one faucet press hands out 1 000 WHOLE COINS, which at 6 decimals is exactly
// 1_000_000_000 base units. That number is not a constant this repository may re-declare — it
// belongs to `docs/src/wallet/mintable.ts` in the kernel tree, which is the SINGLE definition
// the browser SPA's faucet, `deploy/scripts/lib/faucet-mint.ts` and the offer poster all
// import. Reading it here, from the RUNNING image, is the difference between asserting what
// the pinned commit actually ships and asserting what someone remembered about it.
//
// ── THE TWO PRESET COLOURS ───────────────────────────────────────────────────
//
// WBTC and WETH are the faucet presets the price map knows by NAME (`DEFAULT_NAME_ASSET_MAP`
// in `packages/database/price-map.ts`: WBTC -> bitcoin, WETH -> ethereum). Their colours are
// `rawTokenType(domainSepFromName(name), <contract address>)`, so they are per-stack — which
// is exactly why `000-init.sql` cannot seed them and why nothing on a fresh stack prices them
// until someone mints one from the SPA.
//
// This probe registers those two colours (idempotently — a 409 is the normal second answer)
// with an EXPLICIT `decimals: 6`, the same body the SPA's own `api.registerKnownToken` sends
// after a mint since effectstream#918. Registration is a NAME/PRICE mapping, not a claim about
// supply: it is what makes `GET /v1/prices` able to answer for the two colours the whole-coin
// line is specified against (WBTC = 77387/10^6 = 0.077387, WETH = 2393.28/10^6 = 0.00239328).
// A later browser mint of the same name lands on the SAME colour by construction and simply
// finds it already named — the SPA's mint reconciler treats that as a no-op by design.
//
// ── OUTPUT CONTRACT (parsed by verify-kernel.sh; keep it stable) ─────────────
//
//   FAUCET_PROBE allotmentCoins=<n> allotmentBaseUnits=<n> defaultDecimals=<n> contract=<hex>
//   FAUCET_PROBE_TOKEN name=<NAME> kind=<kind> colour=<64-hex> decimals=<n> register=<status>
//
// One line per token, then a single summary line. Every failure throws with the reason in it;
// the caller treats a non-zero exit as a failed section.

import { expectedColour, normaliseHex32, PRESET_TOKENS } from "/app/deploy/scripts/lib/faucet-mint.ts";
import { MINT_AMOUNT, MINT_COINS } from "/app/docs/src/wallet/mintable.ts";
import { coinsToBaseUnits, DEFAULT_TOKEN_DECIMALS } from "/app/packages/solver-core/amount.ts";

const TAG = "[faucet-probe]";

/** The two presets the kernel's built-in NAME price map can price. */
const WANTED = ["WBTC", "WETH"] as const;

function requireEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.trim() === "") {
    throw new Error(`${name} is not set`);
  }
  return value.trim();
}

const apiBase = (process.env.KERNEL_API_URL ?? "http://127.0.0.1:9999").replace(/\/+$/, "");
const contractAddress = normaliseHex32(requireEnv("FAUCET_PROBE_CONTRACT"), "contract address");

// ── the allotment, straight out of the pinned tree ───────────────────────────
//
// Cross-check the two exported forms against each other before printing either: `MINT_AMOUNT`
// is defined as `coinsToBaseUnits(MINT_COINS, DEFAULT_TOKEN_DECIMALS)` upstream, and a tree in
// which that stopped holding would be a tree whose faucet and whose registry disagree.
const derived = coinsToBaseUnits(MINT_COINS, DEFAULT_TOKEN_DECIMALS);
if (derived !== MINT_AMOUNT) {
  throw new Error(
    `mintable.ts MINT_AMOUNT is ${MINT_AMOUNT} but coinsToBaseUnits(${MINT_COINS}, ${DEFAULT_TOKEN_DECIMALS}) is ${derived}`,
  );
}

for (const name of WANTED) {
  const preset = PRESET_TOKENS.find((t) => t.name === name);
  if (preset === undefined) {
    throw new Error(`${name} is no longer a faucet preset in docs/src/wallet/mintable.ts`);
  }
  const colour = expectedColour(name, contractAddress);

  let status: string;
  try {
    const res = await fetch(`${apiBase}/v1/known-tokens`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      // `decimals` STATED, exactly as the SPA does since effectstream#918 and as
      // deploy/images/kernel/entrypoint-register-minted-tokens.sh does since kernel PR #63.
      body: JSON.stringify({
        color: colour,
        name,
        kind: preset.kind,
        decimals: DEFAULT_TOKEN_DECIMALS,
      }),
      signal: AbortSignal.timeout(15_000),
    });
    // 409 = this colour or name is already registered. That is the normal second answer and
    // the reason this probe is safe to re-run on every ./verify.sh.
    status = res.ok ? `ok(${res.status})` : res.status === 409 ? "already(409)" : `HTTP${res.status}`;
    if (!res.ok && res.status !== 409) {
      const body = (await res.text()).slice(0, 200);
      throw new Error(`POST /v1/known-tokens ${name}: HTTP ${res.status} ${body}`);
    }
  } catch (error) {
    throw new Error(
      `${name} ${colour.slice(0, 16)}…: ${error instanceof Error ? error.message : String(error)}`,
    );
  }

  console.log(
    `FAUCET_PROBE_TOKEN name=${name} kind=${preset.kind} colour=${colour} ` +
      `decimals=${DEFAULT_TOKEN_DECIMALS} register=${status}`,
  );
}

console.log(
  `FAUCET_PROBE allotmentCoins=${MINT_COINS} allotmentBaseUnits=${MINT_AMOUNT} ` +
    `defaultDecimals=${DEFAULT_TOKEN_DECIMALS} contract=${contractAddress}`,
);
console.error(`${TAG} done`);

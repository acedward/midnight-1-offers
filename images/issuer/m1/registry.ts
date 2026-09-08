// m1/registry.ts — validate and DUMP this stack's own `undeployed` registry.
//
//   docker compose run --rm --no-deps issuer-registry            # validate + dump
//   docker compose run --rm --no-deps -e ISSUER_REGISTRY_JSON=1 issuer-registry
//
// ── WHY THIS IS FIRST-PARTY ─────────────────────────────────────────────────
// mint-test-tokens' own `npm run check` (`packages/registry/dist/validate.js`) validates the
// THREE TRACKED PUBLIC registries — preview, preprod, stagenet — and deliberately never the
// local one: `metadata.undeployed.json` is gitignored, per-stack, and does not exist in a
// checkout. This stack's `./verify.sh` needs the opposite: the local file, checked with the
// SAME two validators upstream uses, so a bad registry is caught here rather than as an
// unexplainable kernel row or an "unavailable" faucet page.
//
// BOTH validators, because they answer different questions:
//   * the JSON SCHEMA (`schema/metadata.schema.json`, via the tree's own ajv) — structure;
//   * `validateRegistry()` (`packages/registry/src/semantic.js`) — the browser-safe semantic
//     validator the faucet site itself runs before it will show a token.
// A file can pass one and fail the other, and the site only trusts a file that passes both.
//
// ── OUTPUT CONTRACT (read by scripts/verify-issuer.sh; keep it stable) ──────
//   ISSUER_REGISTRY status=<status> network=<key> revision=<64 hex> tokens=<n> active=<n> \
//                   chainId=<name> generatedAt=<iso>
//   ISSUER_TOKEN <NAME> symbol=<symbol> privacy=<...> decimals=<n> id=<64 hex> \
//                 address=<hex> faucetBaseUnits=<n> deployment=<active|...> sourceRevision=<sha>
//
// One `ISSUER_TOKEN` line per token, in the pinned tree's canonical order. `verify-issuer.sh`
// greps these; `docs/OPERATIONS.md` shows an operator the same command.
//
// EXIT CODES: 0 valid, ready, six active deployments; 1 anything else (with the reason).

import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { Ajv2020 } from "ajv/dist/2020.js";
import { validateRegistry } from "../packages/registry/src/semantic.js";
import { TOKEN_DEFINITIONS } from "../packages/registry/src/tokens.js";
import { NETWORK, ROOT, log, registryPath, resolvedTokens } from "./lib.js";

const ROLE = "issuer-registry";
const say = (message: string): void => log(ROLE, message);
const asJson = (process.env.ISSUER_REGISTRY_JSON ?? "").trim() === "1";

const path = registryPath();
let raw: string;
try {
  raw = await readFile(path, "utf8");
} catch (error) {
  if ((error as NodeJS.ErrnoException).code === "ENOENT") {
    say(`no registry at ${path} — the issuer-deploy one-shot has published nothing`);
    process.exit(1);
  }
  throw error;
}

let value: unknown;
try {
  value = JSON.parse(raw);
} catch (error) {
  say(`${path} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}

// ── 1. the JSON schema, with the tree's own ajv and the tree's own schema file ─
const require = createRequire(import.meta.url);
const addFormats = require("ajv-formats") as (ajv: Ajv2020) => void;
const schema = JSON.parse(await readFile(resolve(ROOT, "schema", "metadata.schema.json"), "utf8"));
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validateSchema = ajv.compile(schema);
if (!validateSchema(value)) {
  say(`${path} does not match schema/metadata.schema.json:`);
  say(`  ${ajv.errorsText(validateSchema.errors)}`);
  process.exit(1);
}
say("schema/metadata.schema.json: OK");

// ── 2. the semantic validator the faucet site itself runs ────────────────────
const semantic = validateRegistry(value, NETWORK);
if (!semantic.ok) {
  say(`${path} fails the semantic validator:`);
  for (const error of semantic.errors) say(`  ${error}`);
  process.exit(1);
}
const registry = semantic.value;
say("packages/registry semantic validator: OK");

// ── 3. what this stack requires on top: ready, and six ACTIVE deployments ────
let failed = 0;
if (registry.status !== "ready") {
  say(`status is "${registry.status}", not "ready" — upstream's consumer contract requires ready`);
  failed += 1;
}
if (registry.network.protocolFamily !== "midnight-1.x") {
  say(`protocolFamily is ${registry.network.protocolFamily}, and this stack is midnight-1.x`);
  failed += 1;
}
if (registry.tokens.length !== TOKEN_DEFINITIONS.length) {
  say(`the registry holds ${registry.tokens.length} tokens, expected ${TOKEN_DEFINITIONS.length}`);
  failed += 1;
}

let tokens: ReturnType<typeof resolvedTokens> = [];
try {
  tokens = resolvedTokens(registry);
} catch (error) {
  say(`${error instanceof Error ? error.message : String(error)}`);
  failed += 1;
}

const active = tokens.length;
process.stdout.write(
  `ISSUER_REGISTRY status=${registry.status} network=${registry.network.key} ` +
    `revision=${registry.registryRevision} tokens=${registry.tokens.length} active=${active} ` +
    `chainId=${registry.network.chainId ?? "<null>"} generatedAt=${registry.generatedAt}\n`
);
for (const token of tokens) {
  process.stdout.write(
    `ISSUER_TOKEN ${token.name} symbol=${token.symbol} privacy=${token.privacy} ` +
      `decimals=${token.decimals} id=${token.tokenId} address=${token.contractAddress} ` +
      `faucetBaseUnits=${token.faucetBaseUnits} deployment=${token.deployment.status} ` +
      `sourceRevision=${token.deployment.artifact.sourceRevision}\n`
  );
}
if (asJson) {
  process.stdout.write(
    `${JSON.stringify(
      tokens.map((token) => ({
        name: token.name,
        symbol: token.symbol,
        privacy: token.privacy,
        decimals: token.decimals,
        tokenId: token.tokenId,
        contractAddress: token.contractAddress,
        faucetBaseUnits: token.faucetBaseUnits
      })),
      null,
      2
    )}\n`
  );
}

if (failed > 0) {
  say(`${failed} check(s) failed`);
  process.exit(1);
}
say(`${active} active deployment(s), registry revision ${registry.registryRevision.slice(0, 16)}…`);
process.exit(0);

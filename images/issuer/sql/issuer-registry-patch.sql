-- issuer-registry-patch.sql — give ONE of the kernel's seeded token rows THIS stack's colour.
--
--   psql -v ON_ERROR_STOP=1 -t -A \
--        -v name=TWBTC -v color=<64 hex> -v kind=shielded -v decimals=8 -v asset_id=bitcoin \
--        -f /usr/local/lib/issuer/sql/issuer-registry-patch.sql
--
-- Run six times by images/issuer/entrypoint-registrar.sh — once per canonical token, in the
-- registry's canonical order — AFTER the kernel is healthy, its /v1/health/sync says `ok` and
-- the midnight-node is past block 1. Never earlier: the kernel applies
-- packages/database/migrations/000-init.sql — which contains the seed this patches — while it
-- is bringing the database up, so a patch that won that race would simply be overwritten by
-- the seed.
--
-- ── WHY THIS EXISTS: THE SAME REASON THE sNIGHT PATCH DOES ──────────────────
-- This is images/shielded-night/sql/snight-registry-patch.sql (00015 PR A, organizer
-- issues/00012) GENERALISED from one hard-coded name to a parameter, because kernel `main`
-- @ e3b9388 (PR #69) turned the one-row problem into a six-row problem.
--
-- At that commit `000-init.sql` seeds the SIX canonical mint-test-tokens names —
--
--   ('b11bd7c7…','TWBTC','shielded',8,'bitcoin'),  ('087d1d5d…','TWETH','shielded',18,'ethereum'),
--   ('a5c902be…','TWUSDC','shielded',6,'usd-coin'), ('931ceb35…','TWUSDM','shielded',6,'usdm-2'),
--   ('4ecbf451…','UTWUSDC','unshielded',6,'usd-coin'), ('be3354fb…','UTWBTC','unshielded',8,'bitcoin')
--
-- — at the colours of the PUBLIC PREPROD deployment, from the pinned Preprod registry revision
-- ebd5eaba…. Those colours do not exist on an `undeployed` chain: this stack deploys its own
-- six issuer contracts, so each colour is rawTokenType(domainSeparator, <this stack's contract
-- address>) and is different on every `./down.sh -v`.
--
-- And `POST /v1/known-tokens` is NOT an alternative: `known_tokens.name` is UNIQUE and the
-- route checks the NAME before the colour (packages/node/api.ts), so it answers
-- 409 `Token name "TWBTC" is already taken` and the real colour can never be registered under
-- its own name while the seeded row holds it. The UPDATE is the only door — which is what the
-- kernel's own comment above that INSERT says, verbatim, for the sNight row:
--
--     UPDATE known_tokens SET token_color = '<colour>' WHERE name = 'SNIGHT';
--
-- ── IT IS ALSO CORRECT ON A KERNEL THAT SEEDS NOTHING ───────────────────────
-- At the kernel pin this stack runs TODAY (a608fa6) `000-init.sql` seeds NIGHT, SNIGHT, USDC
-- and USDM and NO TW*/UTW* row at all. This file then matches nothing and reports `UPDATE 0`,
-- and the registrar's POST creates the row (201). Both outcomes are success; the entrypoint
-- distinguishes them in its log so the operator can see which kernel they are on.
--
-- ── THE SHAPE OF THE STATEMENT, AND WHY ─────────────────────────────────────
-- * `upper(name) = upper(:'name')` — the kernel upper-cases every registered name
--   (`String(body.name).trim().toUpperCase()`), so the comparison is made case-insensitively
--   at both ends and a caller may pass either the registry's `twBTC` or the kernel's `TWBTC`.
-- * `kind`, `decimals` and `asset_id` are set too, not only the colour. The seed already
--   carries the right values, so this normally changes nothing — but a stack whose seed ever
--   differs must end up with the row this registration would have CREATED, not a half-patched
--   one. Every price and every sponsorship threshold in the kernel is scaled by `decimals`.
-- * The `AND (…)` guard is what makes a second run report `UPDATE 0` instead of `UPDATE 1`:
--   the statement is idempotent by its WHERE clause, not by a marker file that would have to
--   be invalidated whenever `./down.sh -v` gives the stack six new contracts and six new
--   colours. `IS DISTINCT FROM` rather than `<>` because `asset_id` is NULLable, and
--   NULL <> 'x' is NULL, i.e. not true — a NULL asset_id would never be patched.
-- * NO row is created here. Creating one is the POST's job, and doing it in both places would
--   mean two definitions of what a registered token looks like.
-- * No BEGIN/COMMIT: one UPDATE is already atomic, and the SELECT after it is read-only.
--   `ON_ERROR_STOP` is set here as well as on the command line so a hand-run cannot continue
--   past a failed UPDATE.
--
-- ── WHAT THIS FILE DELIBERATELY DOES NOT TOUCH ──────────────────────────────
-- `canonical_token_registry_state` — the importer-ownership marker kernel #69 adds beside the
-- seed, which records the colour a canonical PUBLIC import last committed for each name. This
-- file leaves it alone, for two reasons:
--
--   1. it CANNOT be made correct: the column carries `CHECK (network IN ('preview','preprod',
--      'stagenet'))`, so there is no legal row for an `undeployed` colour;
--   2. leaving the Preprod marker in place is the honest state, and the kernel's own importer
--      says so usefully. On a stack that has been issued local tokens, an explicit
--      `TOKEN_REGISTRY_NETWORK=preprod` import refuses with "managed token TWBTC no longer
--      matches canonical registry provenance" and is SKIPPED (non-fatal) — which is exactly
--      right: a database cannot hold both the public Preprod colours and this stack's own.
--      Deleting the marker rows would not change that outcome (the import would then refuse
--      with "token name collision with unrelated known token TWBTC" instead) and would destroy
--      a record this profile does not own.
--
-- On `undeployed` the import is skipped before any of that: `fetchRegistry()` throws
-- "undeployed is a local network with no public canonical registry".
--
-- ── THE ONE ERROR THIS FILE CAN RAISE, AND WHO ANSWERS IT ───────────────────
-- `token_color` is UNIQUE. If some OTHER row already holds this stack's colour under a
-- different name, the UPDATE fails with `duplicate key value violates unique constraint
-- "known_tokens_token_color_key"` (psql exits 3). That is the correct outcome — a blind DELETE
-- would be worse — and the entrypoint READS the registry before calling this file precisely so
-- the operator gets the conflict named, with a dump, instead of a constraint violation.
\set ON_ERROR_STOP on

UPDATE known_tokens
   SET token_color = :'color',
       kind        = :'kind',
       decimals    = :decimals,
       asset_id    = :'asset_id'
 WHERE upper(name) = upper(:'name')
   AND (token_color <> :'color'
     OR kind        <> :'kind'
     OR decimals    <> :decimals
     OR asset_id IS DISTINCT FROM :'asset_id');

-- The row as it now stands, for the one-shot's log. One line, prefixed so it can be grepped
-- out of a container log; `(0 rows)` here means this kernel seeds no row under this name at
-- all, which is a legitimate state and not an error — the POST will create it.
SELECT 'ISSUER_REGISTRY_ROW id=' || id
    || ' color=' || token_color
    || ' name=' || name
    || ' kind=' || kind
    || ' decimals=' || decimals
    || ' asset_id=' || coalesce(asset_id, '<null>') AS row
  FROM known_tokens
 WHERE upper(name) = upper(:'name');

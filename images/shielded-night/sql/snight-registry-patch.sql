-- snight-registry-patch.sql — give the kernel's seeded SNIGHT row THIS stack's colour.
--
--   psql -v ON_ERROR_STOP=1 -t -A \
--        -v color=<64 hex> -v name=SNIGHT -v asset_id=midnight-3 -v decimals=6 \
--        -f /usr/local/lib/shielded-night/sql/snight-registry-patch.sql
--
-- Run by images/shielded-night/entrypoint-token-name.sh, AFTER the kernel is healthy, its
-- /v1/health/sync says `ok` and the midnight-node is past block 1. Never run it earlier: the
-- kernel applies packages/database/migrations/000-init.sql — which contains the seed this
-- patches — while it is bringing the database up, so a patch that won the race would simply
-- be overwritten by the seed.
--
-- ── WHY THIS EXISTS: THE KERNEL'S OWN INSTRUCTION ────────────────────────────
-- Kernel `main` @ c293ebd (PR #61) seeds four rows into `known_tokens`, one of them
--
--   ('793c29c94f72972bfbd861e8e84e55480ccc8e57a7b74067f35a5672c816f99c','SNIGHT','shielded',6,'midnight-3')
--
-- and the comment directly above that INSERT says, verbatim:
--
--     !!! PATCH THIS ROW WHEN DEPLOYING TO ANOTHER NETWORK !!!
--     … The value seeded below is *preview*, the default …
--     This file runs against an EMPTY database exactly once, so an ALREADY-LIVE database is
--     not reached by editing it: patch that one by hand, with
--       UPDATE known_tokens SET token_color = '<colour>' WHERE name = 'SNIGHT';
--     or POST /v1/known-tokens.
--
-- This stack IS "another network": `MN_ENV=undeployed`, its own shielded-night wrapper
-- contract deployed per stack, so sNight's colour — rawTokenType(pad32("shielded-night:wrapper"),
-- <this stack's contract address>) — is different every time and can never be the preview one.
--
-- And "or POST /v1/known-tokens" is NOT an alternative here: `known_tokens.name` is UNIQUE and
-- POST /v1/known-tokens checks the NAME before the colour (packages/node/api.ts), so the POST
-- answers 409 "Token name \"SNIGHT\" is already taken" and the real colour can never be
-- registered under its own name while the seeded row holds it. The UPDATE is the only door.
--
-- Recorded upstream-side as this organizer's issues/00012 (the upstream fix is for the kernel
-- to stop seeding the row and let price-map.ts's NAME entry price it wherever it is
-- registered). Until that lands, every m1 stack patches its own database with this file.
--
-- ── WHAT REPLACED WHAT ──────────────────────────────────────────────────────
-- Before 00015 the same problem was solved in up.sh by DELETING the row
-- (`DELETE FROM known_tokens WHERE upper(name) = 'SNIGHT'`) and re-running the registration
-- one-shot. That worked, but it destroyed a row rather than correcting it, it lived in the
-- bring-up script rather than in the profile that owns the colour, and it was unversioned.
-- This file is the kernel's own prescribed statement, parameterised, run by the one-shot that
-- already knows the colour.
--
-- ── THE SHAPE OF THE STATEMENT, AND WHY ─────────────────────────────────────
-- * `upper(name) = upper(:'name')` — the kernel upper-cases every registered name
--   (`String(body.name).trim().toUpperCase()`), and this file is called with `sNight`'s
--   configured symbol, so the comparison is made case-insensitively at both ends.
-- * `decimals` and `asset_id` are set too, not only the colour. The seed already carries 6 /
--   midnight-3, so this normally changes nothing — but a stack whose seed ever differs must
--   end up with the row this profile's registration would have created, not a half-patched
--   one. sNight prices off NIGHT's own asset because one sNight base unit IS one Star.
-- * The `AND (…)` guard is what makes a second run report `UPDATE 0` instead of `UPDATE 1`:
--   the statement is idempotent by its WHERE clause, not by a marker file that would have to
--   be invalidated whenever `./down.sh -v` gives the stack a new contract and a new colour.
--   `IS DISTINCT FROM` rather than `<>` because `asset_id` is NULLable, and NULL <> 'x' is
--   NULL, i.e. not true — a NULL asset_id would never be patched.
-- * NO row is created here. On a kernel that does not seed SNIGHT (a future upstream fix)
--   this touches 0 rows and the one-shot's POST registers the colour normally — the patch is
--   harmless where it is unnecessary.
-- * No BEGIN/COMMIT: one UPDATE is already atomic, and the SELECT after it is read-only.
--   `ON_ERROR_STOP` is set here as well as on the command line so a hand-run cannot continue
--   past a failed UPDATE.
--
-- ── THE ONE ERROR THIS FILE CAN RAISE, AND WHO ANSWERS IT ───────────────────
-- `token_color` is UNIQUE. If some OTHER row already holds this stack's colour under a
-- different name, the UPDATE fails with `duplicate key value violates unique constraint
-- "known_tokens_token_color_key"` (measured: psql exits 3). That is the correct outcome — a
-- blind DELETE would be worse — and the entrypoint READS the registry before calling this
-- file precisely so the operator gets the conflict named, with a dump, instead of a
-- constraint violation.
\set ON_ERROR_STOP on

UPDATE known_tokens
   SET token_color = :'color',
       decimals    = :decimals,
       asset_id    = :'asset_id'
 WHERE upper(name) = upper(:'name')
   AND (token_color <> :'color'
     OR decimals    <> :decimals
     OR asset_id IS DISTINCT FROM :'asset_id');

-- The row as it now stands, for the one-shot's log. One line, prefixed so it can be grepped
-- out of a container log; `(0 rows)` here means this kernel seeds no SNIGHT row at all, which
-- is a legitimate state and not an error.
SELECT 'SNIGHT_REGISTRY_ROW id=' || id
    || ' color=' || token_color
    || ' name=' || name
    || ' kind=' || kind
    || ' decimals=' || decimals
    || ' asset_id=' || coalesce(asset_id, '<null>') AS row
  FROM known_tokens
 WHERE upper(name) = upper(:'name');

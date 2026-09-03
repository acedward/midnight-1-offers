#!/usr/bin/env bash
# shielded-night-verify — the assertions that need a bun runtime, run INSIDE the compose
# network from the same image the contract was deployed from.
#
#   entrypoint-verify.sh keys        the deployed contract's on-chain verifier keys are
#                                    byte-identical to the ones this image serves
#   entrypoint-verify.sh roundtrip   NIGHT -> sNight -> NIGHT, atomic and two-step, with exact
#                                    balance assertions, driven by a funded wallet
#
# …and three modes that belong to the BOOK CHAIN (`./verify.sh`'s `book` subsection, which
# runs only when the offerfiles profile is up). They drive THIS stack's deployed contract
# rather than a fresh one, and they leave a coin behind on purpose — see driver/snight-driver.ts:
#
#   entrypoint-verify.sh color       print the sNight colour of the deployed contract
#   entrypoint-verify.sh wrap        NIGHT -> sNight, kept (SNIGHT_SEED, SNIGHT_AMOUNT)
#   entrypoint-verify.sh unwrap      sNight -> NIGHT from discovered coins (same two knobs)
#
# It is invoked by scripts/verify-shielded-night.sh through `docker compose run --rm`; the
# service declares `deploy: { replicas: 0 }` so `up.sh` never starts it. With no argument this
# prints what it is and exits 0, so an accidental start is harmless rather than confusing.
#
# WHY THIS RUNS IN A CONTAINER AND NOT ON THE HOST: the checks need bun, the pinned tree, its
# node_modules and the compiled keys. Requiring those on an operator's laptop would make the
# strongest section of verify.sh the one most likely to be skipped.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=shielded-night-verify
# shellcheck source=images/shielded-night/entrypoint-common.sh
. /usr/local/lib/shielded-night/entrypoint-common.sh

MODE="${1:-}"

usage() {
  cat >&2 <<'EOF'
[shielded-night-verify] this service performs no work on its own.

    docker compose run --rm shielded-night-verify keys        on-chain verifier keys
    docker compose run --rm shielded-night-verify roundtrip   NIGHT <-> sNight round trips
    docker compose run --rm shielded-night-verify color       the deployed contract's sNight colour
    docker compose run --rm shielded-night-verify wrap        NIGHT -> sNight, and keep it
    docker compose run --rm shielded-night-verify unwrap      sNight -> NIGHT, coin discovered

./scripts/verify-shielded-night.sh runs them.
EOF
}

# The environment is required by the two WORKING modes, not by the usage text: an accidental
# start with no argument must print what this is and exit 0, not exit 78 on a variable it was
# never going to use.
prepare() {
  require_env MN_INDEXER_URL MN_INDEXER_WS_URL MN_NODE_URL MN_PROOF_SERVER_URL
  MN_ENV="${MN_ENV:-undeployed}"
  export MN_ENV
  cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
}

# ── keys ─────────────────────────────────────────────────────────────────────
#
# Runs UPSTREAM's own scripts/verify-deployment.ts against OUR indexer, with --allow-unlocked
# (project 00007 phase F1, effectstream/shielded-night PR #12, merged into main's head this
# stack pins as of phase H2). That flag exists precisely for this stack's situation: a devnet
# contract is deliberately never locked (spec FR-016), so the script's DEFAULT behaviour — exit
# 0 only if the code matches AND the contract is permanently locked — would report every
# correct local deployment as a failure. `--allow-unlocked` still measures and PRINTS the lock
# state, but folds only the verifier-key/circuit-set check into the exit code, so this
# entrypoint can trust `rc` directly instead of parsing "✓ … == local" / "committee=…" lines
# out of stdout by hand (the ~70-line parse this replaces, incl. the SHIELDED_NIGHT_LOCK-aware
# branching — the flag's own exit-code policy, scripts/verify-args.ts's `verifyOutcome()`,
# treats the lock state as informational ONLY under the flag; the lock state is still printed
# to this container's log by the script itself, so an operator who cares can still read it,
# just not have it decide the exit code). It never weakens the code check: a verifier-key
# mismatch, a missing circuit or an extra circuit still exits non-zero with the flag set — that
# is the negative control (measured live, phase H2: CV_ADDRESS forced to the zero address still
# exits non-zero with the flag set, see the plan's H2 gate log). This mirrors the rewrite
# already shipped on the 2.x sibling (midnight-2-offers phase F2.2's entrypoint-verify.sh).
verify_keys() {
  local address rc=0 circuits n
  address="$(published_address)" || die "no published contract address on ${CONTRACT_FILE}"
  log "contract ${address}"
  log "indexer  ${MN_INDEXER_URL}"

  # The circuits THIS IMAGE SERVES, which is what the browser will prove against. Derived, not
  # typed: a contract that gained a circuit must fail here rather than be silently half-checked.
  # A glob, not `ls`: the names come from a compiler and are plain identifiers, but a glob is
  # both correct for any name and one fewer external process. This LOCAL precondition (reads
  # only this image's own src/managed/keys/, not upstream's stdout) is unchanged by the switch
  # to --allow-unlocked — it is independent of the parse being dropped.
  circuits="$(cd "${REPO_ROOT}/src/managed/keys" && for f in ./*.verifier; do
      b="${f##*/}"; printf '%s\n' "${b%.verifier}"
    done | sort)"
  # `|| true`: grep -c exits 1 when the count is zero, which under errexit would abort here
  # instead of reaching the assertion that is meant to report it.
  n="$(printf '%s\n' "${circuits}" | grep -c . || true)"
  if [ "${n}" -ne 11 ]; then
    die "this image serves ${n} verifier keys, expected 11 — the served artifacts are not this contract"
  fi

  # `-- --allow-unlocked`: the `--` is what makes `bun run` forward the flag to the script
  # rather than swallowing it as a `bun run` option of its own. `|| rc=$?` and not `set +e`: a
  # non-zero exit here is a real failure now (unlike the old strict-by-default call), but it
  # must still be CAUGHT rather than let errexit kill this function before the die() below can
  # name it. Output streams straight to the container log — there is nothing left to parse.
  CV_ADDRESS="${address}" bun run scripts/verify-deployment.ts -- --allow-unlocked || rc=$?
  [ "${rc}" -eq 0 ] || die "verify-deployment.ts --allow-unlocked exited ${rc} — see the output above"
  log "OK: 11/11 circuits' on-chain verifier keys are byte-identical to the served ones"
}

# ── roundtrip ────────────────────────────────────────────────────────────────
#
# THE UPSTREAM SUITE IS THE GATE, run against THIS stack (MN_EXTERNAL_STACK=1) rather than
# against a throwaway testcontainers devnet — that is the strongest e2e available and it needs
# no transcribed copy of the test logic here.
#
# TWO TESTS, SELECTED BY NAME, and the selection is load-bearing. `-t '[smoke]'` would be the
# obvious filter and it would be wrong: the same file also carries a multi-wallet smoke that
# runs on `describeContractWithWallets(['alice','bob'])`, i.e. genesis seeds 0x…01 and 0x…02.
# 0x…01 in this stack is the faucet, the offer-files deploy/mint wallet AND the kernel's
# MIDNIGHT_WALLET_SEED — a second facade on it takes a LONG-LIVED service offline with nothing
# naming the cause. Both selected tests assert EXACT balances (wrapped == N, final NIGHT ==
# starting NIGHT).
verify_roundtrip() {
  require_env SHIELDED_NIGHT_DRIVER_SEED
  refuse_genesis_1 "${SHIELDED_NIGHT_DRIVER_SEED}" "shielded-night verify driver"
  # THE DRIVER MAY BE THE DEPLOYER, and by default it is (genesis-2 — project 00007 question
  # Q6, owner decision D; spec FR-011 amended). What the earlier refusal here protected
  # against was two CONCURRENT facades on one seed, and the deploy one-shot has exited before
  # this container is ever run. genesis-1 is still refused above, because THAT seed does have
  # long-lived facades in this stack (the kernel, the batcher, the faucet).

  export MN_EXTERNAL_STACK=1
  export MN_SEED="${SHIELDED_NIGHT_DRIVER_SEED}"

  log "driver wallet ${SHIELDED_NIGHT_DRIVER_SEED:0:8}…${SHIELDED_NIGHT_DRIVER_SEED: -6}"
  log "atomic: convertToShielded -> convertToUnshielded (one transaction each)"
  bun run test:integration test/integration/shielded-night.combined.test.ts \
      -t 'convertToShielded then convertToUnshielded, each in ONE transaction' \
    || die "the atomic round trip failed"

  log "two-step: depositUnshielded -> withdrawShielded -> depositShielded -> withdrawUnshielded"
  bun run test:integration test/integration/shielded-night.test.ts \
      -t 'full round trip: unshielded -> shielded -> unshielded' \
    || die "the two-step round trip failed"

  log "OK: both round trips completed with exact balance assertions"
}

# ── the book-chain modes ─────────────────────────────────────────────────────
#
# Thin on purpose: every assertion lives in driver/snight-driver.ts, which imports the pinned
# tree's own test/support primitives rather than transcribing them. `color` needs no wallet and
# no chain, so it does NOT wait for the stack — it is a pure derivation from contract.json and
# is called by the token-name one-shot, which must be cheap.
driver() {
  cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
  exec bun run driver/snight-driver.ts "$@"
}

case "${MODE}" in
  keys)      prepare; verify_keys ;;
  roundtrip) prepare; verify_roundtrip ;;
  color)     driver color ;;
  wrap)      prepare; require_env SNIGHT_SEED; refuse_genesis_1 "${SNIGHT_SEED}" "shielded-night wrap driver"; driver wrap ;;
  unwrap)    prepare; require_env SNIGHT_SEED; refuse_genesis_1 "${SNIGHT_SEED}" "shielded-night unwrap driver"; driver unwrap ;;
  ""|help|-h|--help) usage; exit 0 ;;
  *) usage; die "unknown mode '${MODE}'" ;;
esac

exit 0

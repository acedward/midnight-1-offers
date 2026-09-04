#!/usr/bin/env python3
"""Validate a RENDERED docker compose configuration against this repository's frozen pins.

`config/artifact-decisions.json` freezes WHAT this stack promised to consume. It cannot say
whether Compose actually asks for those bytes. This checker closes that gap: it reads the
document `docker compose config --format json` produces — i.e. after every `${VAR:-default}`
has resolved exactly the way the daemon will see it — and asserts the rendered services
really do carry the pinned identities.

What it rejects, and which requirement each maps to:

  * a tag-only external runtime image reference                             FR-8
  * a node/indexer/proof-server reference that is not the frozen digest     FR-2
  * a compose `profiles:` key on any service                                FR-1
  * a forced `platform:` on any service or build                            FR-2
  * a source build arg that is not the pinned full commit SHA               FR-8
  * a warehouse repo/release drifted from the matrix                        FR-4
  * a Compact toolchain version drifted from ITS OWN matrix entry           FR-5
  * a build context or volume path naming the PRIVATE relay subtree         FR-11
  * a relay/UI service fetching private source instead of taking it as a
    named build context                                                     FR-11
  * a published port bound to something other than the loopback default     FR-1
  * a proof-data cache with no writer, more than one writer, or a writable
    reader                                                                  FR-2

WHY A `profiles:` KEY IS A FAILURE AND NOT A STYLE NOTE. In this repository a profile IS a
compose fragment filename, and `up.sh` never passes `--profile`. A service carrying a
compose `profiles:` key is therefore declared, rendered, verified — and then never started,
with no error anywhere. It is the quietest possible way to break a stack.

Usage:
    compose_pins.py <rendered.json> --matrix <path> [--self-test]

Exit status is 0 when every check passes.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path

DIGEST_REF = re.compile(r"^[^\s@]+@sha256:[0-9a-f]{64}$")
GIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")

# Images built by this repository from a local context. Identified by build context or by
# this tag prefix, so a run-specific tag from scripts/pick-ports.sh is fine.
LOCAL_IMAGE_PREFIX = "midnight-1-offers/"

# Compose service name -> the matrix component whose official index digest it must run.
OFFICIAL_OCI_SERVICES = {
    "node": "midnight-node",
    "indexer": "indexer-standalone",
    "proof-server": "proof-server",
}

# Build argument -> the matrix source pin it must equal.
# There is deliberately NO SOLVER_REF entry: since 00011 PR B images/cow-solver is
# `FROM kernel-image` plus its entrypoints and takes no build arg at all, so the solver has no
# pin of its own to bind. Its provenance is asserted on the running image instead
# (scripts/verify-source-pins.sh: /app/.kernel-commit == KERNEL_REF, and no /app/.solver-commit).
BUILD_ARG_SOURCES = {
    "KERNEL_REF": "offerfiles-kernel",
    "FRONTEND_REF": "zswap-da-template",
    "SHIELDED_NIGHT_REF": "shielded-night",
    "RELAY_REF": "intents-relay",
}

# Which Compact toolchain a service's COMPACT_VERSION build arg must equal.
#
# THERE ARE THREE COMPILERS IN THIS STACK AND THEY ARE NOT INTERCHANGEABLE: 0.30.0 for the
# kernel's contract (pinned as a Dockerfile ARG, deliberately not a compose build arg),
# 0.31.0 for the zswap-da template's copy of that same source, and 0.31.1 for shielded-night's
# entirely different contract. Each side's generated bindings are version-checked against ITS
# OWN compact-runtime at import time, so a single check against one matrix entry would either
# reject a correct build or — worse — bless a wrong compiler.
#
# The map is by SERVICE with an explicit default, not by argument name: a new service that
# starts passing COMPACT_VERSION is then checked against `compact` rather than silently
# unchecked, which is the safe direction to be wrong in.
DEFAULT_COMPACT_TOOLCHAIN = "compact"
SERVICE_COMPACT_TOOLCHAIN = {
    "shielded-night": "compact-shielded-night",
    "shielded-night-deploy": "compact-shielded-night",
    "shielded-night-verify": "compact-shielded-night",
    "shielded-night-token-name": "compact-shielded-night",
}

# Anything that looks like a source ref must be a full commit, even if it is not one of the
# four the matrix names — a new *_REF build arg pinned to a branch is the same defect.
REF_ARG_RE = re.compile(r"_REF$")

# Substrings that identify the PRIVATE relay/UI source. They may appear in a build context
# NAME (`reference`) but never in a filesystem path this repository controls.
PRIVATE_MARKERS = ("phase1-native-swaps", "midnight-intents-swaps", "shieldedtech")

PROOF_CACHE_VOLUME = "proof-data"
PROOF_WARM_SERVICE = "proof-warm"

DEFAULT_BIND = "127.0.0.1"


class Failures(list):
    def add(self, where: str, message: str) -> None:
        self.append(f"{where}: {message}")


def _services(doc: dict) -> dict:
    return doc.get("services") or {}


def _is_local_build(svc: dict) -> bool:
    return bool(svc.get("build")) or str(svc.get("image", "")).startswith(LOCAL_IMAGE_PREFIX)


def _component(matrix: dict, cid: str) -> dict:
    for c in matrix.get("components", []):
        if c.get("id") == cid:
            return c
    raise KeyError(cid)


def _source(matrix: dict, sid: str) -> dict:
    for s in matrix.get("sources", []):
        if s.get("id") == sid:
            return s
    raise KeyError(sid)


def _cache_mounts(svc: dict) -> list:
    return [
        v for v in (svc.get("volumes") or [])
        if v.get("type") == "volume" and v.get("source") == PROOF_CACHE_VOLUME
    ]


# ── checks ───────────────────────────────────────────────────────────────────


def _check_digest_refs(f: Failures, doc: dict) -> None:
    for name, svc in sorted(_services(doc).items()):
        image = svc.get("image")
        if not image:
            if not svc.get("build"):
                f.add(name, "service declares neither an image nor a build")
            continue
        if _is_local_build(svc):
            continue
        if not DIGEST_REF.match(image):
            f.add(
                name,
                f"external runtime image is not digest-pinned: {image!r} "
                "(expected <repository>@sha256:<64 hex>; a tag is not an identity)",
            )


def _check_official_oci(f: Failures, doc: dict, matrix: dict) -> None:
    for name, cid in sorted(OFFICIAL_OCI_SERVICES.items()):
        svc = _services(doc).get(name)
        if svc is None:
            continue  # profile not selected in this rendering
        oci = _component(matrix, cid)["oci"]
        expect = f"{oci['repository']}@{oci['indexDigest']}"
        if svc.get("image") != expect:
            f.add(name, f"{cid} must be the frozen official index digest {expect!r}, rendered {svc.get('image')!r}")


def _check_no_compose_profiles(f: Failures, doc: dict) -> None:
    for name, svc in sorted(_services(doc).items()):
        if svc.get("profiles"):
            f.add(
                name,
                f"declares a compose `profiles:` key ({svc['profiles']!r}). In this repository a "
                "profile IS a compose fragment filename and up.sh never passes --profile, so this "
                "service would be declared and then silently never start.",
            )


def _check_no_platform(f: Failures, doc: dict) -> None:
    for name, svc in sorted(_services(doc).items()):
        if svc.get("platform"):
            f.add(name, f"forces platform {svc['platform']!r}; every image here is multiarch")
        build = svc.get("build") or {}
        if build.get("platforms"):
            f.add(name, f"build forces platforms {build['platforms']!r}")


def _check_build_args(f: Failures, doc: dict, matrix: dict) -> None:
    warehouse = matrix.get("warehouse") or {}
    toolchains = {t.get("id"): t for t in matrix.get("toolchains") or []}

    for name, svc in sorted(_services(doc).items()):
        args = ((svc.get("build") or {}).get("args")) or {}
        for key, value in sorted(args.items()):
            if key in BUILD_ARG_SOURCES:
                want = _source(matrix, BUILD_ARG_SOURCES[key]).get("ref")
                if value != want:
                    f.add(name, f"{key}={value!r} != matrix pin {want!r} for {BUILD_ARG_SOURCES[key]}")
            elif REF_ARG_RE.search(key) and not GIT_SHA_RE.match(str(value)):
                f.add(
                    name,
                    f"{key}={value!r} is not a full 40-character commit SHA; a branch or tag is "
                    "not an identity and Docker cannot see it move",
                )

        if "FRONTEND_SUBTREE_SHA" in args:
            want = _source(matrix, "zswap-da-template").get("subtreeSha")
            if args["FRONTEND_SUBTREE_SHA"] != want:
                f.add(name, f"FRONTEND_SUBTREE_SHA={args['FRONTEND_SUBTREE_SHA']!r} != matrix {want!r}")
        if "WAREHOUSE_REPO" in args and args["WAREHOUSE_REPO"] != warehouse.get("repository"):
            f.add(name, f"WAREHOUSE_REPO={args['WAREHOUSE_REPO']!r} != matrix {warehouse.get('repository')!r}")
        if "WAREHOUSE_RELEASE" in args and args["WAREHOUSE_RELEASE"] != warehouse.get("releaseTag"):
            f.add(name, f"WAREHOUSE_RELEASE={args['WAREHOUSE_RELEASE']!r} != matrix {warehouse.get('releaseTag')!r}")
        if "COMPACT_VERSION" in args:
            tid = SERVICE_COMPACT_TOOLCHAIN.get(name, DEFAULT_COMPACT_TOOLCHAIN)
            want = (toolchains.get(tid) or {}).get("version")
            if args["COMPACT_VERSION"] != want:
                f.add(name, f"COMPACT_VERSION={args['COMPACT_VERSION']!r} != matrix {want!r} (toolchain {tid!r})")


def _check_private_source_never_on_disk(f: Failures, doc: dict) -> None:
    """The private relay/UI source must reach a build ONLY as a named build context.

    A `context:` path or a bind mount pointing into the private clone means this repository
    is reading it from a fixed location it controls — the first step towards vendoring it.
    A NAMED context (`additional_contexts: reference: ${RELAY_SOURCE_DIR}/…`) is different:
    the location comes from the operator's own environment, is verified against the pinned
    commit by up.sh, and never becomes a path in the repository.
    """
    for name, svc in sorted(_services(doc).items()):
        build = svc.get("build") or {}
        ctx = str(build.get("context") or "")
        low = ctx.lower()
        for marker in PRIVATE_MARKERS:
            if marker in low:
                f.add(
                    name,
                    f"build context {ctx!r} names the PRIVATE source ({marker!r}). Private "
                    "source may only arrive as a NAMED build context fed from RELAY_SOURCE_DIR, "
                    "never as a path this repository points at directly.",
                )
                break
        for mount in svc.get("volumes") or []:
            src = str(mount.get("source") or "").lower()
            for marker in PRIVATE_MARKERS:
                if marker in src:
                    f.add(name, f"bind-mounts {mount.get('source')!r}, which names the PRIVATE source")
                    break


def _check_bind_addr(f: Failures, doc: dict) -> None:
    """Published ports must be loopback-bound in the committed defaults.

    This is rendered with an EMPTY env file, so what is being checked is what a clean clone
    does — not what somebody's .env happens to say. An operator may still set BIND_ADDR to
    0.0.0.0 deliberately; they may not have the repository ship that way.
    """
    for name, svc in sorted(_services(doc).items()):
        for port in svc.get("ports") or []:
            host_ip = port.get("host_ip")
            if host_ip not in (DEFAULT_BIND, "::1"):
                f.add(
                    name,
                    f"publishes {port.get('published')} on host_ip {host_ip or '(all interfaces)'!r}; "
                    f"the committed default must be {DEFAULT_BIND} so a clean clone cannot expose "
                    "a devnet on a shared machine's network",
                )


def _check_proof_cache(f: Failures, doc: dict) -> None:
    """One writer, read-only readers — only once the volume actually exists."""
    services = _services(doc)
    volumes = doc.get("volumes") or {}
    if PROOF_CACHE_VOLUME not in volumes:
        return  # the profile that declares it is not in this rendering

    writers, readers = [], []
    for name, svc in sorted(services.items()):
        for mount in _cache_mounts(svc):
            (readers if mount.get("read_only") else writers).append(name)

    if writers != [PROOF_WARM_SERVICE]:
        f.add(
            "compose",
            f"the {PROOF_CACHE_VOLUME} volume must be writable by exactly one service "
            f"({PROOF_WARM_SERVICE}); writable in {writers or 'nothing'}. A second writer can "
            "race a reader onto a half-populated cache.",
        )
    if PROOF_WARM_SERVICE not in services:
        f.add("compose", f"the {PROOF_CACHE_VOLUME} volume exists but no `{PROOF_WARM_SERVICE}` service fills it")

    for name in ("proof-server",):
        svc = services.get(name)
        if svc is None:
            continue
        if not _cache_mounts(svc):
            f.add(name, f"proof server does not mount the shared `{PROOF_CACHE_VOLUME}` cache")
        elif name not in readers:
            f.add(name, f"proof server mounts `{PROOF_CACHE_VOLUME}` read-write; readers must be :ro")
        dep = (svc.get("depends_on") or {}).get(PROOF_WARM_SERVICE)
        if not dep:
            f.add(name, f"does not depend on `{PROOF_WARM_SERVICE}` — it could start against an empty cache")
        elif dep.get("condition") != "service_completed_successfully":
            f.add(
                name,
                f"depends on `{PROOF_WARM_SERVICE}` with condition {dep.get('condition')!r}; only "
                "`service_completed_successfully` proves the cache was actually populated",
            )

    src = ((services.get("proof-server") or {}).get("environment") or {}).get("MIDNIGHT_PARAM_SOURCE")
    if src and "github" in str(src).lower():
        f.add(
            "proof-server",
            f"MIDNIGHT_PARAM_SOURCE={src!r} — the development-only GitHub warehouse is not an "
            "admissible proof-parameter source",
        )


def validate(doc: dict, matrix: dict) -> Failures:
    f = Failures()
    _check_digest_refs(f, doc)
    _check_official_oci(f, doc, matrix)
    _check_no_compose_profiles(f, doc)
    _check_no_platform(f, doc)
    _check_build_args(f, doc, matrix)
    _check_private_source_never_on_disk(f, doc)
    _check_bind_addr(f, doc)
    _check_proof_cache(f, doc)
    return f


# ── the self-test base ───────────────────────────────────────────────────────
#
# Every fixture mutates a rendered document, so a check that stopped biting because the
# fragments were restructured fails here rather than passing vacuously.
#
# While the fragments are still P0 placeholders they declare no services, so there is
# nothing to mutate. Rather than skip the self-test — which would let the rules rot
# unnoticed for four phases — it runs against a SYNTHETIC document built from the matrix
# itself, so the digests and refs it asserts come from the same single source of truth. The
# moment the real rendering declares services, that is used instead, and the stronger
# property (fixtures bite the REAL compose files) returns automatically.


def synthetic_base(matrix: dict) -> dict:
    def img(cid):
        o = _component(matrix, cid)["oci"]
        return f"{o['repository']}@{o['indexDigest']}"

    def toolchain(tid):
        # BY ID, never by position. There is more than one Compact toolchain in the matrix
        # (the kernel compiles at 0.30.0, the frontend at 0.31.0), so `toolchains[0]` would
        # silently build the synthetic frontend against whichever entry happens to be first —
        # and _check_build_args, which looks up 'compact' by id, would then disagree with the
        # very document the self-test hands it.
        return next((t for t in matrix.get("toolchains") or [] if t.get("id") == tid), {})

    def port(p):
        return {"mode": "ingress", "host_ip": DEFAULT_BIND, "target": p, "published": str(p), "protocol": "tcp"}

    return {
        "name": "synthetic",
        "services": {
            "node": {"image": img("midnight-node"), "ports": [port(9944)]},
            "indexer": {"image": img("indexer-standalone"), "ports": [port(8088)]},
            "proof-server": {
                "image": img("proof-server"),
                "ports": [port(6300)],
                "environment": {},
                "depends_on": {PROOF_WARM_SERVICE: {"condition": "service_completed_successfully"}},
                "volumes": [{"type": "volume", "source": PROOF_CACHE_VOLUME,
                             "target": "/proof-data", "read_only": True}],
            },
            PROOF_WARM_SERVICE: {
                "image": img("proof-server"),
                "volumes": [{"type": "volume", "source": PROOF_CACHE_VOLUME,
                             "target": "/proof-data", "read_only": False}],
            },
            "postgres": {"image": LOCAL_IMAGE_PREFIX + "postgres:local",
                         "build": {"context": "images/postgres", "args": {}}},
            "kernel": {
                "image": LOCAL_IMAGE_PREFIX + "offerfiles-kernel:local",
                "ports": [port(9999)],
                "build": {"context": "images/offerfiles-kernel",
                          "args": {"KERNEL_REF": _source(matrix, "offerfiles-kernel")["ref"]}},
            },
            "celestia": {
                "image": LOCAL_IMAGE_PREFIX + "celestia:local",
                "build": {"context": "images/celestia",
                          "args": {"WAREHOUSE_REPO": (matrix.get("warehouse") or {}).get("repository"),
                                   "WAREHOUSE_RELEASE": (matrix.get("warehouse") or {}).get("releaseTag")}},
            },
            "frontend": {
                "image": LOCAL_IMAGE_PREFIX + "zswap-da:local",
                "ports": [port(10600)],
                "build": {"context": "images/zswap-da",
                          "args": {"FRONTEND_REF": _source(matrix, "zswap-da-template")["ref"],
                                   "FRONTEND_SUBTREE_SHA": _source(matrix, "zswap-da-template")["subtreeSha"],
                                   "COMPACT_VERSION": toolchain("compact").get("version")}},
            },
            "shielded-night-deploy": {
                "image": LOCAL_IMAGE_PREFIX + "shielded-night-deploy:local",
                "build": {"context": "images/shielded-night", "target": "deploy",
                          "args": {"SHIELDED_NIGHT_REF": _source(matrix, "shielded-night")["ref"],
                                   "COMPACT_VERSION": toolchain("compact-shielded-night").get("version")}},
            },
            "shielded-night": {
                "image": LOCAL_IMAGE_PREFIX + "shielded-night:local",
                "ports": [port(10900)],
                "build": {"context": "images/shielded-night", "target": "web",
                          "args": {"SHIELDED_NIGHT_REF": _source(matrix, "shielded-night")["ref"],
                                   "COMPACT_VERSION": toolchain("compact-shielded-night").get("version")}},
            },
            "relay": {
                "image": LOCAL_IMAGE_PREFIX + "relay:local",
                "ports": [port(13000)],
                "build": {"context": "images/relay",
                          "additional_contexts": {"reference": "/home/op/clone/phase1-native-swaps"},
                          "args": {"RELAY_REF": _source(matrix, "intents-relay")["ref"]}},
            },
            # No build args at all — the solver image is the kernel image plus entrypoints
            # (00011 PR B). It stays in the fixture because _fx_new_ref_arg_on_a_branch adds a
            # *_REF arg to it, which is the "a new pin appeared and nobody bound it" case.
            "solver": {
                "image": LOCAL_IMAGE_PREFIX + "cow-solver:local",
                "build": {"context": "images/cow-solver"},
            },
        },
        "volumes": {PROOF_CACHE_VOLUME: {"name": "synthetic_proof-data"}},
    }


# ── negative fixtures ────────────────────────────────────────────────────────


def _fx_tag_only_node(doc):
    doc["services"]["node"]["image"] = "midnightntwrk/midnight-node:1.0.0"
    return doc


def _fx_tag_only_proof(doc):
    doc["services"]["proof-server"]["image"] = "midnightntwrk/proof-server:8.1.0"
    return doc


def _fx_wrong_node_digest(doc):
    doc["services"]["node"]["image"] = "docker.io/midnightntwrk/midnight-node@sha256:" + "0" * 64
    return doc


def _fx_swapped_node_indexer(doc):
    n = doc["services"]["node"]["image"]
    doc["services"]["node"]["image"] = doc["services"]["indexer"]["image"]
    doc["services"]["indexer"]["image"] = n
    return doc


def _fx_compose_profiles_key(doc):
    doc["services"]["kernel"]["profiles"] = ["offerfiles"]
    return doc


def _fx_forced_platform(doc):
    doc["services"]["indexer"]["platform"] = "linux/amd64"
    return doc


def _fx_forced_build_platform(doc):
    doc["services"]["celestia"]["build"]["platforms"] = ["linux/amd64"]
    return doc


def _fx_kernel_ref_is_a_branch(doc):
    doc["services"]["kernel"]["build"]["args"]["KERNEL_REF"] = "main"
    return doc


def _fx_kernel_ref_drifted(doc):
    doc["services"]["kernel"]["build"]["args"]["KERNEL_REF"] = "0" * 40
    return doc


def _fx_new_ref_arg_on_a_branch(doc):
    doc["services"]["solver"]["build"]["args"]["LADDER_REF"] = "feature/new-ladders"
    return doc


def _fx_subtree_sha_drifted(doc):
    doc["services"]["frontend"]["build"]["args"]["FRONTEND_SUBTREE_SHA"] = "1" * 40
    return doc


def _fx_warehouse_release_drifted(doc):
    doc["services"]["celestia"]["build"]["args"]["WAREHOUSE_RELEASE"] = "0.3.999"
    return doc


def _fx_compact_version_drifted(doc):
    doc["services"]["frontend"]["build"]["args"]["COMPACT_VERSION"] = "0.34.0"
    return doc


def _fx_shielded_night_compiled_with_the_frontend_toolchain(doc):
    # The near-miss this per-service map exists for: 0.31.0 is a real, pinned toolchain in
    # this matrix — it is simply the WRONG one for this contract, and the resulting artifacts
    # would fail shielded-night's own byte-exact rebuild rather than anything obvious.
    doc["services"]["shielded-night"]["build"]["args"]["COMPACT_VERSION"] = "0.31.0"
    return doc


def _fx_shielded_night_ref_drifted(doc):
    doc["services"]["shielded-night-deploy"]["build"]["args"]["SHIELDED_NIGHT_REF"] = "2" * 40
    return doc


def _fx_private_source_as_a_context_path(doc):
    doc["services"]["relay"]["build"]["context"] = "./local/intents-swaps/phase1-native-swaps"
    return doc


def _fx_private_source_bind_mounted(doc):
    doc["services"]["relay"]["volumes"] = [
        {"type": "bind", "source": "./local/midnight-intents-swaps", "target": "/src"}
    ]
    return doc


def _fx_port_on_all_interfaces(doc):
    doc["services"]["kernel"]["ports"][0]["host_ip"] = "0.0.0.0"
    return doc


def _fx_proof_reader_writable(doc):
    for mount in doc["services"]["proof-server"]["volumes"]:
        if mount.get("source") == PROOF_CACHE_VOLUME:
            mount["read_only"] = False
    return doc


def _fx_second_cache_writer(doc):
    doc["services"]["indexer"]["volumes"] = [
        {"type": "volume", "source": PROOF_CACHE_VOLUME, "target": "/proof-data", "read_only": False}
    ]
    return doc


def _fx_no_warm_dependency(doc):
    doc["services"]["proof-server"].pop("depends_on", None)
    return doc


def _fx_weak_warm_condition(doc):
    doc["services"]["proof-server"]["depends_on"][PROOF_WARM_SERVICE]["condition"] = "service_started"
    return doc


def _fx_warm_service_removed(doc):
    # `del`, not `.pop(…, None)`. With a default this never raised, so on a rendering that has
    # no pre-warm service to remove the fixture mutated NOTHING, validate() found nothing
    # wrong, and the self-test reported "the checker did not bite" — blaming the rule for a
    # broken fixture. A KeyError is the machinery's own signal for "not present in this
    # rendering", which is the honest answer. (Found at P3, on a frontend-only rendering.)
    del doc["services"][PROOF_WARM_SERVICE]
    return doc


def _fx_github_param_source(doc):
    doc["services"]["proof-server"]["environment"]["MIDNIGHT_PARAM_SOURCE"] = \
        "https://github.com/effectstream/binaries/releases/download/0.3.120/"
    return doc


SELF_TESTS = [
    ("node pinned by tag instead of digest", _fx_tag_only_node),
    ("proof-server pinned by tag instead of digest", _fx_tag_only_proof),
    ("node digest drifted from the frozen matrix", _fx_wrong_node_digest),
    ("node and indexer images swapped", _fx_swapped_node_indexer),
    ("a service carrying a compose profiles: key", _fx_compose_profiles_key),
    ("a service forcing linux/amd64", _fx_forced_platform),
    ("a build forcing a platform list", _fx_forced_build_platform),
    ("KERNEL_REF pinned to a branch", _fx_kernel_ref_is_a_branch),
    ("KERNEL_REF drifted from the matrix", _fx_kernel_ref_drifted),
    ("a NEW *_REF build arg pinned to a branch", _fx_new_ref_arg_on_a_branch),
    ("frontend subtree SHA drifted", _fx_subtree_sha_drifted),
    ("warehouse release drifted from the matrix", _fx_warehouse_release_drifted),
    ("Compact toolchain version drifted from the matrix", _fx_compact_version_drifted),
    ("shielded-night built with the FRONTEND's Compact toolchain", _fx_shielded_night_compiled_with_the_frontend_toolchain),
    ("SHIELDED_NIGHT_REF drifted from the matrix", _fx_shielded_night_ref_drifted),
    ("PRIVATE source used as a build context path", _fx_private_source_as_a_context_path),
    ("PRIVATE source bind-mounted into a service", _fx_private_source_bind_mounted),
    ("a port published on all interfaces by default", _fx_port_on_all_interfaces),
    ("proof reader given a writable cache mount", _fx_proof_reader_writable),
    ("a second service writing the proof cache", _fx_second_cache_writer),
    ("proof server with no pre-warm dependency", _fx_no_warm_dependency),
    ("pre-warm dependency weakened to service_started", _fx_weak_warm_condition),
    ("the pre-warm service removed entirely", _fx_warm_service_removed),
    ("GitHub set as MIDNIGHT_PARAM_SOURCE", _fx_github_param_source),
]


def run_self_test(doc: dict, matrix: dict) -> int:
    rejected = accepted = 0
    for label, mutate in SELF_TESTS:
        try:
            broken = mutate(copy.deepcopy(doc))
        except (KeyError, IndexError, TypeError):
            # The base document has no such service yet, so this fixture has nothing to
            # break. Report it rather than counting it as a pass.
            print(f"  N/A     {label}   (not present in this rendering)")
            continue
        failures = validate(broken, matrix)
        if failures:
            rejected += 1
            print(f"  reject  {label}\n            -> {failures[0]}")
        else:
            accepted += 1
            print(f"  ACCEPT  {label}   <-- the checker did not bite")
    print(f"\nnegative fixtures: {rejected} rejected, {accepted} accepted")
    return 0 if accepted == 0 else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("rendered", type=Path, help="`docker compose config --format json` output ('-' for stdin)")
    p.add_argument("--matrix", type=Path, required=True)
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()

    raw = sys.stdin.read() if str(args.rendered) == "-" else args.rendered.read_text()
    doc = json.loads(raw)
    matrix = json.loads(args.matrix.read_text())

    failures = validate(doc, matrix)
    for line in failures:
        print(f"FAIL {line}")
    if failures:
        print(f"\n{len(failures)} rendered-compose pin violation(s)")
        return 1
    n = len(_services(doc))
    print(f"rendered compose: {n} service(s), all pins verified"
          + ("   (placeholder fragments declare none yet)" if n == 0 else ""))

    if args.self_test:
        print()
        if n == 0:
            base = synthetic_base(matrix)
            print("self-test base: SYNTHETIC (built from the matrix — the real fragments are still")
            print("                P0 placeholders and declare no services to mutate)")
        else:
            base = doc
            print(f"self-test base: the REAL rendered configuration ({n} services)")
        print()
        return run_self_test(base, matrix)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate config/artifact-decisions.json — the frozen artifact-selection contract.

A static, OFFLINE checker. It touches no network, no Docker and no registry; it answers one
question — "does this repository still make the artifact choices it promised?" — so that a
later change cannot silently:

  * repack a good official OCI image under an owner registry,
  * fall back to compiling from source when an exact warehouse binary exists,
  * pin an external runtime by tag instead of by immutable digest,
  * drop a Linux platform from a multiarch image, or record an attestation manifest as
    though it were a runnable one,
  * select a macOS or Windows asset for a Linux container,
  * use a `legacy-unverified` warehouse row without independent official byte-equality,
  * pin a SOURCE build to a branch, a tag or a short sha instead of a full commit,
  * give the PRIVATE relay source a fetchable repository URL, or drop its leak policy,
  * leave a toolchain unresolved with no open question tracking it, or call one resolved
    without actually pinning any bytes,
  * or half-migrate the proof-data strategy so that neither the pre-warm nor the verified
    generation is really in force.

Run `--self-test` to prove the checker rejects each of those.

Schema v2 (this repository) differs from the 2.x sibling's v1 by adding `sources` and
`toolchains`, and by replacing the warehouse proof-data generation with a pre-warm strategy.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
from pathlib import Path

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
GIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
ENV_VAR_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
GIT_URL_RE = re.compile(r"^https://[^\s]+\.git$")

SCHEMA_VERSION = "artifact-decision-matrix-v2"
SELECTION_ORDER = ["official-oci", "warehouse-binary", "exact-oci-mirror", "source-build"]
RETAINED_DECISIONS = {"official-upstream-direct", "source-build"}
ACQUISITIONS = {"anonymous-git-fetch", "operator-local-clone"}
TOOLCHAIN_DECISIONS = {"official-upstream-direct", "warehouse-binary", "source-build"}
PROOF_DECISIONS = {"prewarm-volume", "warehouse-data-generation"}

# Every key whose value is an identity rather than prose. Editing any of them changes
# pinsDigest, so a digest cannot be "fixed" to make a build pass without a visible,
# reviewable regeneration step (--update-pins).
IDENTITY_KEYS = frozenset({
    "acquisition", "alias", "assetCount", "assetId", "assetName", "assetSha256", "assetSize",
    "branch", "catalogCommit", "catalogProvenance", "checksumsAssetId", "checksumsSha256",
    "commit", "configDigest", "decision", "envVar", "equalityClass", "executableSha256",
    "generation", "id", "indexDigest", "indexMediaType", "installMode", "integrityLevel",
    "layerDigests", "leakPolicy", "linuxArchitectures", "manifestDigest", "memberPath",
    "memberSha256", "memberSize", "name", "openQuestion", "outerSha256", "outerSize",
    "privateRepository", "readableTag", "ref", "releaseId", "releaseTag", "repository",
    "resolved", "selectionOrder", "sourceDirEnv", "strategy", "subtree", "subtreeSha",
    "tagConvention", "upstreamAssetId", "upstreamAssetName", "variant", "version", "volume",
})


def identity_projection(doc) -> list:
    """Flatten every identity-bearing field to a sorted list of 'path=value' strings."""
    out = []

    def walk(node, path: str) -> None:
        if isinstance(node, dict):
            for key in sorted(node):
                child = f"{path}.{key}" if path else key
                if key in IDENTITY_KEYS:
                    out.append(f"{child}={json.dumps(node[key], sort_keys=True, separators=(',', ':'))}")
                walk(node[key], child)
        elif isinstance(node, list):
            for i, item in enumerate(node):
                walk(item, f"{path}[{i}]")

    walk(doc, "")
    return sorted(out)


def compute_pins_digest(doc: dict) -> str:
    projection = dict(doc)
    projection.pop("pinsDigest", None)
    payload = "\n".join(identity_projection(projection)).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


class Failures(list):
    def add(self, component: str, message: str) -> None:
        self.append(f"{component}: {message}")


def _digest(f: Failures, where: str, label: str, value) -> None:
    if not isinstance(value, str) or not DIGEST_RE.match(value):
        f.add(where, f"{label} must be a full 'sha256:<64 hex>' digest, got {value!r}")


def _sha256(f: Failures, where: str, label: str, value) -> None:
    if not isinstance(value, str) or not SHA256_RE.match(value):
        f.add(where, f"{label} must be 64 lowercase hex characters, got {value!r}")


def _commit(f: Failures, where: str, label: str, value) -> None:
    if not isinstance(value, str) or not GIT_SHA_RE.match(value):
        f.add(
            where,
            f"{label} must be a FULL 40-character commit SHA, got {value!r}. A branch or tag "
            "is not an identity — Docker cannot see it move — and `git fetch` of a short sha "
            "fails outright.",
        )


def _forbidden_hit(name: str, forbidden) -> str:
    low = str(name).lower()
    return next((b for b in forbidden if b in low), "")


# ── OCI images ───────────────────────────────────────────────────────────────


def _check_oci_image(f: Failures, where: str, label: str, image: dict, arches) -> None:
    repo = image.get("repository")
    if not isinstance(repo, str) or not repo:
        f.add(where, f"{label}.repository is missing")
    elif "@" in repo or ":" in repo.rsplit("/", 1)[-1]:
        f.add(where, f"{label}.repository must be a bare repository, not a tagged/digested ref: {repo!r}")

    _digest(f, where, f"{label}.indexDigest", image.get("indexDigest"))

    platforms = image.get("platforms")
    if not isinstance(platforms, dict):
        f.add(where, f"{label}.platforms must be an object")
        return

    expected = {f"linux/{a}" for a in arches}
    actual = set(platforms)
    for missing in sorted(expected - actual):
        f.add(where, f"{label} is missing required platform {missing}")
    for extra in sorted(actual - expected):
        # `platforms` means "what this stack may RUN". An OCI index also carries
        # unknown/unknown attestation manifests; recording one here would claim a runnable
        # platform that cannot run, and would mask a genuinely missing architecture.
        f.add(
            where,
            f"{label} declares {extra} as a platform; only {sorted(expected)} are runnable. "
            "An unknown/unknown attestation manifest is provenance metadata, not a platform.",
        )

    for pname, p in platforms.items():
        if not isinstance(p, dict):
            f.add(where, f"{label}.platforms[{pname}] must be an object")
            continue
        _digest(f, where, f"{label}.platforms[{pname}].manifestDigest", p.get("manifestDigest"))
        _digest(f, where, f"{label}.platforms[{pname}].configDigest", p.get("configDigest"))
        for i, layer in enumerate(p.get("layerDigests") or []):
            _digest(f, where, f"{label}.platforms[{pname}].layerDigests[{i}]", layer)
        exe = p.get("executableSha256")
        if exe is not None:
            _sha256(f, where, f"{label}.platforms[{pname}].executableSha256", exe)

    # A platform manifest may never be reused across architectures: that is how an amd64
    # image silently becomes "the arm64 one" too.
    digests = [p.get("manifestDigest") for p in platforms.values() if isinstance(p, dict)]
    if len(digests) != len(set(digests)):
        f.add(where, f"{label} reuses one manifest digest across platforms: {digests}")


# ── warehouse assets ─────────────────────────────────────────────────────────


def _check_warehouse_asset(f: Failures, where: str, plat: str, asset: dict, forbidden, arches) -> None:
    name = asset.get("name")
    if not isinstance(name, str) or not name:
        f.add(where, f"assets[{plat}].name is missing")
        return

    bad = _forbidden_hit(name, forbidden)
    if bad:
        f.add(
            where,
            f"assets[{plat}] selects {name!r}, which contains the forbidden substring {bad!r}; "
            "a Linux container must never install a macOS/Windows or wrong-flavour asset",
        )

    # The platform key and the asset name must agree, so an amd64 slot cannot be quietly fed
    # the arm64 archive (or the reverse).
    try:
        _os, arch = plat.split("/", 1)
    except ValueError:
        f.add(where, f"assets key {plat!r} must look like 'linux/<arch>'")
        return
    if _os != "linux":
        f.add(where, f"assets key {plat!r} must target linux")
    if arch not in arches:
        f.add(where, f"assets key {plat!r} uses unsupported architecture {arch!r}")
    if arch not in name.lower():
        f.add(where, f"assets[{plat}] name {name!r} does not encode architecture {arch!r}")

    _sha256(f, where, f"assets[{plat}].outerSha256", asset.get("outerSha256"))
    if not isinstance(asset.get("outerSize"), int) or asset["outerSize"] <= 0:
        f.add(where, f"assets[{plat}].outerSize must be a positive integer")
    if not isinstance(asset.get("assetId"), int):
        f.add(where, f"assets[{plat}].assetId must be an integer")
    if not asset.get("memberPath"):
        f.add(where, f"assets[{plat}].memberPath is missing")

    member = asset.get("memberSha256")
    provenance = asset.get("catalogProvenance")

    if provenance == "known":
        _sha256(f, where, f"assets[{plat}].memberSha256", member)
        if "officialEquality" in asset:
            f.add(
                where,
                f"assets[{plat}] is catalogued 'known' and must bind its cataloged source "
                "identity directly rather than carrying a legacy officialEquality record",
            )
        src = asset.get("sourceProvenance")
        if isinstance(src, dict):
            _commit(f, where, f"assets[{plat}].sourceProvenance.commit", src.get("commit"))
    elif provenance == "legacy-unverified":
        # The catalog honestly records null source/member fields for these rows. They must
        # NOT be invented; independent official equality is required instead.
        if member is not None:
            f.add(
                where,
                f"assets[{plat}] is 'legacy-unverified' so its catalog member hash is null "
                "upstream; recording one here would fabricate provenance",
            )
        if asset.get("sourceProvenance") is not None:
            f.add(
                where,
                f"assets[{plat}] is 'legacy-unverified'; its catalog source fields are null "
                "upstream and must not be back-filled",
            )
        eq = asset.get("officialEquality")
        if not isinstance(eq, dict) or not eq.get("required"):
            f.add(
                where,
                f"assets[{plat}] is 'legacy-unverified' and MUST carry an independent "
                "officialEquality record binding the exact official release/tag/asset/checksum",
            )
        else:
            for field in ("repository", "releaseTag", "assetName", "verifiedOn"):
                if not eq.get(field):
                    f.add(where, f"assets[{plat}].officialEquality.{field} is missing")
            for field in ("releaseId", "assetId", "checksumsAssetId", "assetSize"):
                if not isinstance(eq.get(field), int):
                    f.add(where, f"assets[{plat}].officialEquality.{field} must be an integer")
            _sha256(f, where, f"assets[{plat}].officialEquality.assetSha256", eq.get("assetSha256"))
            _sha256(f, where, f"assets[{plat}].officialEquality.checksumsSha256", eq.get("checksumsSha256"))
            if eq.get("assetSha256") != asset.get("outerSha256"):
                f.add(
                    where,
                    f"assets[{plat}] equality record does not match: warehouse outer SHA-256 "
                    f"{asset.get('outerSha256')} != official {eq.get('assetSha256')}",
                )
            if isinstance(eq.get("assetSize"), int) and eq["assetSize"] != asset.get("outerSize"):
                f.add(
                    where,
                    f"assets[{plat}] equality record size mismatch: warehouse "
                    f"{asset.get('outerSize')} != official {eq['assetSize']}",
                )
            bad = _forbidden_hit(eq.get("assetName", ""), forbidden)
            if bad:
                f.add(
                    where,
                    f"assets[{plat}].officialEquality.assetName {eq.get('assetName')!r} "
                    f"contains forbidden substring {bad!r}",
                )
    else:
        f.add(where, f"assets[{plat}].catalogProvenance must be 'known' or 'legacy-unverified', got {provenance!r}")


# ── sections ─────────────────────────────────────────────────────────────────


def _validate_components(f: Failures, doc: dict, arches, forbidden) -> set:
    components = doc.get("components")
    if not isinstance(components, list) or not components:
        f.add("document", "components must be a non-empty list")
        return set()

    seen = set()
    for comp in components:
        cid = comp.get("id") or "<unnamed>"
        if cid in seen:
            f.add(cid, "duplicate component id")
        seen.add(cid)

        decision = comp.get("decision")
        if decision not in SELECTION_ORDER:
            f.add(cid, f"decision {decision!r} is not one of {SELECTION_ORDER}")
        if comp.get("inArtifactNormalizationScope") is not True:
            f.add(cid, "components[] entries are in artifact-normalization scope; use retainedPaths otherwise")
        if not comp.get("reason"):
            f.add(cid, "a decision without a recorded reason is not reviewable")
        if not comp.get("version"):
            f.add(cid, "version is missing")

        has_assets = isinstance(comp.get("assets"), dict) and bool(comp["assets"])

        if decision == "official-oci":
            image = comp.get("oci")
            if not isinstance(image, dict):
                f.add(cid, "official-oci requires an 'oci' block")
            else:
                _check_oci_image(f, cid, "oci", image, arches)
            # The whole point of 'official-oci': it must not be quietly repacked.
            if comp.get("destination") is not None:
                f.add(
                    cid,
                    "an official-oci component must NOT declare a destination registry; "
                    "repacking a good official image under an owner registry is out of scope",
                )
            if has_assets:
                f.add(cid, "an official-oci component must not also declare warehouse assets")

        elif decision == "warehouse-binary":
            if not has_assets:
                f.add(cid, "warehouse-binary requires an 'assets' block keyed by linux/<arch>")
            else:
                for m in sorted({f"linux/{a}" for a in arches} - set(comp["assets"])):
                    f.add(cid, f"warehouse-binary is missing an asset for {m}")
                for plat, asset in comp["assets"].items():
                    if isinstance(asset, dict):
                        _check_warehouse_asset(f, cid, plat, asset, forbidden, arches)
                    else:
                        f.add(cid, f"assets[{plat}] must be an object")
            if comp.get("oci") is not None:
                f.add(cid, "a warehouse-binary component must not also pin an official OCI image")

        elif decision == "exact-oci-mirror":
            # No component uses this today — this repository needs no mirror, because every
            # external runtime has a good official index. The rule stays so that adding one
            # later is still checked rather than waved through.
            upstream, dest = comp.get("upstream"), comp.get("destination")
            if not isinstance(upstream, dict):
                f.add(cid, "exact-oci-mirror requires an 'upstream' block")
            else:
                _check_oci_image(f, cid, "upstream", upstream, arches)
            if not isinstance(dest, dict):
                f.add(cid, "exact-oci-mirror requires a 'destination' block")
            else:
                _digest(f, cid, "destination.indexDigest", dest.get("indexDigest"))
                if dest.get("equalityClass") == "exact-mirror":
                    if isinstance(upstream, dict) and dest.get("indexDigest") != upstream.get("indexDigest"):
                        f.add(
                            cid,
                            "an exact-mirror destination digest must equal its upstream index "
                            "digest; otherwise it is a different image and needs an explicit "
                            "revision identity instead",
                        )
                elif not str(dest.get("equalityClass", "")).startswith("revision:"):
                    f.add(cid, f"destination.equalityClass {dest.get('equalityClass')!r} is not recognised")

        elif decision == "source-build":
            if has_assets:
                f.add(
                    cid,
                    "this component declares warehouse assets, so it must not be built from "
                    "source; an exact reusable executable artifact exists",
                )
    return seen


def _validate_sources(f: Failures, doc: dict, taken: set) -> set:
    sources = doc.get("sources")
    if not isinstance(sources, list) or not sources:
        f.add("document", "sources must be a non-empty list — every source build is pinned here")
        return set()

    seen = set()
    for src in sources:
        sid = src.get("id") or "<unnamed>"
        if sid in seen or sid in taken:
            f.add(sid, "duplicate id; a source, a component and a retained path may not share one")
        seen.add(sid)

        if not src.get("reason"):
            f.add(sid, "a pin without a recorded reason is not reviewable")
        if not src.get("role"):
            f.add(sid, "role is missing — a pin nobody can place is a pin nobody maintains")

        _commit(f, sid, "ref", src.get("ref"))
        if "subtreeSha" in src:
            _commit(f, sid, "subtreeSha", src.get("subtreeSha"))
        if src.get("subtree") and "subtreeSha" not in src and src.get("acquisition") != "operator-local-clone":
            f.add(
                sid,
                "declares a subtree but no subtreeSha; the commit alone does not prove which "
                "bytes of it the build extracted",
            )

        env = src.get("envVar")
        if not isinstance(env, str) or not ENV_VAR_RE.match(env):
            f.add(sid, f"envVar must name the environment variable that carries this pin, got {env!r}")

        acq = src.get("acquisition")
        if acq not in ACQUISITIONS:
            f.add(sid, f"acquisition {acq!r} is not one of {sorted(ACQUISITIONS)}")
            continue

        if acq == "anonymous-git-fetch":
            repo = src.get("repository")
            if not isinstance(repo, str) or not GIT_URL_RE.match(repo):
                f.add(sid, f"a publicly fetched source needs an https .git repository URL, got {repo!r}")
            for forbidden_key in ("privateRepository", "sourceDirEnv", "leakPolicy"):
                if src.get(forbidden_key) is not None:
                    f.add(sid, f"a public source must not carry {forbidden_key!r}")

        else:  # operator-local-clone
            # THE LEAK RULE. A private source must be unfetchable BY CONSTRUCTION: if a
            # repository URL is recorded, something in this repository will eventually use
            # it, and a build that can fetch private source is a build that can vendor it.
            if src.get("repository") is not None:
                f.add(
                    sid,
                    "a PRIVATE source must NOT record a fetchable repository URL. Its source "
                    "reaches the build only through the operator's own clone; recording a URL "
                    "invites a fetch, and a fetch is how private bytes get vendored.",
                )
            if not src.get("privateRepository"):
                f.add(sid, "privateRepository must name the private upstream, for the record")
            sd = src.get("sourceDirEnv")
            if not isinstance(sd, str) or not ENV_VAR_RE.match(sd):
                f.add(sid, f"sourceDirEnv must name the variable pointing at the operator's clone, got {sd!r}")
            if src.get("leakPolicy") != "no-bytes-committed":
                f.add(sid, f"leakPolicy must be 'no-bytes-committed', got {src.get('leakPolicy')!r}")
    return seen


def _validate_toolchains(f: Failures, doc: dict, forbidden) -> None:
    toolchains = doc.get("toolchains")
    if not isinstance(toolchains, list):
        f.add("document", "toolchains must be a list (possibly empty)")
        return

    for tc in toolchains:
        tid = tc.get("id") or "<unnamed>"
        if tc.get("decision") not in TOOLCHAIN_DECISIONS:
            f.add(tid, f"decision {tc.get('decision')!r} is not one of {sorted(TOOLCHAIN_DECISIONS)}")
        if not tc.get("version"):
            f.add(tid, "version is missing")
        if not tc.get("reason"):
            f.add(tid, "a toolchain choice without a recorded reason is not reviewable")

        resolved = tc.get("resolved")
        if not isinstance(resolved, bool):
            f.add(tid, f"resolved must be a boolean, got {resolved!r}")
            continue

        if not resolved:
            # An unpinned toolchain is allowed to exist, but only while something is
            # tracking it. Otherwise "we'll pin it later" becomes "nobody pinned it".
            if not tc.get("openQuestion"):
                f.add(
                    tid,
                    "is not resolved and names no openQuestion. An unpinned toolchain must be "
                    "tracked by an open question, or it will be forgotten before the phase "
                    "that consumes it.",
                )
        else:
            assets = tc.get("assets")
            if not isinstance(assets, dict) or not assets:
                f.add(tid, "is marked resolved but pins no assets; 'resolved' means the bytes are named")
            else:
                for plat, a in assets.items():
                    if not isinstance(a, dict):
                        f.add(tid, f"assets[{plat}] must be an object")
                        continue
                    _sha256(f, tid, f"assets[{plat}].outerSha256", a.get("outerSha256"))

        # Applies to candidates as well as to pinned assets: the same releases ship darwin
        # builds, and a darwin zip must never enter a Linux build stage.
        for block_name in ("assets", "candidateAssets"):
            block = tc.get(block_name)
            if not isinstance(block, dict):
                continue
            stack = [block]
            while stack:
                node = stack.pop()
                for k, v in node.items():
                    if isinstance(v, dict):
                        stack.append(v)
                    elif k == "name":
                        bad = _forbidden_hit(v, forbidden)
                        if bad:
                            f.add(
                                tid,
                                f"{block_name} names {v!r}, which contains the forbidden "
                                f"substring {bad!r}; the compiler runs inside a Linux image",
                            )


def _validate_proof_data(f: Failures, doc: dict) -> None:
    pd = doc.get("proofData")
    if not isinstance(pd, dict):
        f.add("proofData", "the proof-data block is missing")
        return

    decision = pd.get("decision")
    if decision not in PROOF_DECISIONS:
        f.add("proofData", f"decision {decision!r} is not one of {sorted(PROOF_DECISIONS)}")
    if not pd.get("volume"):
        f.add("proofData", "volume must name the single volume the proof data lives in")
    if pd.get("midnightParamSourceMustNotBeGitHub") is not True:
        f.add("proofData", "GitHub must never be admissible as MIDNIGHT_PARAM_SOURCE")
    if not pd.get("reason"):
        f.add("proofData", "a strategy without a recorded reason is not reviewable")

    generation = pd.get("generation")
    # The pairing is enforced in BOTH directions, so a half-finished migration to the audited
    # v8 generation cannot pass as either strategy.
    if decision == "prewarm-volume":
        if generation is not None:
            f.add(
                "proofData",
                f"decision is 'prewarm-volume' but a generation ({generation!r}) is recorded. "
                "A generation digest means the verified-generation strategy is in force; pick "
                "one, or the stack claims an integrity guarantee it does not have.",
            )
        if not pd.get("integrityCaveat"):
            f.add(
                "proofData",
                "the pre-warm strategy trusts its upstream at fetch time rather than verifying "
                "recorded bytes. That downgrade must be stated in integrityCaveat, not left to "
                "be inferred from a missing hash.",
            )
    elif decision == "warehouse-data-generation":
        _sha256(f, "proofData", "generation", generation)
        if pd.get("integrityLevel") == "fetch-time-trust":
            f.add("proofData", "a verified generation cannot also be recorded as fetch-time-trust")


def validate(doc: dict) -> Failures:
    f = Failures()

    if doc.get("schemaVersion") != SCHEMA_VERSION:
        f.add("document", f"schemaVersion must be {SCHEMA_VERSION!r}, got {doc.get('schemaVersion')!r}")

    expected_pins = compute_pins_digest(doc)
    if doc.get("pinsDigest") != expected_pins:
        f.add(
            "document",
            "pinsDigest does not cover the current identity fields "
            f"(recorded {doc.get('pinsDigest')!r}, computed {expected_pins!r}). An identity "
            "field was edited without re-verifying it against its source. Re-verify, then run "
            "'./scripts/verify-artifact-decisions.sh --update-pins'.",
        )
    if doc.get("selectionOrder") != SELECTION_ORDER:
        f.add("document", f"selectionOrder must be exactly {SELECTION_ORDER}, got {doc.get('selectionOrder')!r}")

    arches = doc.get("linuxArchitectures")
    if arches != ["amd64", "arm64"]:
        f.add("document", f"linuxArchitectures must be exactly ['amd64', 'arm64'], got {arches!r}")
        arches = ["amd64", "arm64"]

    forbidden = [s.lower() for s in doc.get("forbiddenAssetSubstrings") or []]
    for required in ("macos", "darwin", "windows"):
        if required not in forbidden:
            f.add("document", f"forbiddenAssetSubstrings must include {required!r}")

    wh = doc.get("warehouse") or {}
    if wh.get("mutable") is not True:
        f.add("warehouse", "the 0.3.120 warehouse is mutable; this must stay recorded truthfully")
    if wh.get("distributionTier") != "development-only":
        f.add("warehouse", "distributionTier must remain 'development-only'")
    _commit(f, "warehouse", "catalogCommit", wh.get("catalogCommit"))
    if not isinstance(wh.get("assetCount"), int):
        f.add("warehouse", "assetCount must be an integer")

    component_ids = _validate_components(f, doc, arches, forbidden)
    source_ids = _validate_sources(f, doc, component_ids)
    _validate_toolchains(f, doc, forbidden)
    _validate_proof_data(f, doc)

    taken = component_ids | source_ids
    for entry in doc.get("retainedPaths") or []:
        rid = entry.get("id") or "<unnamed>"
        if entry.get("inArtifactNormalizationScope") is not False:
            f.add(rid, "retainedPaths entries must be marked out of artifact-normalization scope")
        if entry.get("decision") not in RETAINED_DECISIONS:
            f.add(rid, f"decision {entry.get('decision')!r} is not one of {sorted(RETAINED_DECISIONS)}")
        if not entry.get("reason"):
            f.add(rid, "a retained path without a recorded reason is not reviewable")
        if rid in taken:
            f.add(rid, "id also appears in components[] or sources[]; an artifact belongs to exactly one")

    return f


# --------------------------------------------------------------------------- #
# Negative self-tests: prove the checker rejects what it claims to reject.
# --------------------------------------------------------------------------- #

def _comp(doc: dict, cid: str) -> dict:
    return next(c for c in doc["components"] if c["id"] == cid)


def _src(doc: dict, sid: str) -> dict:
    return next(s for s in doc["sources"] if s["id"] == sid)


def _tc(doc: dict, tid: str) -> dict:
    return next(t for t in doc["toolchains"] if t["id"] == tid)


def _fx_altered_asset_digest(doc):
    _comp(doc, "celestia-node")["assets"]["linux/arm64"]["outerSha256"] = "0" * 64
    return doc


def _fx_altered_digest_laundered(doc):
    a = _comp(doc, "celestia-node")["assets"]["linux/arm64"]
    a["outerSha256"] = "0" * 64
    a["memberSha256"] = "0" * 64
    a["catalogProvenance"] = "legacy-unverified"
    return doc


def _fx_altered_official_equality(doc):
    _comp(doc, "celestia-appd")["assets"]["linux/amd64"]["officialEquality"]["assetSha256"] = "1" * 64
    return doc


def _fx_missing_legacy_equality(doc):
    del _comp(doc, "celestia-node")["assets"]["linux/amd64"]["officialEquality"]
    return doc


def _fx_fabricated_legacy_provenance(doc):
    _comp(doc, "celestia-node")["assets"]["linux/amd64"]["memberSha256"] = "2" * 64
    return doc


def _fx_missing_platform(doc):
    del _comp(doc, "midnight-node")["oci"]["platforms"]["linux/arm64"]
    return doc


def _fx_attestation_as_platform(doc):
    _comp(doc, "indexer-standalone")["oci"]["platforms"]["unknown/unknown"] = {
        "manifestDigest": "sha256:57b5182d6d7b0bf2ea8b1ac0bae57f58896f98f48603472364acc018a2239ce7",
        "configDigest": "sha256:" + "a" * 64,
    }
    return doc


def _fx_platform_digest_reuse(doc):
    p = _comp(doc, "proof-server")["oci"]["platforms"]
    p["linux/arm64"]["manifestDigest"] = p["linux/amd64"]["manifestDigest"]
    return doc


def _fx_missing_warehouse_arch(doc):
    del _comp(doc, "celestia-appd")["assets"]["linux/arm64"]
    return doc


def _fx_macos_asset(doc):
    _comp(doc, "celestia-node")["assets"]["linux/arm64"]["name"] = "celestia-node-macos-arm64-v0.28.4.tar.gz"
    return doc


def _fx_standalone_lookalike(doc):
    _comp(doc, "celestia-appd")["assets"]["linux/amd64"]["officialEquality"]["assetName"] = \
        "celestia-app-standalone_Linux_x86_64.tar.gz"
    return doc


def _fx_arch_name_mismatch(doc):
    _comp(doc, "celestia-node")["assets"]["linux/arm64"]["name"] = "celestia-node-linux-amd64-v0.28.4.tar.gz"
    return doc


def _fx_tag_only_ref(doc):
    _comp(doc, "midnight-node")["oci"]["indexDigest"] = "1.0.0"
    return doc


def _fx_official_repack(doc):
    node = _comp(doc, "midnight-node")
    node["destination"] = {
        "repository": "ghcr.io/effectstream/midnight-node",
        "alias": "1.0.0",
        "equalityClass": "exact-mirror",
        "indexDigest": node["oci"]["indexDigest"],
    }
    return doc


def _fx_source_build_over_warehouse(doc):
    _comp(doc, "celestia-appd")["decision"] = "source-build"
    return doc


def _fx_mirror_not_exact(doc):
    doc["components"].append({
        "id": "some-mirror", "version": "1.0.0", "inArtifactNormalizationScope": True,
        "decision": "exact-oci-mirror", "reason": "test",
        "upstream": _comp(doc, "proof-server")["oci"],
        "destination": {"repository": "ghcr.io/x/y", "alias": "z",
                        "equalityClass": "exact-mirror", "indexDigest": "sha256:" + "3" * 64},
    })
    return doc


def _fx_source_ref_is_a_branch(doc):
    _src(doc, "offerfiles-kernel")["ref"] = "main"
    return doc


def _fx_source_ref_is_short(doc):
    _src(doc, "offerfiles-kernel")["ref"] = "6c5ebab"
    return doc


def _fx_private_source_given_a_url(doc):
    _src(doc, "intents-relay")["repository"] = "https://github.com/shieldedtech/midnight-intents-swaps.git"
    return doc


def _fx_private_source_loses_leak_policy(doc):
    del _src(doc, "intents-relay")["leakPolicy"]
    return doc


def _fx_private_source_loses_source_dir(doc):
    del _src(doc, "intents-relay")["sourceDirEnv"]
    return doc


def _fx_public_source_claims_privacy(doc):
    _src(doc, "cow-solver")["privateRepository"] = "someone/else"
    return doc


def _fx_subtree_without_sha(doc):
    del _src(doc, "zswap-da-template")["subtreeSha"]
    return doc


def _fx_source_id_collides(doc):
    _src(doc, "cow-solver")["id"] = "midnight-node"
    return doc


# The three toolchain fixtures below SYNTHESISE the state they test rather than assuming the
# live document is still in it. They were originally written against an UNRESOLVED `compact`
# entry (Q9 was open at P0); when P3 resolved it, "delete openQuestion" and "set resolved" both
# stopped describing a defect — one raised KeyError, the other mutated nothing. A fixture that
# quietly stops biting is exactly what --self-test exists to prevent, so each now sets up its
# own precondition and is independent of how the entry happens to be pinned today.
def _fx_unresolved_toolchain_untracked(doc):
    tc = _tc(doc, "compact")
    tc["resolved"] = False
    tc.pop("openQuestion", None)
    return doc


def _fx_toolchain_resolved_without_pins(doc):
    tc = _tc(doc, "compact")
    tc["resolved"] = True
    tc.pop("assets", None)
    return doc


def _fx_toolchain_darwin_asset(doc):
    _tc(doc, "compact")["assets"]["linux/arm64"]["name"] = \
        "compactc_v0.31.0_aarch64-darwin.zip"
    return doc


def _fx_prewarm_claims_a_generation(doc):
    doc["proofData"]["generation"] = "4" * 64
    return doc


def _fx_generation_without_a_digest(doc):
    doc["proofData"]["decision"] = "warehouse-data-generation"
    return doc


def _fx_prewarm_hides_its_caveat(doc):
    del doc["proofData"]["integrityCaveat"]
    return doc


def _fx_github_param_source_allowed(doc):
    doc["proofData"]["midnightParamSourceMustNotBeGitHub"] = False
    return doc


# (label, mutation, repin). repin=True recomputes pinsDigest after the mutation so the
# fixture exercises its own rule rather than tripping the pins guard. repin=False is used
# only to prove the pins guard itself catches a hand-edited identity field.
SELF_TESTS = [
    ("altered warehouse asset digest, not re-pinned", _fx_altered_asset_digest, False),
    ("altered digest laundered as legacy-unverified", _fx_altered_digest_laundered, True),
    ("altered official equality checksum", _fx_altered_official_equality),
    ("legacy row missing official equality evidence", _fx_missing_legacy_equality),
    ("fabricated provenance on a legacy-unverified row", _fx_fabricated_legacy_provenance),
    ("missing OCI platform", _fx_missing_platform),
    ("attestation manifest recorded as a runnable platform", _fx_attestation_as_platform),
    ("one manifest digest reused across two platforms", _fx_platform_digest_reuse),
    ("missing warehouse architecture", _fx_missing_warehouse_arch),
    ("macOS asset selected for a Linux container", _fx_macos_asset),
    ("celestia -standalone look-alike asset", _fx_standalone_lookalike),
    ("architecture/name mismatch in a warehouse asset", _fx_arch_name_mismatch),
    ("tag-only external runtime reference", _fx_tag_only_ref),
    ("repacking a good official OCI image", _fx_official_repack),
    ("source build chosen despite an exact warehouse binary", _fx_source_build_over_warehouse),
    ("exact-mirror destination that is not byte-equal", _fx_mirror_not_exact),
    ("source pinned to a BRANCH instead of a commit", _fx_source_ref_is_a_branch),
    ("source pinned to a SHORT sha", _fx_source_ref_is_short),
    ("PRIVATE source handed a fetchable repository URL", _fx_private_source_given_a_url),
    ("PRIVATE source stripped of its leak policy", _fx_private_source_loses_leak_policy),
    ("PRIVATE source stripped of its source-dir variable", _fx_private_source_loses_source_dir),
    ("public source claiming to be private", _fx_public_source_claims_privacy),
    ("subtree recorded without its subtree SHA", _fx_subtree_without_sha),
    ("a source id colliding with a component id", _fx_source_id_collides),
    ("unresolved toolchain tracked by no open question", _fx_unresolved_toolchain_untracked),
    ("toolchain marked resolved while pinning no bytes", _fx_toolchain_resolved_without_pins),
    ("toolchain candidate pointing at a darwin asset", _fx_toolchain_darwin_asset),
    ("pre-warm strategy claiming a verified generation", _fx_prewarm_claims_a_generation),
    ("verified-generation strategy with no generation digest", _fx_generation_without_a_digest),
    ("pre-warm hiding its fetch-time-trust caveat", _fx_prewarm_hides_its_caveat),
    ("GitHub made admissible as MIDNIGHT_PARAM_SOURCE", _fx_github_param_source_allowed),
]


def run_self_test(doc: dict) -> int:
    bad = 0
    for entry in SELF_TESTS:
        label, mutate = entry[0], entry[1]
        repin = entry[2] if len(entry) > 2 else True
        fixture = mutate(copy.deepcopy(doc))
        if repin:
            fixture["pinsDigest"] = compute_pins_digest(fixture)
        failures = validate(fixture)
        if failures:
            print(f"  rejected  {label}")
            print(f"            -> {failures[0]}")
        else:
            print(f"  ACCEPTED  {label}  <-- the validator failed to catch this")
            bad += 1
    return bad


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("matrix", type=Path, help="path to config/artifact-decisions.json")
    parser.add_argument("--self-test", action="store_true", help="also prove the checker rejects known-bad fixtures")
    parser.add_argument(
        "--update-pins", action="store_true",
        help="recompute pinsDigest after an identity field was legitimately re-verified against its source",
    )
    args = parser.parse_args()

    try:
        doc = json.loads(args.matrix.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"artifact decision matrix not found: {args.matrix}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as exc:
        print(f"artifact decision matrix is not valid JSON: {exc}", file=sys.stderr)
        return 1

    if args.update_pins:
        recomputed = compute_pins_digest(doc)
        if doc.get("pinsDigest") == recomputed:
            print(f"  pinsDigest already current: {recomputed}")
        else:
            doc["pinsDigest"] = recomputed
            args.matrix.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            print(f"  pinsDigest updated to {recomputed}")

    failures = validate(doc)
    if failures:
        for line in failures:
            print(f"  {line}", file=sys.stderr)
        print(f"{len(failures)} artifact-decision violation(s)", file=sys.stderr)
        return 1

    print(
        f"  matrix is internally consistent: {len(doc.get('components') or [])} in-scope "
        f"component(s), {len(doc.get('sources') or [])} source pin(s), "
        f"{len(doc.get('toolchains') or [])} toolchain(s), "
        f"{len(doc.get('retainedPaths') or [])} retained path(s)"
    )

    if args.self_test:
        print(f"  negative fixtures ({len(SELF_TESTS)}):")
        bad = run_self_test(doc)
        if bad:
            print(f"{bad} negative fixture(s) were not rejected", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Fail if this PUBLIC repository carries any byte of the PRIVATE relay/intents-UI source.

`midnight-1-offers` is public. The Midnight Intents relay and its browser UI are built from
`shieldedtech/midnight-intents-swaps`, which is private, and the project rule (spec FR-11,
plan Q4) is absolute: relay/UI source is consumed ONLY through an operator-local clone named
by `RELAY_SOURCE_DIR`, and NOT ONE BYTE of it is ever committed here.

`.gitignore` stops the obvious accident (a clone dropped in `local/`). This is the gate that
catches the rest: a vendored file, a `git apply` patch whose context lines quote private
source, a copied lockfile, a committed build output, or an import of a private workspace
package.

WHY IT IS NOT A BARE `grep -ri shieldedtech`
--------------------------------------------
The repository has to be ABLE to name the upstream it builds from — in its README, in its
`.env.example` comments, in the pinned identity recorded in `config/artifact-decisions.json`.
A grep that forbade the string outright would either fail on day one or be switched off. So
the scanner distinguishes NAMING the private repository (allowed, in a few precise places)
from CARRYING its content (never allowed):

  hard markers      never allowed anywhere. `@phase1-native-swaps/` is the private
                    workspace's package scope: it appears in imports, `package.json`
                    dependency maps and lockfiles, and in nothing a human would write as
                    prose. One hit is copied source, full stop.

  soft markers      the repository's own names. Allowed only in:
                      * Markdown (`*.md`) — prose and documentation;
                      * a COMMENT line (`^\\s*#`) of a shell script, compose fragment,
                        Dockerfile, `.env.example` or `.gitignore`;
                      * an allowlisted KEY of `config/artifact-decisions.json`, so a pin
                        can record what it pins;
                      * an explicitly reviewed line in EXPLICIT_ALLOW below.
                    Anywhere else — a TypeScript file, a JSON blob, a patch body, a compose
                    `image:` line — it is content, and it fails.

  structure         no tracked path may be named after the private subtree, nothing may be
                    tracked under `local/`, and no lockfile may be tracked under the
                    relay/UI image directories (a copied lockfile is a full dependency
                    graph of the private repo).

A stale EXPLICIT_ALLOW entry is itself a failure, so the allowlist cannot quietly grow into
a blanket exemption for lines that no longer exist.

    scripts/lib/leak_scan.py <repo-root> [--self-test]

Exit 0 = clean.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# ── markers ──────────────────────────────────────────────────────────────────

# Copied source, in any context. The scoped package name of the private workspace.
HARD_MARKERS = (
    "@phase1-native-swaps/",
)

# The private repository's names. Allowed where the repository legitimately refers to
# the upstream it builds from; forbidden everywhere else.
SOFT_MARKERS = (
    "shieldedtech",
    "midnight-intents-swaps",
    "phase1-native-swaps",
)

# ── contexts in which a soft marker is legitimate ────────────────────────────

PROSE_SUFFIXES = {".md"}

# Files where `^\s*#` is a comment.
COMMENTABLE_SUFFIXES = {".sh", ".yml", ".yaml", ".tsv", ".env", ".example"}
COMMENTABLE_NAMES = {".gitignore", ".gitattributes", ".dockerignore", ".env.example"}
COMMENT_RE = re.compile(r"^\s*#")

DECISIONS_PATH = "config/artifact-decisions.json"

# JSON keys of config/artifact-decisions.json whose VALUES may name the private repository.
# Every one of these is an identity or a recorded rationale — never source content.
ALLOWED_JSON_KEYS = frozenset({
    "$comment",
    "acquisition",
    "id",
    "leakPolicy",
    "note",
    "privateRepository",
    "reason",
    "repository",
    "role",
    "sourceDirEnv",
    "subtree",
    "warning",
})

# The scanner and its wrapper necessarily spell the markers out. They are the only files
# exempt from their own rules, and the exemption is by exact path.
SELF_EXEMPT = frozenset({
    "scripts/lib/leak_scan.py",
    "scripts/verify-no-private-source.sh",
})

# Reviewed non-comment lines that must name the private repository to be useful — an
# operator-facing failure message is worthless if it cannot say what to clone. Each entry
# MUST still match at least one line, so the allowlist cannot rot into a blanket exemption.
#
#   path     tracked path, exact
#   pattern  regex the whole line must match
#   why      why naming the repo there is not a leak
EXPLICIT_ALLOW = (
    {
        "path": "scripts/lib/common.sh",
        "pattern": r'^\s*(info|dim|err|warn)\s+".*midnight-intents-swaps.*"$',
        "why": "assert_relay_source()'s fatal 'RELAY_SOURCE_DIR is unset' guidance has to name "
               "the repository the operator must clone; a leak gate that forced that message "
               "to be useless would just get switched off",
    },
)

# A lockfile under these directories would publish the private repository's complete
# dependency graph, resolved versions and integrity hashes.
LOCKFILE_NAMES = frozenset({
    "package-lock.json", "npm-shrinkwrap.json", "yarn.lock",
    "pnpm-lock.yaml", "bun.lock", "bun.lockb",
})
LOCKFILE_FORBIDDEN_DIRS = ("images/relay/", "images/intents-ui/")

# No tracked path may be named after the private subtree, and nothing may be tracked
# under the conventional local-clone directory.
FORBIDDEN_PATH_SUBSTRINGS = ("phase1-native-swaps", "midnight-intents-swaps", "shieldedtech")
FORBIDDEN_PATH_PREFIXES = ("local/",)


class Findings(list):
    def add(self, path: str, line_no: int | None, message: str) -> None:
        where = f"{path}:{line_no}" if line_no else path
        self.append(f"{where}: {message}")


# ── per-file rules ───────────────────────────────────────────────────────────


def _is_commentable(path: str) -> bool:
    name = Path(path).name
    if name in COMMENTABLE_NAMES or name.startswith("Dockerfile"):
        return True
    return Path(path).suffix in COMMENTABLE_SUFFIXES


def _explicit_allows(path: str) -> list[dict]:
    return [e for e in EXPLICIT_ALLOW if e["path"] == path]


def _json_key_paths_with_markers(node, key: str | None, trail: str) -> list[tuple[str, str, str]]:
    """(json path, holding key, marker) for every string value carrying a soft marker."""
    hits: list[tuple[str, str, str]] = []
    if isinstance(node, dict):
        for k, v in node.items():
            hits += _json_key_paths_with_markers(v, k, f"{trail}.{k}" if trail else k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            hits += _json_key_paths_with_markers(v, key, f"{trail}[{i}]")
    elif isinstance(node, str):
        low = node.lower()
        for marker in SOFT_MARKERS:
            if marker in low:
                hits.append((trail, key or "<root>", marker))
                break
    return hits


def scan_text(path: str, text: str) -> tuple[Findings, set[int]]:
    """Scan one tracked file. Returns (findings, indices of EXPLICIT_ALLOW entries used)."""
    findings = Findings()
    used: set[int] = set()

    if path in SELF_EXEMPT:
        return findings, used

    allows = _explicit_allows(path)
    prose = Path(path).suffix in PROSE_SUFFIXES
    commentable = _is_commentable(path)

    # config/artifact-decisions.json is checked structurally: a marker may sit only in an
    # allowlisted key's value, which a line-based rule could not express.
    json_allowed_lines: set[int] = set()
    if path == DECISIONS_PATH:
        try:
            doc = json.loads(text)
        except json.JSONDecodeError as exc:
            findings.add(path, None, f"is not valid JSON, so its pins cannot be audited: {exc}")
            doc = None
        if doc is not None:
            for jpath, key, marker in _json_key_paths_with_markers(doc, None, ""):
                if key not in ALLOWED_JSON_KEYS:
                    findings.add(
                        path, None,
                        f"private-source marker {marker!r} in {jpath} — key {key!r} is not one of "
                        f"the identity/rationale keys allowed to name the private repository "
                        f"({', '.join(sorted(ALLOWED_JSON_KEYS))})",
                    )
        # Every line of it is then exempt from the soft line rule; the structural pass above
        # is the real check and is strictly stronger.
        json_allowed_lines = set(range(1, text.count("\n") + 2))

    for line_no, line in enumerate(text.splitlines(), start=1):
        low = line.lower()

        for marker in HARD_MARKERS:
            if marker.lower() in low:
                findings.add(
                    path, line_no,
                    f"PRIVATE SOURCE: {marker!r} is the private workspace's package scope; it "
                    "only ever appears in copied source, imports, manifests or lockfiles",
                )

        soft_hit = next((m for m in SOFT_MARKERS if m in low), None)
        if soft_hit is None:
            continue
        if prose or line_no in json_allowed_lines:
            continue
        if commentable and COMMENT_RE.match(line):
            continue
        matched = False
        for entry in allows:
            if re.match(entry["pattern"], line):
                used.add(EXPLICIT_ALLOW.index(entry))
                matched = True
                break
        if matched:
            continue
        findings.add(
            path, line_no,
            f"private-source marker {soft_hit!r} outside an allowed context "
            "(Markdown prose, a '#' comment, an allowlisted config/artifact-decisions.json key, "
            "or a reviewed EXPLICIT_ALLOW line)",
        )

    return findings, used


def scan_paths(paths: list[str]) -> Findings:
    findings = Findings()
    for path in paths:
        for bad in FORBIDDEN_PATH_PREFIXES:
            if path.startswith(bad):
                findings.add(path, None, f"tracked under {bad!r}, which exists only for the "
                                         "operator's own PRIVATE clone and must never be committed")
        for bad in FORBIDDEN_PATH_SUBSTRINGS:
            if bad in path.lower():
                findings.add(path, None, f"path is named after the private source ({bad!r}); a file "
                                         "at this path is a vendored copy by construction")
        if Path(path).name in LOCKFILE_NAMES and path.startswith(LOCKFILE_FORBIDDEN_DIRS):
            findings.add(path, None, "a lockfile here would publish the private repository's "
                                     "complete resolved dependency graph")
    return findings


# ── driver ───────────────────────────────────────────────────────────────────


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [p for p in out.split("\0") if p]


def run(root: Path) -> int:
    paths = tracked_files(root)
    findings = Findings()
    findings += scan_paths(paths)

    used: set[int] = set()
    scanned = 0
    for path in paths:
        full = root / path
        try:
            text = full.read_text(encoding="utf-8")
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue  # binary or a submodule pointer: no text markers to find
        scanned += 1
        f, u = scan_text(path, text)
        findings += f
        used |= u

    for i, entry in enumerate(EXPLICIT_ALLOW):
        if i not in used:
            findings.add(
                entry["path"], None,
                f"EXPLICIT_ALLOW entry {entry['pattern']!r} matched nothing — a stale exemption "
                "must be deleted, not left standing as a blanket allowance",
            )

    if findings:
        for line in findings:
            print(f"  {line}", file=sys.stderr)
        print(f"{len(findings)} private-source leak finding(s)", file=sys.stderr)
        return 1

    print(f"  no private-source markers in {scanned} tracked text file(s) "
          f"({len(paths)} tracked total)")
    return 0


# ── negative self-tests: prove each rule bites ───────────────────────────────

SELF_TESTS = [
    ("vendored TypeScript importing a private workspace package",
     "images/relay/server.ts", 'import { quote } from "@phase1-native-swaps/common";\n'),
    ("a private package name in a package.json dependency map",
     "images/relay/package.json", '{"dependencies":{"@phase1-native-swaps/common":"1.0.0"}}\n'),
    ("a patch file quoting private source in its context lines",
     "images/relay/relay.patch", "--- a/packages/relay/src/index.ts\n+++ b/phase1-native-swaps/x\n"),
    ("a compose image built from a path named after the private subtree",
     "compose/solver.yml", "services:\n  relay:\n    build: ./phase1-native-swaps/relay\n"),
    ("a shell script with a non-comment reference outside the allowlist",
     "scripts/verify-solver.sh", 'SRC=/opt/shieldedtech/midnight-intents-swaps\n'),
    ("a marker smuggled into a non-identity key of the decision matrix",
     DECISIONS_PATH, '{"components":[{"buildCommand":"cd phase1-native-swaps && npm ci"}]}\n'),
    ("an unparseable decision matrix (pins could not be audited)",
     DECISIONS_PATH, "{not json\n"),
]

PATH_SELF_TESTS = [
    ("a tracked file under the local private-clone directory", "local/relay/src/index.ts"),
    ("a tracked path named after the private subtree", "images/phase1-native-swaps/Dockerfile"),
    ("a copied lockfile under the relay image", "images/relay/package-lock.json"),
]

POSITIVE_TESTS = [
    ("README prose naming the upstream", "README.md",
     "The solver profile builds from shieldedtech/midnight-intents-swaps.\n"),
    ("an .env.example comment naming the upstream", ".env.example",
     "# RELAY_SOURCE_DIR: your own clone of shieldedtech/midnight-intents-swaps\nRELAY_SOURCE_DIR=\n"),
    ("a compose fragment comment naming the upstream", "compose/solver.yml",
     "# relay: built from the phase1-native-swaps subtree of the private repo\nservices: {}\n"),
    ("an allowlisted identity key in the decision matrix", DECISIONS_PATH,
     '{"sources":[{"id":"relay","repository":"shieldedtech/midnight-intents-swaps"}]}\n'),
]


def run_self_test() -> int:
    bad = 0
    print("  negative fixtures (each must be REJECTED):")
    for label, path, text in SELF_TESTS:
        findings, _ = scan_text(path, text)
        if findings:
            print(f"    rejected  {label}")
            print(f"              -> {findings[0]}")
        else:
            print(f"    ACCEPTED  {label}   <-- the scanner did not bite")
            bad += 1
    for label, path in PATH_SELF_TESTS:
        findings = scan_paths([path])
        if findings:
            print(f"    rejected  {label}")
            print(f"              -> {findings[0]}")
        else:
            print(f"    ACCEPTED  {label}   <-- the scanner did not bite")
            bad += 1

    print("  positive fixtures (each must be ACCEPTED):")
    for label, path, text in POSITIVE_TESTS:
        findings, _ = scan_text(path, text)
        if findings:
            print(f"    REJECTED  {label}   <-- the scanner is too strict to live with")
            print(f"              -> {findings[0]}")
            bad += 1
        else:
            print(f"    accepted  {label}")
    return bad


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("root", type=Path, nargs="?", default=Path("."))
    p.add_argument("--self-test", action="store_true",
                   help="also prove every rule rejects a known leak and accepts legitimate prose")
    args = p.parse_args()

    rc = run(args.root.resolve())
    if args.self_test:
        bad = run_self_test()
        if bad:
            print(f"{bad} self-test fixture(s) behaved wrongly", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())

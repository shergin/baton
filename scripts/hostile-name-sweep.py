#!/usr/bin/env python3
"""Type-checks, one document at a time, the hostile names the corpus tests
prove accepted but never compile: the name of a fragment, a query, a
mutation, a subscription and a refetch query, and of a fragment a query or
a mutation spreads; each name as a fragment spread plainly, with
arguments, under `@defer` and under `@catch`; and each name as an `@inline`
fragment, as one a value spreads, and as one a query spreads plainly, with
arguments, under a condition with an alias, under `@defer` and caught under
an alias. Each is a type of the whole
module, and one named like a type the target's own sources spell would
change what they mean, so the corpus cannot hold them. A name batonc refuses
is refused; a name it accepts whose Swift does not type-check is a defect.

From the repository root, after `scripts/build-compiler.sh` and a debug
`swift build` of the package (`--build-tests` or `--target Baton`):

    python3 scripts/hostile-name-sweep.py [position...]

Run it after touching how the emitter spells a type, a fragment or an
operation, and when the floor moves to a Swift with new contextual keywords.
CI runs it in the Swift job. About two minutes on all cores of an M1 Pro.
"""
import os
import platform
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = f"{ROOT}/swift/Tests/BatonTests/baton.json"
MODULES = f"{ROOT}/.build/debug/Modules"
ARCHITECTURE = {"arm64": "arm64", "x86_64": "x86_64"}[platform.machine()]
TARGET = f"{ARCHITECTURE}-apple-macos26.0"

POSITIONS = {
    "fragment": "fragment HOSTILE on Character { name }",
    "query": "query HOSTILE { character(id: 1) { id } }",
    "mutation": 'mutation HOSTILE { setFavorite(id: "1", favorite: true) { character { id } } }',
    "subscription": 'subscription HOSTILE { noteAdded(characterId: "1") { noteEdge { cursor } } }',
    "refetch-query": 'fragment Probe_character on Character @refetchable(queryName: "HOSTILE") { name }',
    "query-spread": "fragment HOSTILE on Character { name } query Probe { character(id: 1) { ...HOSTILE } }",
    "mutation-spread": 'fragment HOSTILE on Character { name } mutation Probe { setFavorite(id: "1", favorite: true) { character { ...HOSTILE } } }',
    "spread-forms": """fragment HOSTILE on Character @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) @throwOnFieldError { name @include(if: $flag) }
fragment Spreader_character on Character {
  ... @alias(as: "boundSpread") { ...HOSTILE @arguments(flag: false) }
  ...HOSTILE
  ... @alias(as: "caughtSpread") @catch { ...HOSTILE }
}
query Deferring { character(id: 1) { ...HOSTILE @defer } }""",
    "inline-fragment": "fragment HOSTILE on Character @inline { name }",
    "value-spread": "fragment HOSTILE on Character @inline { name } fragment Probe_character on Character @inline { ...HOSTILE }",
    "value-spread-forms": """fragment HOSTILE on Character @inline @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) @throwOnFieldError { name @include(if: $flag) }
query Probe($flag: Boolean!) {
  character(id: 1) {
    ...HOSTILE
    ...HOSTILE @arguments(flag: false) @alias(as: "boundValue")
    ...HOSTILE @include(if: $flag) @alias(as: "conditionalValue")
    ... @alias(as: "caughtValue") @catch { ...HOSTILE }
  }
}
query Deferring { character(id: 1) { ...HOSTILE @defer } }""",
}


def batonc():
    """The compiler the build scripts made: the release binary, else a debug one."""
    for profile in ("release", "debug"):
        path = f"{ROOT}/compiler/target/{profile}/batonc"
        if os.path.exists(path):
            return path
    sys.exit("hostile-name-sweep: no batonc; run scripts/build-compiler.sh first")


def hostile_names():
    """Every name the corpus's aliased scalar fields hold, and the ones that
    position refuses besides: close to the tests' own list."""
    corpus = open(f"{ROOT}/swift/Tests/BatonTests/HostileNameDocuments.swift").read()
    start = corpus.index("fragment HostileScalars_character")
    section = corpus[start:corpus.index('"""', start)]
    names = re.findall(r"(\w+): name\b", section)
    return names + ["anchor", "recordID", "Slots", "_hostileHidden"]


def check(job):
    compiler, position, name = job
    with tempfile.TemporaryDirectory() as work:
        document = f"{work}/Probe.graphql"
        open(document, "w").write(POSITIONS[position].replace("HOSTILE", name) + "\n")
        generated = subprocess.run(
            [compiler, "generate", "--config", CONFIG, "--out", f"{work}/out", document],
            capture_output=True, text=True)
        if generated.returncode != 0:
            return position, name, "refused", generated.stderr.strip().splitlines()[0]
        files = [f"{work}/out/{file}" for file in os.listdir(f"{work}/out")]
        checked = subprocess.run(
            ["xcrun", "swiftc", "-typecheck", "-swift-version", "6", "-warnings-as-errors",
             "-target", TARGET, "-I", MODULES, "-module-name", "Probe"] + files,
            capture_output=True, text=True)
        if checked.returncode == 0:
            return position, name, "compiled", ""
        errors = [line for line in checked.stderr.splitlines()
                  if "error: " in line and not line.lstrip().startswith("|")]
        return position, name, "defect", errors[0] if errors else checked.stderr[:200]


def main():
    if not os.path.isdir(MODULES):
        sys.exit(f"hostile-name-sweep: no modules at {MODULES}; run a debug `swift build` first")
    compiler = batonc()
    positions = sys.argv[1:] or list(POSITIONS)
    unknown = [position for position in positions if position not in POSITIONS]
    if unknown:
        sys.exit(f"hostile-name-sweep: no position named {', '.join(unknown)}; the positions are {', '.join(POSITIONS)}")
    jobs = [(compiler, position, name) for position in positions for name in hostile_names()]
    with ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
        results = list(pool.map(check, jobs))
    defects = 0
    for position in positions:
        rows = [row for row in results if row[0] == position]
        counts = {outcome: sum(1 for row in rows if row[2] == outcome)
                  for outcome in ("compiled", "refused", "defect")}
        print(f"{position}: {counts['compiled']} compiled, {counts['refused']} refused, "
              f"{counts['defect']} defects")
        for _, name, outcome, detail in rows:
            if outcome == "defect":
                defects += 1
                print(f"    {name}: {detail}")
    sys.exit(1 if defects else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compiles with kotlinc, against the Kotlin runtime, the hostile names the
Kotlin corpus tests prove accepted but never compile: the name of a
fragment, a query, a mutation, a subscription and a refetch query, and of a
fragment a query or a mutation spreads; each name as a fragment spread
plainly, with arguments, under `@defer` and under `@catch`; and each name as
an `@inline` fragment, as one a value spreads, as one a query spreads
plainly, with arguments, under a condition with an alias, under `@defer`
and caught under an alias, and as one a value spreads in each of those
forms but `@defer`. Each is a class of the package, and the corpus's
package holds a class of a name once, so the corpus cannot hold them in
every position. A name batonc refuses is refused; a name it accepts whose
Kotlin does not compile is a defect.

Each probe is generated alone, `batonc generate --language kotlin`, into a
package of its own; the probes of one position are compiled together, in
one kotlinc run, as a compromise between one run per probe, which takes
hours, and one run for every position, whose failures are harder to read.

From the repository's root, after `scripts/build-compiler.sh`:

    python3 scripts/hostile-name-sweep-kotlin.py [--refused] [position...]

`--refused` prints each refused name with batonc's error besides.

It needs kotlinc (`brew install kotlin`), or the command `KOTLINC` names,
such as the shim `gradle writeKotlincShim` writes to `kotlin/build/kotlinc`
over the embedded compiler of the modules' Kotlin version,
and the classpath the goldens compile against, which it asks Gradle for
(`:goldens:printCompileClasspath`, with a JDK 21 and Gradle 9 as
`scripts/check-kotlin-goldens.sh` finds them) unless
`BATON_KOTLIN_CLASSPATH` gives it. Without kotlinc it says so and exits 0.
Run it after touching how the Kotlin emitter spells a class, a fragment or
an operation, and when the Kotlin floor moves.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = f"{ROOT}/compiler/src/tests/hosts/HostileKotlinDocuments.kt"
CONFIG = f"{ROOT}/spec/tests/baton.json"
JDK = "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"

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
    "value-inner-spread-forms": """fragment HOSTILE on Character @inline @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) { name @include(if: $flag) }
fragment Probe_character on Character @inline @throwOnFieldError @argumentDefinitions(withName: {type: "Boolean!", defaultValue: true}) {
  id
  ...HOSTILE @arguments(flag: false) @alias(as: "boundValue")
  ...HOSTILE @include(if: $withName) @alias(as: "conditionalValue")
  ... @alias(as: "caughtValue") @catch { ...HOSTILE }
}
query Probe { character(id: 1) { ...Probe_character } }""",
}

# The defects `defects()` in `compiler/src/tests/kotlin_hostile_tests.rs`
# records, by position: reported, and not counted until they are fixed.
KNOWN_DEFECTS = {}

# The names the corpus's aliased scalar fields cannot hold, which the
# position refuses: what every lens has, and what its code spells.
REFUSED_FIELDS = ["anchor", "recordID", "equals", "hashCode", "toString", "Companion",
                  "Variable", "Variables", "Slots"]


def batonc():
    """The compiler the build scripts made: the release binary, else a debug one."""
    for profile in ("release", "debug"):
        path = f"{ROOT}/compiler/target/{profile}/batonc"
        if os.path.exists(path):
            return path
    sys.exit("hostile-name-sweep-kotlin: no batonc; run scripts/build-compiler.sh first")


def kotlinc():
    """The Kotlin compiler: `KOTLINC`, else `kotlinc` on the path."""
    named = os.environ.get("KOTLINC")
    if named:
        return named
    return shutil.which("kotlinc")


def classpath():
    """What the goldens compile against: the runtime and its dependencies."""
    given = os.environ.get("BATON_KOTLIN_CLASSPATH")
    if given:
        return given
    environment = dict(os.environ)
    if "JAVA_HOME" not in environment and os.path.isdir(JDK):
        environment["JAVA_HOME"] = JDK
    gradle = os.environ.get("GRADLE") or (
        "/opt/homebrew/opt/gradle/bin/gradle" if os.path.exists("/opt/homebrew/opt/gradle/bin/gradle") else "gradle")
    printed = subprocess.run([gradle, "--no-daemon", "-q", ":goldens:printCompileClasspath"],
                             cwd=f"{ROOT}/kotlin", capture_output=True, text=True, env=environment)
    if printed.returncode != 0:
        sys.exit(f"hostile-name-sweep-kotlin: Gradle could not print the classpath:\n{printed.stderr}")
    return printed.stdout.strip().splitlines()[-1]


def hostile_names():
    """Every name the corpus's aliased scalar fields hold, and the ones that
    position refuses besides: close to the tests' own list."""
    corpus = open(CORPUS).read()
    start = corpus.index("fragment KotlinScalars_character")
    section = corpus[start:corpus.index('"""', start)]
    names = re.findall(r"(\w+): name\b", section)
    return names + REFUSED_FIELDS


def config(work, package):
    """The tests' configuration with its schema found from `work`, writing
    into `package`."""
    base = json.load(open(CONFIG))
    directory = os.path.dirname(CONFIG)
    base["schema"] = os.path.join(directory, base["schema"])
    base["schemaExtensions"] = [os.path.join(directory, entry) for entry in base.get("schemaExtensions", [])]
    base["kotlin"] = {"package": package}
    path = f"{work}/baton.json"
    json.dump(base, open(path, "w"))
    return path


def generate(job):
    """Generates one probe into its own directory and package: the files,
    or batonc's first error."""
    compiler, work, position, index, name = job
    directory = f"{work}/{position}/{index}"
    os.makedirs(directory)
    document = f"{directory}/Probe.graphql"
    open(document, "w").write(POSITIONS[position].replace("HOSTILE", name) + "\n")
    generated = subprocess.run(
        [compiler, "generate", "--language", "kotlin", "--config",
         config(directory, f"probe.{position.replace('-', '_')}.p{index}"),
         "--out", f"{directory}/out", document],
        capture_output=True, text=True)
    if generated.returncode != 0:
        return position, index, name, None, generated.stderr.strip().splitlines()[0]
    files = [f"{directory}/out/{file}" for file in sorted(os.listdir(f"{directory}/out"))]
    return position, index, name, files, ""


def compile_position(job):
    """Compiles every accepted probe of one position in one kotlinc run, and
    returns the first error of each probe that does not compile."""
    compiler, path, work, position, probes = job
    files = [file for _, _, files in probes for file in files]
    if not files:
        return position, {}
    checked = subprocess.run([compiler, "-cp", path, "-d", f"{work}/{position}-classes", "-nowarn"] + files,
                             capture_output=True, text=True)
    failures = {}
    if checked.returncode == 0:
        return position, failures
    owner = {}
    for index, name, probe_files in probes:
        for file in probe_files:
            owner[os.path.realpath(file)] = name
    for line in checked.stderr.splitlines():
        match = re.match(r"(?:file://)?(/[^:]+\.kt):\d+:\d+: error: (.*)", line)
        if not match:
            continue
        name = owner.get(os.path.realpath(match[1]))
        if name is not None and name not in failures:
            failures[name] = match[2]
    if not failures:
        failures["(the whole position)"] = checked.stderr.strip()[:400]
    return position, failures


def main():
    compiler = kotlinc()
    if compiler is None:
        print("hostile-name-sweep-kotlin: no kotlinc on the path and no KOTLINC; install it "
              "(`brew install kotlin`) to compile the probes. Nothing was swept.")
        sys.exit(0)
    arguments = sys.argv[1:]
    show_refused = "--refused" in arguments
    positions = [argument for argument in arguments if argument != "--refused"] or list(POSITIONS)
    unknown = [position for position in positions if position not in POSITIONS]
    if unknown:
        sys.exit(f"hostile-name-sweep-kotlin: no position named {', '.join(unknown)}; "
                 f"the positions are {', '.join(POSITIONS)}")
    path = classpath()
    generator = batonc()
    names = hostile_names()
    with tempfile.TemporaryDirectory() as work:
        jobs = [(generator, work, position, index, name)
                for position in positions for index, name in enumerate(names)]
        with ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
            generated = list(pool.map(generate, jobs))
        compile_jobs = []
        for position in positions:
            probes = [(index, name, files) for row_position, index, name, files, _ in generated
                      if row_position == position and files is not None]
            compile_jobs.append((compiler, path, work, position, probes))
        # Each kotlinc run takes several cores of its own.
        with ThreadPoolExecutor(max_workers=max(1, (os.cpu_count() or 4) // 4)) as pool:
            compiled = dict(pool.map(compile_position, compile_jobs))
    defects = 0
    for position in positions:
        rows = [row for row in generated if row[0] == position]
        refused = [row for row in rows if row[3] is None]
        failures = compiled[position]
        expected = KNOWN_DEFECTS.get(position, [])
        known = [name for name in failures if name in expected]
        accepted = len(rows) - len(refused)
        print(f"{position}: {accepted - len(failures)} compiled, {len(refused)} refused, "
              f"{len(failures) - len(known)} defects, {len(known)} known")
        if show_refused:
            for _, _, name, _, error in refused:
                print(f"    refused {name}: {error}")
        for name, detail in failures.items():
            if name in known:
                print(f"    known {name}: {detail}")
                continue
            defects += 1
            print(f"    {name}: {detail}")
        for name in expected:
            if name not in failures:
                defects += 1
                print(f"    {name} compiles now: move it from the known defects to the corpus tests")
    sys.exit(1 if defects else 0)


if __name__ == "__main__":
    main()

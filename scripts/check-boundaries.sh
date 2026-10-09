#!/bin/sh
# The boundaries inside the runtime module, checked as a ratchet. The rules
# are the module decision's (docs/decisions/one-runtime-module.md):
#
#   1. One file imports SwiftUI: SwiftUI.swift.
#   2. Only the disk's file imports SQLite3: Disk.swift.
#   3. The record, the plan and the ingest do not name the store.
#   4. The store's files name neither the environment nor a transport.
#   5. The runtime imports only Foundation, Observation, Synchronization and,
#      in the two files above, SQLite3 and SwiftUI.
#
# The Kotlin runtime's, by the same decision and the common-first one
# (docs/decisions/the-kotlin-runtime-is-common-first.md):
#
#   6. The common source set imports no platform: nothing from java, javax
#      or android; the platform's pieces are the actuals of jvmMain,
#      jvmSharedMain and androidMain.
#   7. The testing module reaches the runtime's public surface alone: no
#      friend paths, no visibility suppressions.
#   8. Every name generated Kotlin may spell, RUNTIME_NAMES in the
#      compiler's kotlin_names.rs, is declared in the common source set.
#
# And both runtimes hold the files docs/runtimes.md maps, and nothing the
# map does not name.
#
# Comments may name anything; only code counts. The violations listed below
# are tolerated today, each with the step of the plan that removes it. The
# script fails on a violation that is not listed and on a listed one that
# is gone, so the list can only shrink.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/swift/Sources/Baton"

# Rules 3 and 4, as "<file> names <word>", one a line, with the step that
# removes each after a colon.
listed='
'

failures=0
fail() {
  echo "check-boundaries: $1" >&2
  failures=$((failures + 1))
}

# The code lines of a file: whole-line comments left out.
code() {
  grep -v '^[[:space:]]*//' "$1"
}

# Rules 1, 2 and 5: every import of every file.
for file in *.swift; do
  for module in $(grep '^import ' "$file" | awk '{ print $2 }'); do
    case "$module" in
      Foundation | Observation | Synchronization) ;;
      SwiftUI) [ "$file" = SwiftUI.swift ] || fail "$file imports SwiftUI; only SwiftUI.swift may" ;;
      SQLite3) [ "$file" = Disk.swift ] || fail "$file imports SQLite3; only Disk.swift may" ;;
      *) fail "$file imports $module, which the runtime does not depend on" ;;
    esac
  done
done

# Rules 3 and 4: the names the files must not spell.
found=""
note() {
  found="$found
$1 names $2"
}
for file in Record.swift Plan.swift Resolution.swift Ingest.swift; do
  code "$file" | grep -qw Store && note "$file" Store
done
for file in Store.swift Availability.swift Hydration.swift Connections.swift Roots.swift Keys.swift; do
  code "$file" | grep -qw Environment && note "$file" Environment
  code "$file" | grep -q Transport && note "$file" Transport
done

# A found violation must be listed; a listed one must still be found. The
# loops run in a subshell, so their findings come back as text.
problems="$(
  echo "$found" | while IFS= read -r violation; do
    [ -n "$violation" ] || continue
    echo "$listed" | grep -q "^$violation:" || echo "$violation; not among the violations the ratchet lists"
  done
  echo "$listed" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    violation="${line%%:*}"
    echo "$found" | grep -qx "$violation" || echo "$violation is listed and gone; remove it from the list"
  done
)"
if [ -n "$problems" ]; then
  echo "$problems" | while IFS= read -r message; do echo "check-boundaries: $message" >&2; done
  failures=$((failures + 1))
fi

# Rule 6: the common source set's imports.
kotlin="$root/kotlin/baton/src"
for file in "$kotlin"/commonMain/kotlin/baton/*.kt; do
  name="$(basename "$file")"
  grep -E '^import (java|javax|android)\.' "$file" | while IFS= read -r line; do
    fail "commonMain/$name has \`$line\`; the platform's pieces are actuals of a platform source set"
  done
done

# Rule 7: the testing module's reach.
if grep -rqE 'friendPaths|INVISIBLE_MEMBER|INVISIBLE_REFERENCE' "$root/kotlin/baton-testing" --include='*.kt' --include='*.kts'; then
  fail "kotlin/baton-testing reaches past the runtime's public surface"
fi

# Rule 8: the names the generated Kotlin may spell.
for name in $(awk '/pub const RUNTIME_NAMES/,/^\];/' "$root/compiler/src/kotlin_names.rs" | grep -o '"[A-Za-z]*"' | tr -d '"'); do
  grep -rqE "(class|interface|object|typealias) $name\b" "$kotlin"/commonMain/kotlin/baton \
    || fail "the compiler's RUNTIME_NAMES has $name, which the Kotlin runtime does not declare"
done

# The map: every file it names exists, and every source file is on it.
map="$root/docs/runtimes.md"
for file in $(grep -o '`[A-Za-z]*\.swift`' "$map" | tr -d '`' | sort -u); do
  [ -f "$root/swift/Sources/Baton/$file" ] || fail "docs/runtimes.md names $file, which swift/Sources/Baton lacks"
done
for file in "$root"/swift/Sources/Baton/*.swift; do
  name="$(basename "$file")"
  grep -q "\`$name\`" "$map" || fail "swift/Sources/Baton/$name is not on docs/runtimes.md"
done
for file in $(grep -o '`[A-Za-z/.]*\.kt`' "$map" | tr -d '`' | sort -u); do
  case "$file" in
    */*) path="$kotlin/${file%%/*}/kotlin/baton/${file#*/}" ;;
    *) path="$kotlin/commonMain/kotlin/baton/$file" ;;
  esac
  [ -f "$path" ] || fail "docs/runtimes.md names $file, which the Kotlin runtime lacks"
done
for set in commonMain jvmSharedMain jvmMain androidMain; do
  for file in "$kotlin/$set"/kotlin/baton/*.kt; do
    name="$(basename "$file")"
    case "$set" in
      commonMain) listed="$name" ;;
      *) listed="$set/$name" ;;
    esac
    grep -q "\`$listed\`" "$map" || fail "kotlin/baton/src/$set/kotlin/baton/$name is not on docs/runtimes.md"
  done
done

[ "$failures" -eq 0 ] || exit 1
echo "check-boundaries: the runtimes' boundaries hold"

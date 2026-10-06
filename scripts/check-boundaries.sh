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
for file in Record.swift Plan.swift Ingest.swift; do
  code "$file" | grep -qw Store && note "$file" Store
done
for file in Store.swift Hydration.swift Connections.swift Roots.swift; do
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

[ "$failures" -eq 0 ] || exit 1
echo "check-boundaries: the runtime's boundaries hold"

#!/bin/sh
# Profiles one row of the bench suite with Apple's Time Profiler and prints
# the heaviest symbols on the main thread, by self time and by inclusive
# time.
#
#   scripts/profile-bench.sh "<row label, or part of it>" [seconds] [--only <sections>] [--scope <symbol>] [--top <n>]
#
# The suite's `--profile` mode runs the sections up to the row, prints the
# executable's load address, waits for the profiler, loops the row for the
# seconds given (five by default) and exits. This script starts that run,
# attaches xctrace once the address is printed, exports the samples and
# hands them to profile-summary.py with the address, which symbolicates
# the executable's frames through atos. `--scope` keeps only the samples
# whose stack holds a symbol containing the text, as `Store.commit` or
# `Ingest.normalize`, so the row's own setup does not count. The trace, the
# export and the summary land under $BATON_PROFILE_DIR, /tmp/baton-profile
# by default, named after the row.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
row="${1:?usage: scripts/profile-bench.sh \"<row label>\" [seconds] [--only <sections>] [--scope <symbol>] [--top <n>]}"
shift
seconds=5
case "${1:-}" in
  ''|-*) ;;
  *) seconds="$1"; shift ;;
esac
# The sections to run on the way to the row, handed to the suite; the
# rest of the options go to the summary.
only=""
if [ "${1:-}" = "--only" ]; then
  only="$2"
  shift 2
fi
out="${BATON_PROFILE_DIR:-/tmp/baton-profile}"
mkdir -p "$out"
slug="$(printf '%s' "$row" | tr -c 'A-Za-z0-9' '-' | cut -c1-60)"
binary=".build/release/BatonBenchmarks"

BATON_COMPILER=local swift build -c release --product BatonBenchmarks
# The symbols, beside the binary, where atos looks for them.
dsymutil "$binary" -o "$binary.dSYM"

rm -f "$out/$slug.out"
"$binary" --profile "$row" --profile-seconds "$((seconds + 2))" ${only:+--only "$only"} > "$out/$slug.out" 2>&1 &
pid=$!
# The sections before the row run first; the address is printed when the
# row starts, a second and a half before its loop.
waited=0
until grep -q '^load-address' "$out/$slug.out" 2>/dev/null; do
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$out/$slug.out"
    echo "profile-bench: the run ended before it reached a row named like \"$row\"" >&2
    exit 1
  fi
  sleep 0.2
  waited=$((waited + 1))
  if [ "$waited" -gt 1500 ]; then
    kill "$pid" 2>/dev/null || true
    echo "profile-bench: the run did not reach the row in five minutes" >&2
    exit 1
  fi
done
rm -rf "$out/$slug.trace"
xcrun xctrace record --template 'Time Profiler' --attach "$pid" --time-limit "${seconds}s" --output "$out/$slug.trace" > "$out/$slug.record.log" 2>&1
wait "$pid" || true
grep -E '^(profiling|profiled)' "$out/$slug.out"
load="$(awk '/^load-address/ { print $2 }' "$out/$slug.out")"
xcrun xctrace export --input "$out/$slug.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$out/$slug.xml"
python3 "$root/scripts/profile-summary.py" "$out/$slug.xml" "$binary" "$load" "$@" | tee "$out/$slug.summary.txt"
echo "the trace is $out/$slug.trace"

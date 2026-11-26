#!/bin/sh
# Builds two modules of one app, the second spreading a fragment the first
# declares, over the compiler and the runtimes of this checkout, in Swift
# (swift/Fixtures/Bases) and in Kotlin (kotlin/fixtures/bases). The base's
# generation writes its fragments file and the dependent's names it with
# --base; both modules and a test that reads one response through the two
# lenses build with warnings as errors and pass. In Swift an app's file that
# builds the base's lens without the generated SPI fails to type-check.
# `check-bases.sh swift` or `check-bases.sh kotlin` runs one half. Needs a
# built compiler, the one BATON_COMPILER names or
# compiler/target/release/batonc; the Kotlin half needs a JDK 21 and
# Gradle 9, which JAVA_HOME and GRADLE override.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
compiler="${BATON_COMPILER:-$root/compiler/target/release/batonc}"
if [ ! -x "$compiler" ]; then
  echo "no compiler at $compiler; run cargo build --release in compiler/, or name one in BATON_COMPILER" >&2
  exit 1
fi
halves="${1:-swift kotlin}"

swift_half() {
  cd "$root/swift/Fixtures/Bases"
  # The generated sources are build products; the fragments file lives
  # outside the targets so that SwiftPM does not take it for a resource.
  rm -rf Sources/Shared/Generated Sources/Screens/Generated .build/baton
  mkdir -p Sources/Shared/Generated Sources/Screens/Generated .build/baton
  "$compiler" generate --config baton.json --module Shared \
    --out Sources/Shared/Generated --fragments .build/baton/Shared.fragments.json \
    Sources/Shared/CharacterStatus.swift
  "$compiler" generate --config baton.json --module Screens \
    --out Sources/Screens/Generated --base .build/baton/Shared.fragments.json \
    Sources/Screens/CharacterRow.swift
  grep -q '^@_spi(Generated) import Shared$' Sources/Screens/Generated/*.baton.swift || {
    echo "the dependent's generated Swift does not import its base" >&2
    exit 1
  }
  # The package's environment variable of the same name chooses the
  # compiler the plugin runs, which this fixture does not use.
  env -u BATON_COMPILER swift build --build-tests -Xswiftc -warnings-as-errors
  env -u BATON_COMPILER swift test --skip-build
  # An app's own file imports the runtime and the base without the SPI: it
  # may not build the base's lens.
  modules="$(env -u BATON_COMPILER swift build --show-bin-path)/Modules"
  log=.build/baton/masked.log
  if swiftc -typecheck -swift-version 6 -I "$modules" Masked/AppBuildsALens.swift 2> "$log"; then
    echo "an app's file built the base's lens without the generated SPI" >&2
    exit 1
  fi
  grep -q "'CharacterStatus_character' initializer is inaccessible due to '@_spi' protection level" "$log" || {
    echo "the app's file failed for another reason than the lens's initializer:" >&2
    cat "$log" >&2
    exit 1
  }
}

kotlin_half() {
  if [ -z "${JAVA_HOME:-}" ]; then
    if [ -d /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ]; then
      JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
    elif [ -x /usr/libexec/java_home ]; then
      JAVA_HOME="$(/usr/libexec/java_home -v 21)"
    fi
  fi
  export JAVA_HOME
  gradle="${GRADLE:-}"
  if [ -z "$gradle" ]; then
    if [ -x /opt/homebrew/opt/gradle/bin/gradle ]; then
      gradle=/opt/homebrew/opt/gradle/bin/gradle
    else
      gradle=gradle
    fi
  fi
  cd "$root/kotlin/fixtures/bases"
  # Each module has its own package, which its `baton.json` names for its
  # shared file and its host declares for its lenses.
  rm -rf shared/build/baton screens/build/baton build/baton
  mkdir -p shared/build/baton screens/build/baton build/baton
  "$compiler" generate --language kotlin --config shared/baton.json \
    --out shared/build/baton --fragments build/baton/shared.fragments.json \
    shared/src/jvmMain/kotlin/fixture/shared/CharacterStatus.kt
  "$compiler" generate --language kotlin --config screens/baton.json \
    --out screens/build/baton --base build/baton/shared.fragments.json \
    screens/src/jvmMain/kotlin/fixture/screens/CharacterRow.kt
  grep -q '^import fixture.shared.CharacterStatus_character$' screens/build/baton/*CharacterRow.baton.kt || {
    echo "the dependent's generated Kotlin does not import its base's lens" >&2
    exit 1
  }
  "$gradle" --no-daemon -q :screens:jvmTest --rerun
}

for half in $halves; do
  case "$half" in
    swift) (swift_half) ;;
    kotlin) (kotlin_half) ;;
    *) echo "usage: check-bases.sh [swift|kotlin]" >&2; exit 2 ;;
  esac
done
case "$halves" in
  *swift*) masked=", and an app's Swift file cannot build that lens" ;;
  *) masked="" ;;
esac
echo "a module spreads its base's fragment and reads it through the base's lens, in $(echo $halves | sed 's/ / and /')$masked"

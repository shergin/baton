#!/bin/sh
# Compiles the Kotlin emitter's goldens, compiler/src/tests/goldens-kotlin,
# against the Kotlin runtime: a golden that does not compile is a fault of
# the emitter. Needs a JDK 21 and Gradle 9; JAVA_HOME and GRADLE override
# where they are found.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
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
cd "$root/kotlin"
"$gradle" --no-daemon -q :goldens:compileKotlinJvm

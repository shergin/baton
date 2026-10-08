# baton-gradle

The Gradle plugin `com.shergin.baton`: `batonc generate` as a task with
every input and output declared, and the compiler fetched from the
release's artifact bundle, versioned with Baton. The repository's own
Kotlin modules apply it as an included build; `gradle :baton-gradle:build`
from `kotlin/` builds and tests it.

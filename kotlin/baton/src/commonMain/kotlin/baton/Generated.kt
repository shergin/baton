package baton

/**
 * Marks what the runtime exposes to generated code alone, as Swift's
 * `@_spi(Generated)` does: an adopter who opts in is on their own.
 */
@RequiresOptIn(
    message = "This is the runtime's contract with generated code, not an API for an application.",
    level = RequiresOptIn.Level.ERROR,
)
@kotlin.annotation.Retention(AnnotationRetention.BINARY)
@Target(
    AnnotationTarget.CLASS,
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY,
    AnnotationTarget.CONSTRUCTOR,
    AnnotationTarget.TYPEALIAS,
)
annotation class Generated

/**
 * The format of generated code this runtime reads. Generated code names the
 * marker; a runtime of another format fails to compile it. The Kotlin
 * format has its own numbers, per the decision that a format is per emitter.
 */
@Generated
object Format2

/** The marker before: generated code that names it is of an earlier compiler, and does not compile. */
@Deprecated("this generated code is of format 1 and the runtime reads format 2; rebuild with the compiler of this release", level = DeprecationLevel.ERROR)
@Generated
object Format1

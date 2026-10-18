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
object Format4

/** The markers before: generated code that names one is of an earlier compiler, and does not compile. */
@Deprecated("this generated code is of format 3 and the runtime reads format 4: a mutation's deletions; rebuild with the compiler of this release", level = DeprecationLevel.ERROR)
@Generated
object Format3

@Deprecated("this generated code is of format 2 and the runtime reads format 3: a streamed list and the operation's `hasIncremental`; rebuild with the compiler of this release", level = DeprecationLevel.ERROR)
@Generated
object Format2

@Deprecated("this generated code is of format 1 and the runtime reads format 3; rebuild with the compiler of this release", level = DeprecationLevel.ERROR)
@Generated
object Format1

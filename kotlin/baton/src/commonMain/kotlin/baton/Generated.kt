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
object Format1

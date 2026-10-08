package baton

/**
 * The host of a fragment: the composable, or the class, that renders it.
 * The document is the text the compiler reads; a document with a variable
 * is written in a multi-dollar raw string, `$$"""…"""`, since `$` is a
 * template in a plain one. Nothing of the annotation reaches a class file.
 * Every marker repeats: a host may carry several documents, as a button that
 * stars and unstars carries two mutations.
 */
@kotlin.annotation.Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.FUNCTION, AnnotationTarget.CLASS)
@Repeatable
annotation class Fragment(val document: String)

/** The host of a query: the composable, or the class, that holds its handle. */
@kotlin.annotation.Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.FUNCTION, AnnotationTarget.CLASS)
@Repeatable
annotation class Query(val document: String)

/** The host of a mutation: the composable, or the class, that holds its action. */
@kotlin.annotation.Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.FUNCTION, AnnotationTarget.CLASS)
@Repeatable
annotation class Mutation(val document: String)

/** The host of a subscription: the composable, or the class, that holds its handle. */
@kotlin.annotation.Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.FUNCTION, AnnotationTarget.CLASS)
@Repeatable
annotation class Subscription(val document: String)

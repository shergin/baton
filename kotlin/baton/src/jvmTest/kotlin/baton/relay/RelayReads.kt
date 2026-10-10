package baton.relay

import baton.FieldErrors
import baton.Lens
import baton.MappedScalar
import baton.RequiredFieldError
import baton.Walker

// What a lens reads at a row of a Relay script, lifted into the manifest's
// spelling: the Kotlin twin of `swift/Tests/BatonRelayTests/RelayValues.swift`
// and of the reads `RelayReads.swift` generates there, found here by walking
// the generated lens by its property names.

/** What a read gave: a value in the manifest's spelling, as JSON read by `Json`, or the kind of error it threw. */
internal sealed interface RelayRead {
    data class Value(val json: Any?) : RelayRead {
        override fun toString(): String = render(json)
    }

    data class Threw(val kind: String) : RelayRead {
        override fun toString(): String = "a thrown $kind"
    }

    /** Whether two reads are the same: two values the same JSON, two throws of one kind. */
    fun isSame(other: RelayRead): Boolean = when {
        this is Value && other is Value -> isSameJson(json, other.json)
        this is Threw && other is Threw -> kind == other.kind
        else -> false
    }
}

/**
 * The read at [path] over [data]: each response key through the property
 * of its name, an index into a list, absent past its end. A `Result` met in
 * the middle of the path is unwrapped, a failed one reading the rest as
 * absent, and an absent value reads the rest as absent. A getter that
 * throws `RequiredFieldError` or `FieldErrors` anywhere on the path is the
 * read's throw. Null when the lens reads no property of a key.
 */
internal fun relayRead(data: Lens, path: String): RelayRead? {
    var current: Any? = data
    val segments = path.split('.')
    for ((index, segment) in segments.withIndex()) {
        current = when (current) {
            null -> return RelayRead.Value(null)
            is List<*> -> current.getOrNull(segment.toIntOrNull() ?: return null)
            else -> {
                val found = try {
                    Walker.field(current, segment, strict = true)
                } catch (_: RequiredFieldError) {
                    return RelayRead.Threw("requiredField")
                } catch (_: FieldErrors) {
                    return RelayRead.Threw("fieldErrors")
                }
                (found ?: return null).value
            }
        }
        if (index < segments.lastIndex && current is Result<*>) current = current.getOrNull()
    }
    return RelayRead.Value(lift(current))
}

/**
 * A value a lens reads in the manifest's spelling: a scalar as itself, a
 * generated enum or a mapped scalar as its text, a lens as an empty object,
 * a `@catch` result as `{"ok": true}` with the value of a scalar, or as
 * `{"ok": false, "errors": [path, ...]}` with its errors' paths sorted.
 */
internal fun lift(value: Any?): Any? = when (value) {
    null -> null
    is String, is Boolean -> value
    is Int -> value.toLong()
    is Long -> value
    is Short -> value.toLong()
    is Double -> value
    is Float -> value.toDouble()
    is MappedScalar -> value.scalarText
    is Lens -> emptyMap<String, Any?>()
    is List<*> -> value.map { lift(it) }
    is Result<*> -> {
        val failure = value.exceptionOrNull()
        when {
            failure == null -> {
                val success = value.getOrNull()
                if (success is Lens) mapOf("ok" to true) else mapOf("ok" to true, "value" to lift(success))
            }
            failure is FieldErrors -> mapOf("ok" to false, "errors" to failure.errors.map { it.path }.sorted())
            else -> mapOf("ok" to false, "thrown" to failure.toString())
        }
    }
    else -> value.toString()
}

/** Whether two JSON values are the same: a number is one number however it is spelled, and an object's members compare by name. */
internal fun isSameJson(value: Any?, other: Any?): Boolean = when {
    value is Number && other is Number ->
        if (value is Double || other is Double) value.toDouble() == other.toDouble() else value.toLong() == other.toLong()
    value is List<*> && other is List<*> -> value.size == other.size && value.indices.all { isSameJson(value[it], other[it]) }
    value is Map<*, *> && other is Map<*, *> ->
        value.size == other.size && value.all { (key, item) -> other.containsKey(key) && isSameJson(item, other[key]) }
    else -> value == other
}

/** A JSON value as text, for the messages. */
internal fun render(value: Any?): String = when (value) {
    null -> "null"
    is String -> "\"$value\""
    is List<*> -> value.joinToString(", ", "[", "]") { render(it) }
    is Map<*, *> -> value.entries.joinToString(", ", "{", "}") { "\"${it.key}\": ${render(it.value)}" }
    else -> value.toString()
}

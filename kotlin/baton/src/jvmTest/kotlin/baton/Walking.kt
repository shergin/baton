package baton

import baton.spec.DateTimes
import baton.spec.Decimals
import baton.spec.Urls
import java.lang.reflect.InvocationTargetException
import java.math.BigDecimal
import java.net.URI
import java.time.Instant
import kotlin.reflect.KClass
import kotlin.reflect.KProperty1
import kotlin.reflect.KVisibility
import kotlin.reflect.full.memberProperties
import kotlin.test.fail

/**
 * The value at a row's path over a lens: a response key through the
 * property of its name, an index into a list, absent past its end. A
 * `Result` reads as its value or as absent, and a getter that throws a
 * field's error reads as absent, as a fragment that throws does. The cases'
 * reads and the scripts' share it.
 */
internal fun walk(data: Lens, path: String): Any? {
    var current: Any? = data
    for (segment in path.split('.')) {
        current = when (current) {
            null -> return null
            is List<*> -> current.getOrNull(segment.toInt())
            else -> (Walker.field(current, segment) ?: fail("$path: ${current::class.simpleName} reads no field $segment")).value
        }
    }
    return current
}

/**
 * A row's path over generated code: a response key is the Kotlin name of
 * the property that reads it, backticks and JVM names aside. A key the lens
 * does not read itself is read through what reads the same record: a
 * fragment's spread, an inline fragment's lens, an `@inline` fragment's
 * value. The generated code is the package of the lens being walked,
 * `baton.spec` for the main manifest and `baton.relay` for Relay's.
 */
internal object Walker {
    /** What a property read: its value, null where it read as absent. */
    class Found(val value: Any?)

    /**
     * The property of [owner] that reads [key], or the one of a lens over
     * the same record that does. Read leniently, a `Result` is its value and
     * a getter that throws a field's error is absent; read [strict], the
     * property that reads [key] gives its `Result` as it is and throws what
     * its getter throws, while the lenses searched on the way are still read
     * leniently.
     */
    fun field(owner: Any, key: String, strict: Boolean = false): Found? {
        val generated = owner::class.java.packageName
        val properties = properties(owner::class)
        properties[key]?.let { return Found(if (strict) readStrictly(it, owner) else read(it, owner)) }
        var absent: Found? = null
        for (property in properties.values) {
            val inner = read(property, owner)
            if (inner == null) {
                // A fragment that reads as absent, or throws, holds its
                // fields absent: its class says which they are.
                val fragment = fragmentClass(property, generated)
                if (fragment != null && declares(fragment, key, generated)) absent = Found(null)
                continue
            }
            if (!reachesTheSameRecord(owner, inner, generated)) continue
            val found = field(inner, key, strict) ?: continue
            if (found.value != null) return found
            absent = found
        }
        return absent
    }

    /** The public properties of [type] by name, but the anchor and the record's identity every lens has. */
    private fun properties(type: KClass<*>): Map<String, KProperty1<Any, *>> {
        @Suppress("UNCHECKED_CAST")
        return (type.memberProperties as Collection<KProperty1<Any, *>>)
            .filter { it.visibility == KVisibility.PUBLIC && it.name != "anchor" && it.name != "recordID" }
            .associateBy { it.name }
    }

    /** The fragment's class a property reads, a `Result` of one among them, or null for anything else. */
    private fun fragmentClass(property: KProperty1<Any, *>, generated: String): KClass<*>? {
        var type = property.returnType
        if (type.classifier == Result::class) type = type.arguments.first().type ?: return null
        val classifier = type.classifier as? KClass<*> ?: return null
        return classifier.takeIf { isFragment(it.java, generated) }
    }

    /** Whether [type], a fragment's class, reads [key] itself or through a fragment it spreads. */
    private fun declares(type: KClass<*>, key: String, generated: String): Boolean {
        val properties = properties(type)
        if (key in properties) return true
        return properties.values.any { property -> fragmentClass(property, generated)?.let { declares(it, key, generated) } ?: false }
    }

    /** Whether [type] is a fragment's lens or value: a class at the top of the package [generated]. */
    private fun isFragment(type: Class<*>, generated: String): Boolean = type.packageName == generated && type.enclosingClass == null

    /** A property's value as its getter gives it: a `Result` kept, a thrown error thrown again as itself. */
    private fun readStrictly(property: KProperty1<Any, *>, owner: Any): Any? = try {
        property.get(owner)
    } catch (error: InvocationTargetException) {
        throw error.cause ?: error
    }

    /** A property's value: a `Result` unwrapped, a failure or a thrown field error as absent. */
    private fun read(property: KProperty1<Any, *>, owner: Any): Any? {
        val value = try {
            property.get(owner)
        } catch (error: InvocationTargetException) {
            if (error.cause is FieldErrors || error.cause is RequiredFieldError) return null
            throw error.cause ?: error
        } catch (_: FieldErrors) {
            return null
        } catch (_: RequiredFieldError) {
            return null
        }
        return if (value is Result<*>) value.getOrNull() else value
    }

    /**
     * Whether [inner] reads the record [owner] reads: a fragment's lens or
     * value, a class of its own at the top of the package, or a nested lens
     * over the same record, an inline fragment's. A nested lens over another
     * record is a link's.
     */
    private fun reachesTheSameRecord(owner: Any, inner: Any, generated: String): Boolean {
        val type = inner::class.java
        if (type.packageName != generated) return false
        if (isFragment(type, generated)) return true
        return inner is Lens && owner is Lens && inner.anchor.record === owner.anchor.record
    }
}

/** Whether a lens's value is a row's: a mapped scalar compared as its type's value, an enum by its text. */
internal fun matches(actual: Any?, expected: Any?): Boolean = when {
    expected == null -> actual == null
    actual == null -> false
    expected is List<*> -> actual is List<*> && actual.size == expected.size && actual.indices.all { matches(actual[it], expected[it]) }
    actual is BigDecimal -> expected is String && Decimals.parse(expected)?.compareTo(actual) == 0
    actual is Instant -> expected is String && DateTimes.parse(expected) == actual
    actual is URI -> expected is String && Urls.parse(expected) == actual
    actual is GeneratedEnum -> expected is String && actual.scalarText == expected
    actual is Int -> expected is Long && expected == actual.toLong()
    actual is Double -> expected is Number && expected.toDouble() == actual
    else -> actual == expected
}

package baton

/**
 * A variable's JSON value, as it is sent and as it renders inside a storage
 * key. The runtime's own value type is the store's; this one is the wire's.
 */
sealed interface Variable {
    data object Null : Variable
    data class Bool(val value: Boolean) : Variable
    data class Int(val value: Long) : Variable
    data class Double(val value: kotlin.Double) : Variable
    data class String(val value: kotlin.String) : Variable
    data class List(val values: kotlin.collections.List<Variable>) : Variable
    data class Object(val fields: Map<kotlin.String, Variable>) : Variable

    /** The value as JSON, object keys sorted, as Relay renders a key's arguments. */
    val json: kotlin.String
        get() = when (this) {
            Null -> "null"
            is Bool -> if (value) "true" else "false"
            is Int -> value.toString()
            is Double -> renderDouble(value)
            is String -> quote(value)
            is List -> values.joinToString(",", "[", "]") { it.json }
            is Object -> fields.entries.sortedBy { it.key }.joinToString(",", "{", "}") { quote(it.key) + ":" + it.value.json }
        }


    companion object {
        fun of(value: Boolean?): Variable = if (value == null) Null else Bool(value)
        fun of(value: kotlin.Int?): Variable = if (value == null) Null else Int(value.toLong())
        fun of(value: Long?): Variable = if (value == null) Null else Int(value)
        fun of(value: kotlin.Double?): Variable = if (value == null) Null else Double(value)
        fun of(value: kotlin.String?): Variable = if (value == null) Null else String(value)
        fun of(value: InputObject?): Variable = value?.variable ?: Null
        fun of(value: MappedScalar?): Variable = if (value == null) Null else String(value.scalarText)
        fun <T : Any> of(value: T?, converter: ScalarConverter<T>): Variable = if (value == null) Null else String(converter.render(value))
        fun of(value: Variable?): Variable = value ?: Null

        /** A JSON string literal: quotes and the escapes JSON requires, nothing else escaped. */
        fun quote(text: kotlin.String): kotlin.String = buildString(text.length + 2) {
            append('"')
            for (character in text) {
                when (character) {
                    '"' -> append("\\\"")
                    '\\' -> append("\\\\")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    '\b' -> append("\\b")
                    '\u000C' -> append("\\f")
                    else -> if (character < ' ') {
                        append("\\u")
                        append(character.code.toString(16).padStart(4, '0'))
                    } else {
                        append(character)
                    }
                }
            }
            append('"')
        }

        /**
         * A double's text as the contract's float rendering rule gives it: the
         * shortest round-tripping decimal, an integral value with `.0`, as
         * Swift's `description` prints and the fixtures hold. See
         * `spec/runtime.md`, section 1.
         */
        internal fun renderDouble(value: kotlin.Double): kotlin.String {
            if (value.isNaN() || value.isInfinite()) return "null"
            return platformShortestDouble(value)
        }
    }
}

/** The text a value takes inside a record key, `Character:1`: a string bare, anything else as JSON. */
internal val Variable.keyText: String
    get() = if (this is Variable.String) value else json

/** The platform's shortest round-tripping rendering of a double, normalized to the contract's spelling. */
internal expect fun platformShortestDouble(value: Double): String

/** The variables an operation is run with: a name to a value, nothing else. */
class Variables(val values: Map<String, Variable>) {
    operator fun get(name: String): Variable? = values[name]

    /** The JSON rendering used inside storage keys: `characters(page:1)`. */
    internal fun render(name: String): String = (values[name] ?: Variable.Null).json

    /** The rendering used inside record keys for lookups: `Character:1`. */
    internal fun keyText(name: String): String = (values[name] ?: Variable.Null).keyText

    /** The `variables` object of a request body. */
    val json: String get() = Variable.Object(values).json

    override fun equals(other: Any?): Boolean = other is Variables && other.values == values
    override fun hashCode(): Int = values.hashCode()
    override fun toString(): String = json

    companion object {
        val none: Variables = Variables(emptyMap())

        /**
         * The variables an operation value declares, from name and value
         * pairs; a pair whose value is null is a variable left unset, absent
         * from the request. A receiver-free builder, so a getter that reads
         * the value's own properties reads nothing else.
         */
        fun of(vararg entries: Pair<String, Variable?>): Variables {
            val values = LinkedHashMap<String, Variable>(entries.size)
            for ((name, value) in entries) if (value != null) values[name] = value
            return Variables(values)
        }
    }
}

/** A schema input object as generated code spells it: a class whose unset fields are left out of its value. */
interface InputObject {
    val variable: Variable
}

/** A value sent and read as a scalar's text: a generated enum, or a type the configuration maps a scalar to. */
interface MappedScalar {
    val scalarText: String
}

/** A generated enum: the schema's values as objects, and an `Undeclared` carrying a value the schema did not declare. */
interface GeneratedEnum : MappedScalar

/**
 * How a mapped scalar's text becomes a value and back, for a type the runtime
 * cannot extend: `customScalarTypes` names the converter under `kotlin`.
 */
interface ScalarConverter<T : Any> {
    /** The value of [text], or null when the text is not one the type holds. */
    fun parse(text: String): T?
    fun render(value: T): String
}

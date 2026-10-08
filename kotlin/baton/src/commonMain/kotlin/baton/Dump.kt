package baton

/**
 * The store as `spec/` freezes it: every record by key, each a JSON object
 * from storage key to value, a link as Relay writes it (`{"__ref": key}`,
 * `{"__refs": [key]}`), the record's type as `__typename`, field errors
 * under `__errors`, a deleted record as `null`. Keys are sorted by code
 * point and each record is one line, so a change to identity or layout is a
 * reviewable diff, and an inspector's export can become a fixture. See
 * `spec/README.md`, the manifest's `records`.
 */
@Generated
fun Store.dump(): String {
    val lines = recordsByKey().entries.sortedWith { left, right -> compareCodePoints(left.key, right.key) }.map { (key, record) ->
        "  " + Dump.quote(key) + ": " + (if (record.deleted) "null" else Dump.record(this, record))
    }
    return "{\n" + lines.joinToString(",\n") + "\n}\n"
}

/**
 * Every value a record holds, by storage key, as the dump writes it, with
 * its error; for an inspector. The values are read through the record's
 * cells, so a read in composition registers them.
 */
@Generated
fun Store.fieldTexts(record: Record): List<Triple<String, String, FieldError?>> =
    storedFields(record).map { (key, value, error) -> Triple(key, Dump.json(value), error) }

private object Dump {
    fun record(store: Store, record: Record): String {
        val fields = ArrayList<Pair<String, String>>()
        fields.add("__typename" to quote(record.type.name))
        val errors = ArrayList<Pair<String, String>>()
        for ((key, value, error) in store.storedFields(record)) {
            fields.add(key to json(value))
            if (error != null) errors.add(key to "{\"message\": " + quote(error.message) + ", \"path\": " + quote(error.path) + "}")
        }
        if (errors.isNotEmpty()) fields.add("__errors" to "{" + entries(errors) + "}")
        return "{" + entries(fields) + "}"
    }

    private fun entries(pairs: List<Pair<String, String>>): String =
        pairs.sortedWith { left, right -> compareCodePoints(left.first, right.first) }.joinToString(", ") { quote(it.first) + ": " + it.second }

    fun json(value: Value): String = when (value) {
        Value.Missing, Value.Null -> "null"
        is Value.Bool -> if (value.value) "true" else "false"
        is Value.Int -> value.value.toString()
        is Value.Double -> Variable.renderDouble(value.value)
        is Value.String -> quote(value.value)
        is Value.Ref -> "{\"__ref\": " + quote(value.record.key) + "}"
        is Value.Refs -> "{\"__refs\": [" + value.records.joinToString(", ") { it?.let { record -> quote(record.key) } ?: "null" } + "]}"
        is Value.List -> "[" + value.values.joinToString(", ") { json(it) } + "]"
    }

    /** A JSON string: quotes, backslashes and the control characters escaped, `\u` with four lowercase digits, nothing else. */
    fun quote(text: String): String = buildString(text.length + 2) {
        append('"')
        for (character in text) {
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
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
}

/** Compares two strings by Unicode code point, as the dumps sort their keys, rather than by UTF-16 unit. */
internal fun compareCodePoints(left: String, right: String): Int {
    val length = minOf(left.length, right.length)
    for (index in 0 until length) {
        val a = left[index]
        val b = right[index]
        if (a == b) continue
        // A surrogate encodes a code point above every other UTF-16 unit.
        val aSurrogate = a.isSurrogate()
        val bSurrogate = b.isSurrogate()
        if (aSurrogate != bSurrogate) return if (aSurrogate) 1 else -1
        return a.compareTo(b)
    }
    return left.length - right.length
}

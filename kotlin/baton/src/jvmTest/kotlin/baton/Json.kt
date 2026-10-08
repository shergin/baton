package baton

/**
 * A small JSON reader for the spec's files, since the runtime takes no
 * serialization library: an object is a map in the file's order, an array a
 * list, a number without a fraction or an exponent a `Long`, any other a
 * `Double`; or, read keeping its numbers, every number its own text.
 */
internal object Json {
    /** A number as the file spells it, so that writing the value back changes no number the ingest reads. */
    data class Number(val text: String)

    fun parse(text: String, keepingNumbers: Boolean = false): Any? {
        val reader = Reader(text, keepingNumbers)
        val value = reader.value()
        reader.whitespace()
        check(reader.position == text.length) { "trailing text at ${reader.position}" }
        return value
    }

    /** A value as JSON text, every character outside ASCII escaped, so a lone surrogate the file escaped is escaped again. */
    fun write(value: Any?): String = StringBuilder().also { write(value, it) }.toString()

    private fun write(value: Any?, output: StringBuilder) {
        when (value) {
            null -> output.append("null")
            is Boolean, is Long -> output.append(value.toString())
            is Double -> output.append(Variable.renderDouble(value))
            is Number -> output.append(value.text)
            is String -> {
                output.append('"')
                for (character in value) {
                    when {
                        character == '"' -> output.append("\\\"")
                        character == '\\' -> output.append("\\\\")
                        character.code < 0x20 || character.code >= 0x7f -> output.append("\\u%04x".format(character.code))
                        else -> output.append(character)
                    }
                }
                output.append('"')
            }
            is List<*> -> {
                output.append('[')
                for ((index, item) in value.withIndex()) {
                    if (index > 0) output.append(',')
                    write(item, output)
                }
                output.append(']')
            }
            is Map<*, *> -> {
                output.append('{')
                for ((index, entry) in value.entries.withIndex()) {
                    if (index > 0) output.append(',')
                    write(entry.key as String, output)
                    output.append(':')
                    write(entry.value, output)
                }
                output.append('}')
            }
            else -> error("not JSON: $value")
        }
    }

    /** A JSON value as the variable an operation is run with. */
    fun variable(value: Any?): Variable = when (value) {
        null -> Variable.Null
        is Boolean -> Variable.Bool(value)
        is Long -> Variable.Int(value)
        is Double -> Variable.Double(value)
        is String -> Variable.String(value)
        is List<*> -> Variable.List(value.map { variable(it) })
        is Map<*, *> -> Variable.Object(value.entries.associate { (key, item) -> key as String to variable(item) })
        else -> error("not JSON: $value")
    }

    private class Reader(private val text: String, private val keepingNumbers: Boolean) {
        var position = 0

        fun whitespace() {
            while (position < text.length && text[position] in " \n\r\t") position += 1
        }

        fun value(): Any? {
            whitespace()
            return when (val character = text[position]) {
                '{' -> objectValue()
                '[' -> arrayValue()
                '"' -> string()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> if (character == '-' || character.isDigit()) number() else error("unexpected '$character' at $position")
            }
        }

        private fun objectValue(): Map<String, Any?> {
            val fields = LinkedHashMap<String, Any?>()
            position += 1
            whitespace()
            if (text[position] == '}') {
                position += 1
                return fields
            }
            while (true) {
                whitespace()
                val key = string()
                whitespace()
                check(text[position] == ':') { "expected ':' at $position" }
                position += 1
                fields[key] = value()
                whitespace()
                when (text[position]) {
                    ',' -> position += 1
                    '}' -> {
                        position += 1
                        return fields
                    }
                    else -> error("expected ',' or '}' at $position")
                }
            }
        }

        private fun arrayValue(): List<Any?> {
            val items = ArrayList<Any?>()
            position += 1
            whitespace()
            if (text[position] == ']') {
                position += 1
                return items
            }
            while (true) {
                items.add(value())
                whitespace()
                when (text[position]) {
                    ',' -> position += 1
                    ']' -> {
                        position += 1
                        return items
                    }
                    else -> error("expected ',' or ']' at $position")
                }
            }
        }

        private fun string(): String {
            check(text[position] == '"') { "expected a string at $position" }
            position += 1
            val output = StringBuilder()
            while (true) {
                val character = text[position]
                position += 1
                when (character) {
                    '"' -> return output.toString()
                    '\\' -> {
                        val escape = text[position]
                        position += 1
                        when (escape) {
                            'b' -> output.append('\b')
                            'f' -> output.append('\u000C')
                            'n' -> output.append('\n')
                            'r' -> output.append('\r')
                            't' -> output.append('\t')
                            'u' -> {
                                output.append(text.substring(position, position + 4).toInt(16).toChar())
                                position += 4
                            }
                            else -> output.append(escape)
                        }
                    }
                    else -> output.append(character)
                }
            }
        }

        private fun number(): Any {
            val start = position
            while (position < text.length && (text[position].isDigit() || text[position] in "+-.eE")) position += 1
            val token = text.substring(start, position)
            if (keepingNumbers) return Number(token)
            if (token.any { it in ".eE" }) return token.toDouble()
            return token.toLong()
        }

        private fun literal(word: String, value: Any?): Any? {
            check(text.startsWith(word, position)) { "expected $word at $position" }
            position += word.length
            return value
        }
    }
}

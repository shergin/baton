package baton

/** Strings out of a response's bytes, the one place the ingest makes them. */
internal object Text {
    private const val REPLACEMENT = 0xFFFD

    /**
     * The string in `bytes[start, end)`: as UTF-8 when nothing is escaped,
     * malformed bytes read as U+FFFD; otherwise with JSON's escapes read. An
     * escape `\u` cut short by the string's end is U+FFFD and its digits are
     * dropped; one without four hex digits is U+FFFD and what follows the `u`
     * is read as the string's own bytes; a high surrogate pairs only with a
     * low one written as the next escape, and an unpaired one is U+FFFD.
     */
    fun materialize(bytes: ByteArray, start: Int, end: Int, escaped: Boolean): String {
        if (!escaped) return bytes.decodeToString(start, end)
        // An escape writes at most one and a half times its bytes: `\u` before a byte that is no digit.
        val output = ByteArray((end - start) * 2 + 8)
        var length = 0
        fun append(byte: Int) {
            output[length] = byte.toByte()
            length += 1
        }
        fun appendScalar(scalar: Int) {
            when {
                scalar < 0x80 -> append(scalar)
                scalar < 0x800 -> {
                    append(0xC0 or (scalar shr 6))
                    append(0x80 or (scalar and 0x3F))
                }
                scalar < 0x10000 -> {
                    append(0xE0 or (scalar shr 12))
                    append(0x80 or ((scalar shr 6) and 0x3F))
                    append(0x80 or (scalar and 0x3F))
                }
                else -> {
                    append(0xF0 or (scalar shr 18))
                    append(0x80 or ((scalar shr 12) and 0x3F))
                    append(0x80 or ((scalar shr 6) and 0x3F))
                    append(0x80 or (scalar and 0x3F))
                }
            }
        }
        var index = start
        while (index < end) {
            val byte = bytes[index].toInt() and 0xFF
            if (byte != '\\'.code) {
                append(byte)
                index += 1
                continue
            }
            index += 1
            when (bytes[index].toInt().toChar()) {
                '"' -> append('"'.code)
                '\\' -> append('\\'.code)
                '/' -> append('/'.code)
                'b' -> append(0x08)
                'f' -> append(0x0C)
                'n' -> append(0x0A)
                'r' -> append(0x0D)
                't' -> append(0x09)
                'u' -> {
                    if (index + 4 >= end) {
                        appendScalar(REPLACEMENT)
                        index = end
                        continue
                    }
                    var scalar = hex4(bytes, index + 1)
                    if (scalar < 0) {
                        appendScalar(REPLACEMENT)
                        index += 1
                        continue
                    }
                    index += 4
                    if (scalar in 0xD800 until 0xDC00 && index + 6 < end && bytes[index + 1] == '\\'.code.toByte() && bytes[index + 2] == 'u'.code.toByte()) {
                        val low = hex4(bytes, index + 3)
                        if (low in 0xDC00..0xDFFF) {
                            scalar = 0x10000 + ((scalar - 0xD800) shl 10) + (low - 0xDC00)
                            index += 6
                        }
                    }
                    appendScalar(if (scalar in 0xD800..0xDFFF) REPLACEMENT else scalar)
                }
                else -> append(bytes[index].toInt() and 0xFF)
            }
            index += 1
        }
        return output.decodeToString(0, length)
    }

    /** The value of the four hex digits at [start], or -1 when one is not. */
    private fun hex4(bytes: ByteArray, start: Int): Int {
        var value = 0
        for (offset in 0 until 4) {
            val digit = when (val byte = bytes[start + offset].toInt()) {
                in '0'.code..'9'.code -> byte - '0'.code
                in 'a'.code..'f'.code -> byte - 'a'.code + 10
                in 'A'.code..'F'.code -> byte - 'A'.code + 10
                else -> return -1
            }
            value = (value shl 4) or digit
        }
        return value
    }
}

package baton

/**
 * Java prints the shortest round-tripping decimal as Swift does, with two
 * spellings to normalize: an integral value prints `1.0` on both, but Java
 * switches to `1.0E10` notation above ten million where Swift prints
 * `10000000000.0`, and below a thousandth where Swift prints `0.0001`.
 */
internal actual fun platformShortestDouble(value: Double): String {
    val text = value.toString()
    if ('E' !in text) return text
    return java.math.BigDecimal(text).stripTrailingZeros().toPlainString().let { plain ->
        if ('.' in plain) plain else "$plain.0"
    }
}

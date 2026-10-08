package baton

import java.math.BigDecimal

/**
 * Java prints the shortest round-tripping digits (since Java 19) as Swift
 * does, in its own notation, `1.0E10` above ten million and below a
 * thousandth; the digits are re-spelled by the contract's rule.
 */
internal actual fun platformShortestDouble(value: Double): String =
    spellShortestDouble(value, BigDecimal(value.toString()))

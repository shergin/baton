package baton

import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode

/**
 * Android's `Double.toString` is not the shortest round trip (it prints
 * `8.409999999999999E21` for `8.41e21`), so the digits are searched for: the
 * double's exact decimal value rounded to one significant digit, then two,
 * until a rounding reads back as the same double, toward zero and away from
 * it at each length, the nearer of two that both read back, the even one on
 * a tie. That is the shortest round-tripping decimal, and of those the
 * nearest, which is what Swift prints. A rounding is read back
 * through `String.toDouble()`, the platform's correctly rounded parser.
 */
internal actual fun platformShortestDouble(value: Double): String {
    if (value == 0.0) return spellShortestDouble(value, BigDecimal.ZERO)
    val exact = BigDecimal(value)
    for (precision in 1..17) {
        val down = exact.round(MathContext(precision, RoundingMode.DOWN))
        val up = exact.round(MathContext(precision, RoundingMode.UP))
        val downReadsBack = down.toString().toDouble() == value
        val upReadsBack = up.toString().toDouble() == value
        if (!downReadsBack && !upReadsBack) continue
        val digits = when {
            !upReadsBack -> down
            !downReadsBack -> up
            else -> nearer(exact, down, up)
        }
        return spellShortestDouble(value, digits)
    }
    // Seventeen significant digits always read back; this is not reached.
    return spellShortestDouble(value, exact.round(MathContext(17, RoundingMode.HALF_EVEN)))
}

/** The one of two roundings nearer [exact]; on a tie, the one whose last digit is even. */
private fun nearer(exact: BigDecimal, down: BigDecimal, up: BigDecimal): BigDecimal {
    val order = exact.subtract(down).abs().compareTo(up.subtract(exact).abs())
    if (order < 0) return down
    if (order > 0) return up
    return if (down.unscaledValue().testBit(0)) up else down
}

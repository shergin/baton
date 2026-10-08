package baton

import java.math.BigDecimal
import kotlin.math.abs

/**
 * Spells a double's shortest round-tripping [digits] by the contract's rule:
 * plain with `.0` for an integral value, and `<mantissa>e<sign><two digits>`
 * when the decimal exponent is below -4 or at 16 or above, as Swift's
 * `description` prints `1e+16` and `1e-05`. Where the digits come from is
 * each target's own.
 */
internal fun spellShortestDouble(value: Double, digits: BigDecimal): String {
    if (value == 0.0) return if (1.0 / value < 0) "-0.0" else "0.0"
    val decimal = digits.stripTrailingZeros()
    val sign = if (value < 0) "-" else ""
    val exponent = decimal.precision() - decimal.scale() - 1
    if (exponent < -4 || exponent >= 16) {
        val unscaled = decimal.unscaledValue().abs().toString()
        val mantissa = if (unscaled.length == 1) unscaled else unscaled[0] + "." + unscaled.substring(1)
        return sign + mantissa + "e" + (if (exponent < 0) "-" else "+") + abs(exponent).toString().padStart(2, '0')
    }
    val plain = decimal.abs().toPlainString()
    return sign + if ('.' in plain) plain else "$plain.0"
}

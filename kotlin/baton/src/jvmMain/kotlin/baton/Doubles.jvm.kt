package baton

import java.math.BigDecimal
import kotlin.math.abs

/**
 * Java prints the shortest round-tripping digits (since Java 19) as Swift
 * does, in its own notation: `1.0E10` above ten million and below a
 * thousandth. The digits are re-spelled by the contract's rule: plain with
 * `.0` for an integral value, and `<mantissa>e<sign><two digits>` when the
 * decimal exponent is below -4 or at 16 or above, as Swift's `description`
 * prints `1e+16` and `1e-05`.
 */
internal actual fun platformShortestDouble(value: Double): String {
    if (value == 0.0) return if (1.0 / value < 0) "-0.0" else "0.0"
    val decimal = BigDecimal(value.toString()).stripTrailingZeros()
    val sign = if (value < 0) "-" else ""
    val exponent = decimal.precision() - decimal.scale() - 1
    if (exponent < -4 || exponent >= 16) {
        val digits = decimal.unscaledValue().abs().toString()
        val mantissa = if (digits.length == 1) digits else digits[0] + "." + digits.substring(1)
        return sign + mantissa + "e" + (if (exponent < 0) "-" else "+") + abs(exponent).toString().padStart(2, '0')
    }
    val plain = decimal.abs().toPlainString()
    return sign + if ('.' in plain) plain else "$plain.0"
}

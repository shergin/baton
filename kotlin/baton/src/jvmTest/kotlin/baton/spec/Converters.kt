package baton.spec

import baton.ScalarConverter
import java.math.BigDecimal
import java.net.URI
import java.net.URISyntaxException
import java.time.Instant
import java.time.format.DateTimeParseException

// The converters `spec/tests/baton.json` names under `kotlin` for its mapped
// scalars, which the generated lenses read through.

/** `Decimal` as a `BigDecimal`. */
object Decimals : ScalarConverter<BigDecimal> {
    override fun parse(text: String): BigDecimal? = text.toBigDecimalOrNull()

    override fun render(value: BigDecimal): String = value.toPlainString()
}

/** `DateTime` as an `Instant`. */
object DateTimes : ScalarConverter<Instant> {
    override fun parse(text: String): Instant? = try {
        Instant.parse(text)
    } catch (_: DateTimeParseException) {
        null
    }

    override fun render(value: Instant): String = value.toString()
}

/** `Url` as a `URI`, as Foundation's `URL(string:)` reads one: an empty text is none. */
object Urls : ScalarConverter<URI> {
    override fun parse(text: String): URI? {
        if (text.isEmpty()) return null
        return try {
            URI(text)
        } catch (_: URISyntaxException) {
            null
        }
    }

    override fun render(value: URI): String = value.toString()
}

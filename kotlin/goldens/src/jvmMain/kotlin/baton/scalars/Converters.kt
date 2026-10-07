package baton.scalars

import baton.ScalarConverter

/** `Decimal` as a `java.math.BigDecimal`, as the goldens' configuration maps it. */
object Decimals : ScalarConverter<java.math.BigDecimal> {
    override fun parse(text: String): java.math.BigDecimal? = text.toBigDecimalOrNull()

    override fun render(value: java.math.BigDecimal): String = value.toPlainString()
}

/** `DateTime` as a `java.time.Instant`, as the goldens' configuration maps it. */
object DateTimes : ScalarConverter<java.time.Instant> {
    override fun parse(text: String): java.time.Instant? =
        try {
            java.time.Instant.parse(text)
        } catch (_: java.time.format.DateTimeParseException) {
            null
        }

    override fun render(value: java.time.Instant): String = value.toString()
}

/** `Url` as a `java.net.URI`, as the goldens' configuration maps it. */
object Urls : ScalarConverter<java.net.URI> {
    override fun parse(text: String): java.net.URI? =
        try {
            java.net.URI(text)
        } catch (_: java.net.URISyntaxException) {
            null
        }

    override fun render(value: java.net.URI): String = value.toString()
}

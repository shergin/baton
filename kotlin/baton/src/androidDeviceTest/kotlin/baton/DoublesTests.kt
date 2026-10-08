package baton

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlin.test.Test
import kotlin.test.assertEquals
import org.junit.runner.RunWith

/**
 * A double's shortest text on Android's runtime, whose `Double.toString` is
 * not the JVM's: the values the JVM printed with too many digits before
 * Java 19, spelled as the contract spells them.
 */
@RunWith(AndroidJUnit4::class)
class DoublesTests {
    @Test
    fun the_shortest_text_of_a_double_on_android_is_the_contract_s() {
        val expected = listOf(
            8.41e21 to "8.41e+21",
            2e23 to "2e+23",
            1e23 to "1e+23",
            1e16 to "1e+16",
            1e-5 to "1e-05",
            0.002 to "0.002",
            0.1 + 0.2 to "0.30000000000000004",
            9007199254740993.0 to "9007199254740992.0",
            -0.0 to "-0.0",
            5e-324 to "5e-324",
            1.7976931348623157e308 to "1.7976931348623157e+308",
            123.456 to "123.456",
            -2.5 to "-2.5",
        )
        for ((value, text) in expected) assertEquals(text, platformShortestDouble(value), "the text of $value")
    }
}

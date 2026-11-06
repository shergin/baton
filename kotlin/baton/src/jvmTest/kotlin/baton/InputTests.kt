package baton

import baton.spec.CharacterBy
import baton.spec.Residence
import baton.spec.Status
import baton.spec.TestCharacterBy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

/**
 * A `@oneOf` input as the generated choice: a case renders the object of its
 * one field, a case holding an input object or the input itself nests it,
 * and two equal cases are equal, as the Swift enum's tests prove.
 */
class InputTests {
    @Test
    fun `a oneOf input's case renders the object of its one field, as a record given that field alone would`() {
        assertEquals(Variable.Object(mapOf("id" to Variable.String("1"))), CharacterBy.Id("1").variable)
        assertEquals("""{"status":"DEAD"}""", CharacterBy.Status_(Status.DEAD).variable.json)
        assertEquals("""{"names":["Rick","Morty"]}""", CharacterBy.Names(listOf("Rick", "Morty")).variable.json)
    }

    @Test
    fun `a oneOf case holding an input object renders that object's own fields under its one member`() {
        val residence = Residence(dimension = "C-137")
        assertEquals(Variable.Object(mapOf("residence" to residence.variable)), CharacterBy.Residence_(residence).variable)
        assertEquals("""{"residence":{"dimension":"C-137"}}""", CharacterBy.Residence_(residence).variable.json)
    }

    @Test
    fun `a oneOf case holding the input itself renders one object inside another, each with one member`() {
        val by = CharacterBy.Fallback(CharacterBy.Fallback(CharacterBy.Id("1")))
        assertEquals("""{"fallback":{"fallback":{"id":"1"}}}""", by.variable.json)
    }

    @Test
    fun `two equal oneOf cases are equal and hash alike, and a case differs from another holding the same value`() {
        assertEquals<CharacterBy>(CharacterBy.Id("1"), CharacterBy.Id("1"))
        assertEquals(CharacterBy.Id("1").hashCode(), CharacterBy.Id("1").hashCode())
        assertNotEquals<CharacterBy>(CharacterBy.Id("1"), CharacterBy.Id("2"))
        assertNotEquals<CharacterBy>(CharacterBy.Names(listOf("1")), CharacterBy.Id("1"))
        assertEquals(2, setOf(CharacterBy.Id("1"), CharacterBy.Id("1"), CharacterBy.Fallback(CharacterBy.Id("1"))).size)
        assertEquals(TestCharacterBy(CharacterBy.Id("1")), TestCharacterBy(CharacterBy.Id("1")))
        assertNotEquals(TestCharacterBy(CharacterBy.Id("1")), TestCharacterBy(CharacterBy.Fallback(CharacterBy.Id("1"))))
    }

    @Test
    fun `an operation's oneOf variable is carried as the object of its one field`() {
        val query = TestCharacterBy(CharacterBy.Residence_(Residence(dimension = "C-137")))
        assertEquals("""{"by":{"residence":{"dimension":"C-137"}}}""", query.variables.json)
    }
}

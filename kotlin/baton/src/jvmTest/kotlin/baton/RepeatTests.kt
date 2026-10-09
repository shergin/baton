package baton

import baton.spec.TestAppendCastNodes
import baton.spec.TestAppendEpisodeNodes
import baton.spec.TestUnion
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * An entity object printed before under the same selection, byte for byte,
 * is read as the earlier object's record by a compare of its bytes, without
 * a parse, and [ChangeSet.repeats] counts the objects read so. The store is
 * what reading every object in full makes, which the manifest's cases hold
 * for each of their responses; these tests hold where the compare applies
 * and where it must not.
 */
class RepeatTests {
    /** The connection the edge directives name. No store holds it: the tests of an edit read the change set alone. */
    private val connections = listOf("Character:1:__TestNotes_notes_connection")

    @Test
    fun `the fixture's entity objects printed before under their selection are read as repeats`() {
        val case = Spec.case("rickandmorty/characters-page-1")
        val store = Store()
        val changes = Ingest.normalize(Spec.bytes(case.responses.single()), store.resolve(checkNotNull(case.plan), case.variables), Store.ROOT_KEY)
        // The count a walk of the fixture by the plan gives: 191 of the 242
        // episode objects under `results.episode`; 440 of the 1,266 characters
        // under the 51 episodes read in full, since a repeated episode's
        // characters are passed over with it; and 21 of the 40 origins and
        // locations, which share one selection. The 11 origins and locations
        // printed with a null id are keyed by their path and never repeat.
        assertEquals(652, changes.repeats)
        // The records are those a full read makes: the dump's, but for the
        // roots of the mutation and the subscription, which the store adds.
        @Suppress("UNCHECKED_CAST")
        val dump = Json.parse(Spec.text(case.records)) as Map<String, Any?>
        assertEquals(899, changes.recordCount)
        assertEquals(dump.keys - setOf(Store.MUTATION_ROOT_KEY, Store.SUBSCRIPTION_ROOT_KEY), changes.recordKeys.toSet())
        // The store after the commit is the dump, as the oracle proves for
        // every case of the manifest.
        store.commit(changes)
        assertNull(case.difference(store))
    }

    @Test
    fun `an entity printed twice under a selection with an edge directive is read in full both times`() {
        val store = Store()
        val mutation = TestAppendCastNodes(id = "1", name = "Rick Sanchez", connections = connections)
        val changes = Ingest.normalize(Spec.bytes("tests/rename-1-pilot-twice-with-cast.json"), store.resolve(TestAppendCastNodes.plan, mutation.variables), Store.MUTATION_ROOT_KEY)
        // The pilot is printed twice, byte for byte, under a selection that
        // holds `characters @appendNode`: each printing is read, and each
        // records the insertion of its cast, as a read of every object does.
        assertEquals(0, changes.repeats)
        assertEquals(listOf("Character:1", "Character:1"), insertedNodes(changes))
    }

    @Test
    fun `an entity printed twice in a plural field with an edge directive is inserted twice`() {
        val store = Store()
        val mutation = TestAppendEpisodeNodes(id = "1", name = "Rick Sanchez", connections = connections)
        val changes = Ingest.normalize(Spec.bytes("tests/rename-1-pilot-twice.json"), store.resolve(TestAppendEpisodeNodes.plan, mutation.variables), Store.MUTATION_ROOT_KEY)
        // The edge directive is on `episode`, a field of the character's
        // selection: the character is read in full, and its reading inserts
        // each element of the list, however the element was read. The
        // episode's own selection records no edit, so its second printing is
        // a repeat, and it is inserted twice all the same.
        assertEquals(1, changes.repeats)
        assertEquals(listOf("Episode:1", "Episode:1"), insertedNodes(changes))
    }

    @Test
    fun `an entity printed again under an abstract selection is read as a repeat`() {
        val store = Store()
        val query = TestUnion(name = "robot")
        val changes = Ingest.normalize(Spec.bytes("tests/union-unknown-type-twice.json"), store.resolve(TestUnion.plan, query.variables), Store.ROOT_KEY)
        // The union's elements print a robot, of a type the build did not
        // list, read by the memberships it answers, and a character, of a
        // type the union lists, each twice: each second printing is a repeat.
        assertEquals(2, changes.repeats)
        store.commit(changes)
        val search = assertNotNull(TestUnion.data(Anchor(store.root, Owner(query.variables, store))).search)
        assertEquals(4, search.size)
        assertEquals(search[0].recordID, search[2].recordID)
        assertEquals(search[1].recordID, search[3].recordID)
        assertEquals("Butter Robot", search[2].asNamed?.name, "the robot's memberships, read from its first printing, hold for the repeat")
    }

    /** The keys of the records the change set's `@appendNode` and `@prependNode` edits insert, in their order. */
    private fun insertedNodes(changes: ChangeSet): List<String> =
        changes.edits.filterIsInstance<ChangeSet.Edit.InsertNode>().map { changes.recordKeys[it.node] }
}

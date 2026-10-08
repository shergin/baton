package baton

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/** The response is the oracle: each case's responses, committed into an empty store, leave the records its dump lists. */
class OracleTests {
    private fun expectDump(name: String) {
        val case = Spec.case(name)
        val store = Store()
        case.commit(store)
        assertNull(case.difference(store), name)
    }

    @Test
    fun `every case of the manifest leaves the records its dump lists`() {
        val failures = ArrayList<String>()
        for (case in Spec.cases) {
            if (case.plan == null) {
                failures.add("${case.name}: no plan for ${case.operation}")
                continue
            }
            val store = Store()
            try {
                case.commit(store)
            } catch (error: Exception) {
                failures.add("${case.name}: $error")
                continue
            }
            case.difference(store)?.let { failures.add("${case.name}: $it") }
        }
        if (failures.isNotEmpty()) fail("${failures.size} of ${Spec.cases.size} cases differ:\n" + failures.joinToString("\n"))
    }

    /**
     * A case's `override`: its response with the overridden leaves set to
     * the override's value, applied as an optimistic layer over the
     * committed case, reads the value at every overridden path; reverted, it
     * leaves the case's dump, but for the records the layer made, which hold
     * nothing once it is gone and wait for the collector.
     */
    @Test
    fun `under a layer that overrides a leaf the store reads the overriding value, and after its revert the records the dump lists`() {
        val failures = ArrayList<String>()
        var overridden = 0
        for (case in Spec.cases) {
            val override = case.override ?: continue
            overridden += 1
            val store = Store()
            try {
                case.commit(store)
                val resolved = store.resolve(checkNotNull(case.plan), case.variables)
                var edited = Json.parse(Spec.text(case.responses.single()), keepingNumbers = true)
                for (path in override.paths) edited = replacing(edited, listOf("data") + path.split("."), override.value)
                val before = store.recordsByKey().keys.toSet()
                val layer = store.applyOptimistic(Ingest.normalize(Json.write(edited).encodeToByteArray(), resolved, Store.rootKey(case.kind)))
                for (path in override.paths) {
                    val read = leafJson(leaf(store, resolved, path, store.root(case.kind)))
                    if (read != leafJson(override.value)) failures.add("${case.name}: under the layer $path reads $read where the override is ${override.value}")
                }
                store.revertOptimistic(layer)
                val made = store.recordsByKey().filterKeys { it !in before }
                for ((key, record) in made) if (!record.isEmpty) failures.add("${case.name}: the record $key the layer made holds values after the revert")
                val dump = store.dump().lines().filterNot { line -> made.keys.any { line.trimStart().startsWith("\"$it\":") } }.joinToString("\n")
                Spec.difference(dump, Spec.text(case.records), case.records)?.let { failures.add("${case.name}: after the layer is reverted, $it") }
            } catch (error: Exception) {
                failures.add("${case.name}: $error")
            }
        }
        assertTrue(overridden > 0, "the manifest has cases with an override")
        if (failures.isNotEmpty()) fail("${failures.size} of $overridden overrides differ:\n" + failures.joinToString("\n"))
    }

    /** [node] with the value at [path], response keys and list indices, set to [value]. */
    private fun replacing(node: Any?, path: List<String>, value: Any?): Any? {
        if (path.isEmpty()) return value
        val head = path.first()
        val rest = path.drop(1)
        return when (node) {
            is Map<*, *> -> {
                check(node.containsKey(head)) { "no $head in the response" }
                LinkedHashMap(node).also { it[head] = replacing(node[head], rest, value) }
            }
            is List<*> -> {
                val index = head.toInt()
                node.toMutableList().also { it[index] = replacing(node[index], rest, value) }
            }
            else -> error("no $head in the response")
        }
    }

    @Test
    fun `a character's header is an entity linked from the root by its lookup key`() = expectDump("rickandmorty/character-header-9")

    @Test
    fun `the public API's first page becomes the records its dump lists`() = expectDump("rickandmorty/characters-page-1")

    @Test
    fun `a connection's page merges into the client record that hangs off its parent`() = expectDump("tests/notes-page-1")

    @Test
    fun `a page fetched after a cursor merges into its connection by appending`() = expectDump("tests/notes-page-2")

    @Test
    fun `a union's members are read by the variant their typename names`() = expectDump("tests/union-1")

    @Test
    fun `an object of a type the plan did not list takes its variant from its membership answers`() = expectDump("tests/union-unknown-type")

    @Test
    fun `an object without its key under a union is keyed by its path and its type`() = expectDump("tests/union-path-location")

    @Test
    fun `errors land on the fields their paths name`() = expectDump("tests/character-errors")

    @Test
    fun `a deferred part lands at the record its path names`() = expectDump("tests/character-deferred")

    @Test
    fun `a deferred part announced as pending lands by its id`() = expectDump("tests/character-deferred-pending")

    @Test
    fun `a mutation's appended edge is a copy the connection owns`() = expectDump("tests/add-note-n9")

    @Test
    fun `a deleted record dumps as null`() = expectDump("tests/delete-note-7")

    @Test
    fun `the tokenizer reads escapes, surrogates, big integers and custom scalars as the dump says`() = expectDump("tokenizer/response")

    @Test
    fun `an empty store holds its three roots and nothing else`() {
        val expected = """
            {
              "client:root": {"__typename": "Query"},
              "client:root:mutation": {"__typename": "Mutation"},
              "client:root:subscription": {"__typename": "Subscription"}
            }

        """.trimIndent()
        assertEquals(expected, Store().dump())
    }

    @Test
    fun `responses that are not well formed fail with their byte offset, and odd escapes read as the spec says`() {
        @Suppress("UNCHECKED_CAST")
        val entries = Json.parse(Spec.text("tokenizer/malformed.json")) as List<Map<String, Any?>>
        val plan = checkNotNull(Spec.operation("TestTokenizerQuery")).plan
        for (entry in entries) {
            val response = Spec.bytes("tokenizer/" + entry["response"])
            val store = Store()
            val resolved = store.resolve(plan, Variables.none)
            if (entry["error"] == "IngestError") {
                val error = runCatching { Ingest.normalize(response, resolved, Store.ROOT_KEY) }.exceptionOrNull()
                assertTrue(error is IngestError, "${entry["response"]} fails to ingest, not with $error")
                assertTrue(error.offset in 0..response.size, "${entry["response"]} names an offset inside the response")
                continue
            }
            store.commit(Ingest.normalize(response, resolved, Store.ROOT_KEY))
            @Suppress("UNCHECKED_CAST")
            for ((path, expected) in entry["leaves"] as Map<String, Any?>) {
                assertEquals(leafJson(expected), leafJson(leaf(store, resolved, path)), "${entry["response"]}: $path")
            }
        }
    }

    /** The value at a dotted path of response keys and list indices from [from], the root of the operation's kind, read through the plan. */
    private fun leaf(store: Store, selection: ResolvedSelection, path: String, from: Record = store.root): Any? {
        var record = from
        var current = selection
        val keys = path.split(".")
        var position = 0
        while (position < keys.size) {
            val key = keys[position]
            val field = checkNotNull(current.variant(record.type).field(key)) { "no field $key" }
            val value = record.peek(field.slot)
            if (position == keys.lastIndex) return plain(value)
            position += 1
            record = when (value) {
                is Value.Ref -> value.record
                is Value.Refs -> {
                    val index = keys[position].toInt()
                    position += 1
                    checkNotNull(value.records[index]) { "no record at $path" }
                }
                else -> error("$key is not a link: $value")
            }
            current = (field.kind as ResolvedField.Kind.Linked).selection
        }
        return null
    }

    private fun plain(value: Value): Any? = when (value) {
        is Value.String -> value.value
        is Value.Int -> value.value
        is Value.Double -> value.value
        is Value.Bool -> value.value
        is Value.List -> value.values.map { plain(it) }
        Value.Null, Value.Missing -> null
        else -> error("not a leaf: $value")
    }

    private fun leafJson(value: Any?): String = when (value) {
        null -> "null"
        is String -> value.map { if (it.code < 0x80) it.toString() else "\\u%04x".format(it.code) }.joinToString("")
        is List<*> -> value.joinToString(",", "[", "]") { leafJson(it) }
        else -> value.toString()
    }
}

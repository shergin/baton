package baton

/**
 * Values as the ingest reads them, before the store decides which won: a
 * kind and two numbers per value in parallel arrays, so reading a response
 * allocates nothing per value. A string is a range of the response's bytes
 * until the commit materializes the winner; a link is a record's index in
 * the change set; a list of links or scalars is a run in [ChangeSet.refs] or
 * [ChangeSet.scalars].
 */
internal object Raw {
    const val NULL: Byte = 0
    const val BOOL: Byte = 1
    const val INT: Byte = 2
    const val DOUBLE: Byte = 3
    const val STRING: Byte = 4
    const val ESCAPED_STRING: Byte = 5
    const val REF: Byte = 6
    const val REFS: Byte = 7
    const val LIST: Byte = 8
}

/** A growable run of raw values: a kind, a 64-bit payload (the number, or a start) and a 32-bit one (an end, or a count). */
internal class RawValues(capacity: Int) {
    var kinds = ByteArray(capacity)
    var first = LongArray(capacity)
    var second = IntArray(capacity)
    var size = 0

    fun add(kind: Byte, first: Long, second: Int) {
        if (size == kinds.size) grow()
        kinds[size] = kind
        this.first[size] = first
        this.second[size] = second
        size += 1
    }

    fun clear() {
        size = 0
    }

    private fun grow() {
        val capacity = maxOf(8, kinds.size * 2)
        kinds = kinds.copyOf(capacity)
        first = first.copyOf(capacity)
        second = second.copyOf(capacity)
    }
}

/**
 * A normalized response, not yet in the store: records by key, one flat
 * list of (record, slot, value) entries, lists in shared arenas, strings as
 * byte ranges into the response, the edits the plan's connections and edge
 * directives ask for, and the field errors the response carried, resolved to
 * the records and slots they name. Made off the store's thread; it holds no
 * record and touches no snapshot state. See `spec/runtime.md`, section 3.
 */
internal class ChangeSet(val bytes: ByteArray) {
    /** What the store does after writing the entries; records are indices into the change set, connections their record keys. */
    sealed interface Edit {
        class Merge(val connection: Int, val page: Int, val slots: ConnectionSlots, val mode: ConnectionMode) : Edit
        class InsertEdge(val edge: Int, val connections: List<String>, val prepend: Boolean) : Edit
        class InsertNode(val node: Int, val edgeType: TypeID, val connections: List<String>, val prepend: Boolean) : Edit
        class DeleteEdge(val id: String, val connections: List<String>) : Edit
        class DeleteRecord(val id: String) : Edit
    }

    /** A field error resolved to the record and slot its path names, and whether a `@catch` on the way handles it. */
    class FieldErrorEntry(val record: Int, val slotIndex: Int, val error: FieldError, val caught: Boolean)

    val recordKeys = ArrayList<String>(bytes.size / 512 + 4)
    val recordTypes = ArrayList<TypeID>(bytes.size / 512 + 4)
    /** Where each record's id starts in its key, or -1 for a record keyed by its path. */
    val recordIDOffsets = ArrayList<Int>(bytes.size / 512 + 4)
    private val index = HashMap<String, Int>(bytes.size / 512 + 4)

    /**
     * The records whose entity key came from one unescaped key field, by the
     * type and the field's bytes, in front of [index]: an entity a response
     * names many times, as every episode of a character names its
     * characters, is found by its bytes, and its key string is made once, on
     * first sight. Open addressing over four ints a slot: the record, where
     * the bytes start and end, and their hash; the string index stays the
     * record of truth, so a spelling this table does not hold still finds
     * its record there.
     */
    private var spans = IntArray(spanCapacity(bytes.size / 512 + 4) * 4) { -1 }
    private var spanCount = 0

    /** What the response said of types the plan did not list: records of the type are members of the condition. */
    val memberships = ArrayList<Pair<TypeID, TypeID>>()

    /** The entries' records and slot indices; their values are [values] at the same position. */
    var entryRecords = IntArray(bytes.size / 24 + 8)
        private set
    var entrySlots = IntArray(bytes.size / 24 + 8)
        private set
    val values = RawValues(bytes.size / 24 + 8)

    /** The entries of record `i` are `starts[i] until starts[i + 1]`, once grouped. */
    var starts = IntArray(0)
        private set
    var refs = IntArray(bytes.size / 128 + 4)
        private set
    var refCount = 0
        private set
    val scalars = RawValues(16)
    val edits = ArrayList<Edit>()
    val fieldErrors = ArrayList<FieldErrorEntry>()
    /** Errors without a path, or with one that names no field the operation selected: nothing in the store holds them. */
    val unplacedErrors = ArrayList<FieldError>()
    /** How many objects were read as repeats of an earlier object, by a compare of their bytes rather than a parse; for the tests and the benchmarks. */
    var repeats = 0

    val recordCount: Int get() = recordKeys.size
    val entryCount: Int get() = values.size

    /** The record for a key, added on first sight. */
    fun record(key: String, type: TypeID, idOffset: Int): Int {
        index[key]?.let { return it }
        val id = recordKeys.size
        recordKeys.add(key)
        recordTypes.add(type)
        recordIDOffsets.add(idOffset)
        index[key] = id
        return id
    }

    /**
     * The record of an entity of `type` keyed by the one unescaped key field
     * at `bytes[start, end)`, added on first sight under the key
     * `typeName:text`, as [record] adds it.
     */
    fun entityRecord(typeName: String, type: TypeID, start: Int, end: Int): Int {
        val hash = spanHash(type, start, end)
        val mask = spans.size / 4 - 1
        var slot = hash and mask
        while (true) {
            val base = slot * 4
            val record = spans[base]
            if (record < 0) break
            if (spans[base + 3] == hash && spans[base + 2] - spans[base + 1] == end - start && recordTypes[record] == type && sameBytes(spans[base + 1], start, end - start)) return record
            slot = (slot + 1) and mask
        }
        val record = record(Record.entityKey(typeName, Text.materialize(bytes, start, end, false)), type, Record.idOffset(typeName))
        if ((spanCount + 1) * 2 > spans.size / 4) {
            growSpans()
        }
        insertSpan(record, start, end, hash)
        return record
    }

    private fun spanHash(type: TypeID, start: Int, end: Int): Int {
        var hash = type.raw * -0x61c88647
        for (position in start until end) hash = (hash xor (bytes[position].toInt() and 0xFF)) * 16777619
        return hash xor (hash ushr 16)
    }

    private fun sameBytes(first: Int, second: Int, length: Int): Boolean {
        for (offset in 0 until length) if (bytes[first + offset] != bytes[second + offset]) return false
        return true
    }

    private fun insertSpan(record: Int, start: Int, end: Int, hash: Int) {
        val mask = spans.size / 4 - 1
        var slot = hash and mask
        while (spans[slot * 4] >= 0) slot = (slot + 1) and mask
        val base = slot * 4
        spans[base] = record
        spans[base + 1] = start
        spans[base + 2] = end
        spans[base + 3] = hash
        spanCount += 1
    }

    private fun growSpans() {
        val old = spans
        spans = IntArray(old.size * 2) { -1 }
        spanCount = 0
        for (base in old.indices step 4) {
            if (old[base] >= 0) insertSpan(old[base], old[base + 1], old[base + 2], old[base + 3])
        }
    }

    fun addEntry(record: Int, slotIndex: Int, kind: Byte, first: Long, second: Int) {
        if (values.size == entryRecords.size) {
            val capacity = maxOf(8, entryRecords.size * 2)
            entryRecords = entryRecords.copyOf(capacity)
            entrySlots = entrySlots.copyOf(capacity)
        }
        entryRecords[values.size] = record
        entrySlots[values.size] = slotIndex
        values.add(kind, first, second)
    }

    /** Appends a run of links, -1 for a null element; returns where it starts. */
    fun addRefs(targets: IntArray, count: Int): Int {
        val start = refCount
        if (refCount + count > refs.size) refs = refs.copyOf(maxOf(refs.size * 2, refCount + count))
        targets.copyInto(refs, start, 0, count)
        refCount += count
        return start
    }

    /**
     * Groups the entries by record and keeps the last one per slot, at the
     * place of the slot's first entry: an entity that appears at many paths
     * is written once. A stable counting sort, then one pass per record.
     */
    fun group() {
        val recordCount = recordKeys.size
        val total = values.size
        val counts = IntArray(recordCount + 1)
        var highest = -1
        var highestRendered = -1
        for (position in 0 until total) {
            counts[entryRecords[position] + 1] += 1
            val slot = entrySlots[position]
            if (slot > highest) highest = slot else if (slot < 0 && slot.inv() > highestRendered) highestRendered = slot.inv()
        }
        for (record in 0 until recordCount) counts[record + 1] += counts[record]
        val next = counts.copyOf()
        val order = IntArray(total)
        for (position in 0 until total) {
            val record = entryRecords[position]
            order[next[record]] = position
            next[record] += 1
        }
        // The record that last kept each slot, and where it kept it.
        val width = highest + 1 + highestRendered + 1
        val keeper = IntArray(width) { -1 }
        val place = IntArray(width)
        val sortedRecords = IntArray(total)
        val sortedSlots = IntArray(total)
        val sorted = RawValues(total)
        val grouped = IntArray(recordCount + 1)
        var kept = 0
        for (record in 0 until recordCount) {
            grouped[record] = kept
            for (index in counts[record] until counts[record + 1]) {
                val position = order[index]
                val slot = entrySlots[position]
                val column = if (slot >= 0) slot else highest + 1 + slot.inv()
                val at: Int
                if (keeper[column] == record) {
                    at = place[column]
                } else {
                    keeper[column] = record
                    place[column] = kept
                    at = kept
                    kept += 1
                    sorted.add(Raw.NULL, 0, 0)
                }
                sortedRecords[at] = record
                sortedSlots[at] = slot
                sorted.kinds[at] = values.kinds[position]
                sorted.first[at] = values.first[position]
                sorted.second[at] = values.second[position]
            }
        }
        grouped[recordCount] = kept
        entryRecords = sortedRecords
        entrySlots = sortedSlots
        values.kinds = sorted.kinds
        values.first = sorted.first
        values.second = sorted.second
        values.size = kept
        starts = grouped
    }

    /** The highest dense slot index among a record's entries, once grouped; -1 when it has none. */
    fun highestDenseSlot(record: Int): Int {
        var highest = -1
        for (position in starts[record] until starts[record + 1]) {
            val slot = entrySlots[position]
            if (slot > highest) highest = slot
        }
        return highest
    }

    /** The position of a record's entry for a slot, once grouped; -1 when it has none. */
    fun entry(record: Int, slotIndex: Int): Int {
        for (position in starts[record] until starts[record + 1]) {
            if (entrySlots[position] == slotIndex) return position
        }
        return -1
    }

    /** The field errors no `@catch` handles, placed or not, each once. */
    val uncaughtFieldErrors: List<FieldError>
        get() = fieldErrors.filter { !it.caught }.map { it.error } + unplacedErrors

    /** A string value of the response. */
    fun string(start: Int, end: Int, escaped: Boolean): String = Text.materialize(bytes, start, end, escaped)

    private companion object {
        /** Slots for the expected records at half load, a power of two. */
        fun spanCapacity(expected: Int): Int {
            var capacity = 16
            while (capacity < expected * 2) capacity *= 2
            return capacity
        }
    }

    /** Whether the string at the range equals [other], without making a string when the bytes are ASCII. */
    fun stringEquals(start: Int, end: Int, escaped: Boolean, other: String): Boolean {
        if (escaped) return string(start, end, true) == other
        if (other.length != end - start) {
            // A non-ASCII string's UTF-8 length differs from its length in chars.
            for (position in start until end) if (bytes[position] < 0) return string(start, end, false) == other
            return false
        }
        for (offset in 0 until end - start) {
            val byte = bytes[start + offset]
            if (byte < 0) return string(start, end, false) == other
            if (other[offset].code != byte.toInt()) return false
        }
        return true
    }
}

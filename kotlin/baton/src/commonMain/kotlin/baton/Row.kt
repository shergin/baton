package baton

// The image's row codec: the tags, the writing of a record's row and a root
// field's cell, and the reading back, over bytes. `Disk` keeps SQLite and
// knows nothing of the layout; the codec knows nothing of SQL. A row is a
// flag byte and the record's type name, then a cell per value held: the
// key's name, the value's tag and payload, and, after a tag with its high
// bit set, a field error as its message, its path and its `extensions` as
// JSON text, empty for none. Numbers are varints, strings a length and
// UTF-8, links a type name shifted past an entity bit and a key. The names
// of types and keys are the file's, which the disk numbers, so the codec
// asks for them. The layout is the Swift runtime's, though a second
// runtime's rows need not read as the Swift runtime's.

/** The tags of a stored value. */
internal object RowTag {
    const val NULL = 0
    const val NO = 1
    const val YES = 2
    const val INT = 3
    const val DOUBLE = 4
    const val STRING = 5
    const val REF = 6
    const val REFS = 7
    const val LIST = 8
    const val HAS_ERROR = 0x80
}

/**
 * A record and its values at one moment: what a commit hands the image's
 * writer for a changed record, taken on the store's thread and encoded off
 * it. [slots] are the slot indices of [values], dense first, then the
 * store's numbers.
 */
internal class RecordSnapshot(
    val record: Record,
    val slots: IntArray,
    val values: Array<Value>,
    val errors: Map<Int, FieldError>?,
    val deleted: Boolean,
    /**
     * Whether the record's row had been read when the snapshot was taken,
     * so that the values are everything the image holds of the record. The
     * writer merges the values of a record not read into its row, rather
     * than lose what the image held and memory never saw.
     */
    val hydrated: Boolean,
) {
    /** Adds the store's numbers the row is written under, which the writer names when it writes, to [into]: not to be freed before. */
    fun renderedSlots(into: MutableSet<Slot>) {
        for (index in slots) if (index < 0) into.add(Slot(record.type, index))
    }
}

/** A changed field of the query root, which the image stores a row per field. */
internal class RootField(val slot: Slot, val value: Value, val error: FieldError?)

/** Whether the value links a record of a transient type, which the image never names. */
internal val Value.linksTransient: Boolean
    get() = when (this) {
        is Value.Ref -> Registry.isTransient(record.type)
        is Value.Refs -> records.any { it != null && Registry.isTransient(it.type) }
        else -> false
    }

/** Writes a row or a cell into bytes the disk stores. */
internal class RowWriter {
    private var buffer = ByteArray(256)
    var size = 0
        private set

    fun reset() {
        size = 0
    }

    /** The bytes written since the last reset. */
    fun bytes(): ByteArray = buffer.copyOf(size)

    /** A record's row: its flags, its type, and a cell per value held, those whose keys the disk never writes left out. */
    fun row(snapshot: RecordSnapshot, typeName: (TypeID) -> Int, slotName: (Slot) -> Int) {
        val record = snapshot.record
        append((if (snapshot.deleted) 1 else 0) or (if (record.isEntity) 2 else 0))
        appendVarint(typeName(record.type).toLong())
        for (position in snapshot.slots.indices) {
            cell(Slot(record.type, snapshot.slots[position]), snapshot.values[position], snapshot.errors, typeName, slotName)
        }
    }

    /**
     * Keeps, after the row's own cells, the cells of the record's earlier
     * row that it does not write: for a record memory has not read from the
     * image, whose snapshot holds what this launch's responses wrote and not
     * what the image held of it. The row's own cells come first, so that a
     * stale name in the old row cuts a read short only after everything
     * new; a damaged old row is kept as far as it reads. The cells of a
     * deleted row are not kept: a payload that names a deleted record again
     * starts it over, as hydration reads none of them.
     */
    fun merge(old: ByteArray) {
        val oldCells = RowReader(old)
        val flags = oldCells.byte() ?: return
        if (flags and 1 != 0 || oldCells.index() == null) return
        val written = HashSet<Int>()
        val cells = RowReader(buffer, size)
        if (cells.byte() == null || cells.index() == null) return
        while (true) written.add(cells.cell()?.name ?: break)
        while (true) {
            val cell = oldCells.cell() ?: break
            if (cell.name in written) continue
            append(old, cell.start, cell.end)
        }
    }

    /** A record's cell: the key's name and the value with its error. */
    private fun cell(slot: Slot, value: Value, errors: Map<Int, FieldError>?, typeName: (TypeID) -> Int, slotName: (Slot) -> Int) {
        if (value == Value.Missing) return
        // A link to a transient record is left out: nothing on disk names
        // one, and the next launch misses on the slot and fetches.
        if (value.linksTransient) return
        val name = slotName(slot)
        if (name < 0) return
        appendVarint(name.toLong())
        append(value, errors?.get(slot.index), typeName)
    }

    /** A root field's cell: the value with its error. */
    fun cell(field: RootField, typeName: (TypeID) -> Int) {
        append(field.value, field.error, typeName)
    }

    private fun ensure(extra: Int) {
        if (size + extra <= buffer.size) return
        buffer = buffer.copyOf(maxOf(buffer.size * 2, size + extra))
    }

    private fun append(byte: Int) {
        ensure(1)
        buffer[size] = byte.toByte()
        size += 1
    }

    private fun append(bytes: ByteArray, from: Int, to: Int) {
        ensure(to - from)
        bytes.copyInto(buffer, size, from, to)
        size += to - from
    }

    fun appendVarint(value: Long) {
        var rest = value
        while (rest.toULong() >= 0x80u) {
            append((rest.toInt() and 0x7f) or 0x80)
            rest = rest ushr 7
        }
        append(rest.toInt())
    }

    private fun append(string: String) {
        val utf8 = string.encodeToByteArray()
        appendVarint(utf8.size.toLong())
        append(utf8, 0, utf8.size)
    }

    /** A link is the target's type, whether it is an entity, and its key; a null entry of a list is a zero. */
    private fun appendLink(target: Record?, typeName: (TypeID) -> Int) {
        if (target == null) {
            append(0)
            return
        }
        appendVarint(((typeName(target.type) + 1).toLong() shl 1) or (if (target.isEntity) 1L else 0L))
        append(target.key)
    }

    /** A value is a tag and its payload; the tag's high bit says a field error follows. */
    private fun append(value: Value, error: FieldError?, typeName: (TypeID) -> Int) {
        val flag = if (error == null) 0 else RowTag.HAS_ERROR
        when (value) {
            Value.Missing, Value.Null -> append(RowTag.NULL or flag)
            is Value.Bool -> append((if (value.value) RowTag.YES else RowTag.NO) or flag)
            is Value.Int -> {
                append(RowTag.INT or flag)
                appendVarint((value.value shl 1) xor (value.value shr 63))
            }
            is Value.Double -> {
                append(RowTag.DOUBLE or flag)
                val bits = value.value.toRawBits()
                for (byte in 0 until 8) append((bits ushr (8 * byte)).toInt() and 0xff)
            }
            is Value.String -> {
                append(RowTag.STRING or flag)
                append(value.value)
            }
            is Value.Ref -> {
                append(RowTag.REF or flag)
                appendLink(value.record, typeName)
            }
            is Value.Refs -> {
                append(RowTag.REFS or flag)
                appendVarint(value.records.size.toLong())
                for (target in value.records) appendLink(target, typeName)
            }
            is Value.List -> {
                append(RowTag.LIST or flag)
                appendVarint(value.values.size.toLong())
                for (item in value.values) append(item, null, typeName)
            }
        }
        if (error != null) {
            append(error.message)
            append(error.path)
            // The extensions as JSON text; empty for none, since a JSON value is never empty.
            append(error.extensions?.json ?: "")
        }
    }
}

/** A cursor over a row's bytes. Every read is checked against the end: a row is data from a file, and a damaged one must read as nothing, not crash. */
internal class RowReader(private val bytes: ByteArray, private val end: Int = bytes.size) {
    private var offset = 0

    val isAtEnd: Boolean get() = offset >= end
    private val remaining: Int get() = end - offset

    fun byte(): Int? {
        if (offset >= end) return null
        return bytes[offset++].toInt() and 0xff
    }

    /** A varint that names a position in a table: at most `Int.MAX_VALUE`. */
    fun index(): Int? {
        val value = varint() ?: return null
        if (value < 0 || value > Int.MAX_VALUE) return null
        return value.toInt()
    }

    fun varint(): Long? {
        var result = 0L
        var shift = 0
        while (offset < end && shift < 64) {
            val byte = bytes[offset++].toInt() and 0xff
            result = result or ((byte and 0x7f).toLong() shl shift)
            if (byte < 0x80) return result
            shift += 7
        }
        return null
    }

    private fun fixed64(): Long? {
        if (remaining < 8) return null
        var bits = 0L
        for (byte in 0 until 8) bits = bits or ((bytes[offset + byte].toLong() and 0xff) shl (8 * byte))
        offset += 8
        return bits
    }

    private fun string(): String? {
        val length = varint() ?: return null
        if (length < 0 || length > remaining) return null
        val text = bytes.decodeToString(offset, offset + length.toInt())
        offset += length.toInt()
        return text
    }

    // Decoding.

    /** A cell's value with its field error, or null for a damaged row. */
    fun value(type: (Int) -> TypeID?, target: (String, TypeID, Boolean) -> Record): Pair<Value, FieldError?>? {
        val tag = byte() ?: return null
        val value: Value = when (tag and RowTag.HAS_ERROR.inv()) {
            RowTag.NULL -> Value.Null
            RowTag.NO -> Value.False
            RowTag.YES -> Value.True
            RowTag.INT -> Value.Int(zigzag(varint() ?: return null))
            RowTag.DOUBLE -> Value.Double(Double.fromBits(fixed64() ?: return null))
            RowTag.STRING -> Value.String(string() ?: return null)
            RowTag.REF -> {
                val link = link(type, target) ?: return null
                link.record?.let { Value.Ref(it) } ?: Value.Null
            }
            RowTag.REFS -> {
                // Every link takes a byte at least, which bounds what a damaged count can ask for.
                val count = varint() ?: return null
                if (count < 0 || count > remaining) return null
                val targets = ArrayList<Record?>(count.toInt())
                repeat(count.toInt()) { targets.add((link(type, target) ?: return null).record) }
                Value.Refs(targets)
            }
            RowTag.LIST -> {
                val count = varint() ?: return null
                if (count < 0 || count > remaining) return null
                val items = ArrayList<Value>(count.toInt())
                repeat(count.toInt()) { items.add(scalar() ?: return null) }
                Value.List(items)
            }
            else -> return null
        }
        if (tag and RowTag.HAS_ERROR == 0) return value to null
        val message = string() ?: return null
        val path = string() ?: return null
        val extensions = string() ?: return null
        // Extensions the row holds that no longer read are a damaged row.
        var parsed: Variable? = null
        if (extensions.isNotEmpty()) {
            parsed = try {
                Scanner(extensions.encodeToByteArray()).value()
            } catch (_: IngestError) {
                return null
            }
        }
        return value to FieldError(message, path, parsed)
    }

    /** An element of a stored list of scalars. Lists hold scalars only, so a tag of anything else is a damaged row, and nesting cannot recurse. */
    private fun scalar(): Value? = when (byte() ?: return null) {
        RowTag.NULL -> Value.Null
        RowTag.NO -> Value.False
        RowTag.YES -> Value.True
        RowTag.INT -> Value.Int(zigzag(varint() ?: return null))
        RowTag.DOUBLE -> Value.Double(Double.fromBits(fixed64() ?: return null))
        RowTag.STRING -> Value.String(string() ?: return null)
        else -> null
    }

    private fun zigzag(raw: Long): Long = (raw ushr 1) xor -(raw and 1)

    /** A stored link: [record] is null for a null entry of a list. */
    class Link(val record: Record?)

    /** The record a stored link names, or null for a row that could not be read. */
    private fun link(type: (Int) -> TypeID?, target: (String, TypeID, Boolean) -> Record): Link? {
        val head = varint() ?: return null
        if (head == 0L) return Link(null)
        // A link's head is its type's name id plus one, shifted past the entity bit: 1 names no type.
        if (head < 2 || (head ushr 1) > Int.MAX_VALUE.toLong() + 1) return null
        val linked = type(((head ushr 1) - 1).toInt()) ?: return null
        val key = string() ?: return null
        return Link(target(key, linked, head and 1L != 0L))
    }

    // Scanning.

    /** Marks in [used] the names a record's row uses, its type's, its keys' and those of the types its links name, for the sweep of the names table. False for a damaged row, read as far as it went. */
    fun namesOfRow(used: BooleanArray): Boolean {
        if (byte() == null) return false
        mark(index() ?: return false, used)
        while (!isAtEnd) {
            mark(index() ?: return false, used)
            if (!skipValue(used)) return false
        }
        return true
    }

    /** Marks the names a root field's cell uses: the types its links name. */
    fun namesOfCell(used: BooleanArray): Boolean = skipValue(used)

    /** A cell of a record's row, past its header: the key's name and where the cell's bytes are, name and value. */
    class Cell(val name: Int, val start: Int, val end: Int)

    /** The next cell of a record's row, past its header; null at the end, or at a damaged cell. */
    fun cell(): Cell? {
        val start = offset
        val name = index() ?: return null
        if (!skipValue(null)) return null
        return Cell(name, start, offset)
    }

    private fun mark(name: Int, used: BooleanArray?) {
        if (used != null && name < used.size) used[name] = true
    }

    /** Passes over a value and its error, marking the type names its links carry. */
    private fun skipValue(used: BooleanArray?): Boolean {
        val tag = byte() ?: return false
        when (tag and RowTag.HAS_ERROR.inv()) {
            RowTag.NULL, RowTag.NO, RowTag.YES -> Unit
            RowTag.INT -> varint() ?: return false
            RowTag.DOUBLE -> fixed64() ?: return false
            RowTag.STRING -> if (!skipString()) return false
            RowTag.REF -> if (!skipLink(used)) return false
            RowTag.REFS -> {
                val count = varint() ?: return false
                if (count < 0 || count > remaining) return false
                repeat(count.toInt()) { if (!skipLink(used)) return false }
            }
            RowTag.LIST -> {
                val count = varint() ?: return false
                if (count < 0 || count > remaining) return false
                repeat(count.toInt()) { scalar() ?: return false }
            }
            else -> return false
        }
        if (tag and RowTag.HAS_ERROR != 0) {
            repeat(3) { if (!skipString()) return false }
        }
        return true
    }

    private fun skipLink(used: BooleanArray?): Boolean {
        val head = varint() ?: return false
        if (head == 0L) return true
        if (head < 2 || (head ushr 1) > Int.MAX_VALUE.toLong() + 1) return false
        mark(((head ushr 1) - 1).toInt(), used)
        return skipString()
    }

    private fun skipString(): Boolean {
        val length = varint() ?: return false
        if (length < 0 || length > remaining) return false
        offset += length.toInt()
        return true
    }
}

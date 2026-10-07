package baton

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.neverEqualPolicy

/**
 * What a record's slot holds: missing, which means the store never received
 * the field, null, which the server said, or a value. Links compare by
 * identity, since the store holds one record per key. See `spec/runtime.md`,
 * section 1.
 */
internal sealed interface Value {
    data object Missing : Value
    data object Null : Value
    data class Bool(val value: Boolean) : Value
    data class Int(val value: Long) : Value

    /** A float, equal as numbers are: `-0.0` equals `0.0`, as the contract's equal-value rule compares. */
    class Double(val value: kotlin.Double) : Value {
        override fun equals(other: Any?): Boolean = other is Double && other.value == value
        override fun hashCode(): kotlin.Int = if (value == 0.0) 0 else value.hashCode()
        override fun toString(): kotlin.String = "Double($value)"
    }

    data class String(val value: kotlin.String) : Value
    data class Ref(val record: Record) : Value
    data class Refs(val records: kotlin.collections.List<Record?>) : Value
    data class List(val values: kotlin.collections.List<Value>) : Value

    companion object {
        val True: Value = Bool(true)
        val False: Value = Bool(false)
    }
}

/**
 * An entry of a response's `errors` that landed on a field: its message, its
 * response path dotted with list indices (`character.episode.2.name`), and
 * the server's `extensions`, when it sent any.
 */
internal data class FieldError(val message: String, val path: String, val extensions: Variable? = null)

/**
 * One normalized object in the store: its type, its key, a cell per slot, a
 * field error beside a cell where the response put one, and whether
 * `@deleteRecord` removed it.
 *
 * A cell is Compose snapshot state, so a read in composition registers that
 * slot and a write invalidates that slot's readers alone: the contract's
 * notification granularity, a record and a field. The array of cells is
 * sized by the registry's slot count for the type when the record is made
 * and grown when a slot is interned after; a cell's state is made when the
 * slot is first read or written, since a type has many slots and a record
 * holds few. A key the store numbered (a negative slot index) has its cell
 * in a short list sorted by number. A record belongs to its store's thread.
 */
class Record internal constructor(val type: TypeID, val key: String, internal val idOffset: Int = -1) {
    /** Whether `@deleteRecord` removed it: links to it read as null and lists skip it, until a payload names it again. */
    internal var deleted: Boolean = false
        private set

    private var cells: Array<MutableState<Value>?> = arrayOfNulls(Registry.slotCount(type))
    /** The numbers of the store's keys written to the record, ascending, and their cells beside them. */
    private var renderedNumbers: IntArray = EMPTY_NUMBERS
    private var renderedCells: Array<MutableState<Value>?> = EMPTY_CELLS
    private var renderedCount = 0
    /** Field errors by slot index; made when the first error lands. */
    private var errors: HashMap<Int, FieldError>? = null

    /** Whether the record is an entity, keyed `Type:id`. */
    internal val isEntity: Boolean get() = idOffset >= 0

    /** Whether the record is an entity with this id. */
    internal fun hasID(id: String): Boolean =
        idOffset >= 0 && key.length - idOffset == id.length && key.regionMatches(idOffset, id, 0, id.length)

    /** The slot's value, read through its cell: in composition, the read registers the slot. */
    internal fun read(slot: Slot): Value = cell(slot).value

    /** The slot's value for the store's own bookkeeping, making no cell for a slot never written. */
    internal fun peek(slot: Slot): Value {
        val index = slot.index
        if (index >= 0) {
            if (index >= cells.size) return Value.Missing
            return cells[index]?.value ?: Value.Missing
        }
        val position = renderedPosition(index.inv())
        if (position < 0) return Value.Missing
        return renderedCells[position]?.value ?: Value.Missing
    }

    /** The field error beside a slot. */
    internal fun peekError(slot: Slot): FieldError? = errors?.get(slot.index)

    /** Whether any slot carries an error, for the commit's fast path. */
    internal val hasErrors: Boolean get() = errors != null

    /**
     * Writes a slot. Returns the previous value when the value changed, null
     * when it was equal, in which case nothing is written and nobody is
     * told: a reader of the slot hears of a change alone.
     */
    internal fun write(slot: Slot, value: Value): Value? {
        check(slot.type == type) { "a ${slot.type.name} slot written into a ${type.name} record" }
        val index = slot.index
        if (index >= 0 && (index >= cells.size || cells[index] == null)) {
            if (value == Value.Missing) return null
        } else if (index < 0 && renderedPosition(index.inv()) < 0) {
            if (value == Value.Missing) return null
        }
        val cell = cell(slot)
        val previous = cell.value
        if (previous == value) return null
        cell.value = value
        return previous
    }

    /** Sets or clears a slot's error, telling the slot's readers. Returns whether it changed. */
    internal fun setError(slot: Slot, error: FieldError?): Boolean {
        if (error != null) {
            val table = errors ?: HashMap<Int, FieldError>().also { errors = it }
            if (table[slot.index] == error) return false
            table[slot.index] = error
        } else {
            val table = errors ?: return false
            if (table.remove(slot.index) == null) return false
            if (table.isEmpty()) errors = null
        }
        notify(slot)
        return true
    }

    /** Tells a slot's readers that what they read changed though the value did not: its error, or a link's target deleted. */
    internal fun notify(slot: Slot) {
        val cell = cell(slot)
        cell.value = cell.value
    }

    internal fun setDeleted(deleted: Boolean) {
        this.deleted = deleted
    }

    /** Whether the record holds no value: never written, or every value since cleared. */
    internal val isEmpty: Boolean
        get() {
            var empty = true
            forEachValue { _, _ -> empty = false }
            return empty
        }

    /** Calls [body] with every slot that holds a value, dense slots first, then the store's keys by number. */
    internal fun forEachValue(body: (Slot, Value) -> Unit) {
        for (index in cells.indices) {
            val value = cells[index]?.value ?: continue
            if (value == Value.Missing) continue
            body(Slot(type, index), value)
        }
        for (position in 0 until renderedCount) {
            val value = renderedCells[position]?.value ?: continue
            if (value == Value.Missing) continue
            body(Slot(type, renderedNumbers[position].inv()), value)
        }
    }

    /** Every slot that holds a value, with its error; for the dump. */
    internal fun storedSlots(): List<Triple<Slot, Value, FieldError?>> {
        val stored = ArrayList<Triple<Slot, Value, FieldError?>>()
        forEachValue { slot, value -> stored.add(Triple(slot, value, errors?.get(slot.index))) }
        return stored
    }

    /** Copies a slot's value and error under its twin, the second slot the store holds one key at. Returns whether there was a value. */
    internal fun twin(slot: Slot, twin: Slot): Boolean {
        val value = peek(slot)
        if (value == Value.Missing) return false
        write(twin, value)
        errors?.get(slot.index)?.let { errors?.put(twin.index, it) }
        return true
    }

    /** Notifies every slot that links to one of [targets]: deleting a target changes what such a slot reads as without changing it. */
    internal fun notifyLinks(targets: Set<Record>) {
        val linking = ArrayList<Slot>()
        forEachValue { slot, value ->
            val links = when (value) {
                is Value.Ref -> value.record in targets
                is Value.Refs -> value.records.any { it != null && it in targets }
                else -> false
            }
            if (links) linking.add(slot)
        }
        for (slot in linking) notify(slot)
    }

    /** The slot's cell, made, and the arrays grown, on first touch. */
    private fun cell(slot: Slot): MutableState<Value> {
        val index = slot.index
        if (index >= 0) {
            if (index >= cells.size) cells = cells.copyOf(maxOf(index + 1, Registry.slotCount(type)))
            return cells[index] ?: newCell().also { cells[index] = it }
        }
        val number = index.inv()
        val position = renderedPosition(number)
        if (position >= 0) return renderedCells[position] ?: newCell().also { renderedCells[position] = it }
        val insertion = -(position + 1)
        if (renderedCount == renderedNumbers.size) {
            val capacity = maxOf(4, renderedCount * 2)
            renderedNumbers = renderedNumbers.copyOf(capacity)
            renderedCells = renderedCells.copyOf(capacity)
        }
        renderedNumbers.copyInto(renderedNumbers, insertion + 1, insertion, renderedCount)
        renderedCells.copyInto(renderedCells, insertion + 1, insertion, renderedCount)
        val cell = newCell()
        renderedNumbers[insertion] = number
        renderedCells[insertion] = cell
        renderedCount += 1
        return cell
    }

    /** Where a store's key is among the record's: its position, or `-(insertion + 1)`. */
    private fun renderedPosition(number: Int): Int = renderedNumbers.binarySearch(number, 0, renderedCount)

    override fun toString(): String = "Record($key)"

    internal companion object {
        private val EMPTY_NUMBERS = IntArray(0)
        private val EMPTY_CELLS = arrayOfNulls<MutableState<Value>>(0)

        /**
         * Every write is compared by the record before it reaches the cell,
         * and a write of an equal value notifies on purpose, so the cell's
         * own policy never compares.
         */
        private fun newCell(): MutableState<Value> = mutableStateOf(Value.Missing, neverEqualPolicy())

        /** An entity's key, `Type:id`, built here and nowhere else. */
        fun entityKey(typeName: String, id: String): String = "$typeName:$id"

        /**
         * The value part of an entity's key from its key fields' values: one
         * as it is; several each with `\` and `:` escaped by `\`, joined by
         * `:`, so no two lists of values meet.
         */
        fun keyValue(parts: List<String>): String {
            if (parts.size == 1) return parts[0]
            return buildString {
                for ((index, part) in parts.withIndex()) {
                    if (index > 0) append(':')
                    for (character in part) {
                        if (character == ':' || character == '\\') append('\\')
                        append(character)
                    }
                }
            }
        }

        /** Where the id starts in an entity's key of the type. */
        fun idOffset(typeName: String): Int = typeName.length + 1
    }
}

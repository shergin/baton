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
 * One normalized object in the store: its type, its key, a cell per slot, a
 * field error beside a cell where the response put one, and whether
 * `@deleteRecord` removed it.
 *
 * A cell holds its value in a plain array. Beside it, a slot that was read
 * has a channel, Compose snapshot state made at the slot's first read and
 * bumped by a write that changes the slot: a read in composition registers
 * the channel, so a write invalidates that slot's readers alone, the
 * contract's notification granularity, a record and a field. A slot nobody
 * read has no channel, and a write to it is a store into the array. The
 * arrays are sized by what the record holds: a commit reserves the highest
 * slot its change set writes to the record, and a write past the end grows
 * them. A key the store numbered (a negative slot index) has its cell and
 * channel in short lists sorted by number. A record belongs to its store's
 * thread.
 */
class Record internal constructor(val type: TypeID, val key: String, internal val idOffset: Int = -1) {
    /** Whether `@deleteRecord` removed it: links to it read as null and lists skip it, until a payload names it again. */
    @Generated
    var deleted: Boolean = false
        private set

    /** The dense slots' values, by index; null where the slot was never written. */
    private var values: Array<Value?> = EMPTY_VALUES
    /** The dense slots' channels, by index, each made at its slot's first read; empty until one is. */
    private var channels: Array<MutableState<Unit>?> = EMPTY_CHANNELS
    /** The numbers of the store's keys written to the record, ascending, with their values and channels beside them. */
    private var renderedNumbers: IntArray = EMPTY_NUMBERS
    private var renderedValues: Array<Value?> = EMPTY_VALUES
    private var renderedChannels: Array<MutableState<Unit>?> = EMPTY_CHANNELS
    private var renderedCount = 0
    /** Field errors by slot index; made when the first error lands. */
    private var errors: HashMap<Int, FieldError>? = null
    /**
     * Values a netted batch wrote and has not yet settled, by slot index:
     * the store's bookkeeping reads them, while the cells still hold what
     * readers saw before the batch, and the batch's end writes into a cell
     * only a value that differs from it. Null outside such a batch.
     */
    private var staged: HashMap<Int, Value>? = null

    /** Whether the record is an entity, keyed `Type:id`. */
    internal val isEntity: Boolean get() = idOffset >= 0

    /** The id an entity's key carries; null for a record keyed by its path. */
    internal val entityID: String? get() = if (idOffset >= 0) key.substring(idOffset) else null

    /** Whether the record is an entity with this id. */
    internal fun hasID(id: String): Boolean =
        idOffset >= 0 && key.length - idOffset == id.length && key.regionMatches(idOffset, id, 0, id.length)

    /** Makes room for the dense slots below [count]: a commit reserves what its change set writes to the record, so its writes grow nothing. */
    internal fun reserve(count: Int) {
        if (count > values.size) values = values.copyOf(count)
    }

    /** The slot's value, read through its channel: in composition, the read registers the slot. */
    internal fun read(slot: Slot): Value {
        channel(slot).value
        return stored(slot.index)
    }

    /** The slot's value for the store's own bookkeeping, registering nothing and making no channel. */
    internal fun peek(slot: Slot): Value {
        val index = slot.index
        staged?.get(index)?.let { return it }
        return stored(index)
    }

    /** The field error beside a slot. */
    internal fun peekError(slot: Slot): FieldError? = errors?.get(slot.index)

    /** The field error beside a slot, read through the slot's channel, which an error's arrival bumps: in composition, the read registers the slot. */
    internal fun error(slot: Slot): FieldError? {
        channel(slot).value
        return errors?.get(slot.index)
    }

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
        val previous = stored(index)
        if (previous == value) return null
        store(index, value)
        bump(index)
        return previous
    }

    /**
     * Writes a slot for a netted batch: the value is staged, so the store
     * reads it and nobody is told until [settle]. Returns the previous value
     * when the value changed, null when it was equal.
     */
    internal fun stage(slot: Slot, value: Value): Value? {
        check(slot.type == type) { "a ${slot.type.name} slot written into a ${type.name} record" }
        val previous = peek(slot)
        if (previous == value) return null
        // The cell is made now, so the walks over the record's values find the staged value.
        ensure(slot.index)
        val table = staged ?: HashMap<Int, Value>().also { staged = it }
        table[slot.index] = value
        return previous
    }

    /**
     * Ends a slot's staging: the staged value is written into the slot's
     * cell when it differs from what the cell holds, which tells the slot's
     * readers. Returns whether it was written.
     */
    internal fun settle(slot: Slot): Boolean {
        val table = staged ?: return false
        if (!table.containsKey(slot.index)) return false
        val value = table.getValue(slot.index)
        table.remove(slot.index)
        if (table.isEmpty()) staged = null
        val index = slot.index
        if (stored(index) == value) return false
        store(index, value)
        bump(index)
        return true
    }

    /** Sets or clears a slot's error, telling the slot's readers unless [notifying] is false, as in a netted batch, which tells them at its end. Returns whether it changed. */
    internal fun setError(slot: Slot, error: FieldError?, notifying: Boolean = true): Boolean {
        if (error != null) {
            val table = errors ?: HashMap<Int, FieldError>().also { errors = it }
            if (table[slot.index] == error) return false
            table[slot.index] = error
        } else {
            val table = errors ?: return false
            if (table.remove(slot.index) == null) return false
            if (table.isEmpty()) errors = null
        }
        if (notifying) notify(slot)
        return true
    }

    /** Tells a slot's readers that what they read changed though the value did not: its error, or a link's target deleted. */
    internal fun notify(slot: Slot) {
        bump(slot.index)
    }

    internal fun setDeleted(deleted: Boolean) {
        this.deleted = deleted
    }

    /** Whether the record's row has been read from the image: memory then holds everything the image does of it. */
    internal var hydrated: Boolean = false
        private set

    /** Notes that the record's row has been read from the image. */
    internal fun setHydrated() {
        hydrated = true
    }

    /**
     * Fills a slot the record lacks with a value read from the image, and
     * its field error with it. A slot that holds a value is left alone:
     * memory is the truth. Returns whether the slot was filled.
     */
    internal fun fill(slot: Slot, value: Value, error: FieldError?): Boolean {
        if (peek(slot) != Value.Missing) return false
        if (error != null) setError(slot, error, notifying = false)
        write(slot, value)
        return true
    }

    /** The record as the image stores it: its values, errors and deletion now, staged values among them. */
    internal fun snapshot(): RecordSnapshot {
        val slots = ArrayList<Int>()
        val values = ArrayList<Value>()
        forEachValue { slot, value ->
            slots.add(slot.index)
            values.add(value)
        }
        return RecordSnapshot(this, slots.toIntArray(), values.toTypedArray(), errors?.let { HashMap(it) }, deleted, hydrated)
    }

    /** Whether a collection removed the record from its store, or the store ended: a link to it reads nothing more from it. */
    internal var swept: Boolean = false
        private set

    /** The collection pass that last reached the record, the store's epoch: a pass marks with a number and keeps no set. */
    internal var mark: Int = 0

    /**
     * Clears every value and error, telling the slots' readers, and marks
     * the record swept: a collection removes it, so links between removed
     * records break, or the store's session ended.
     */
    internal fun clear() {
        for (index in values.indices) {
            if (stored(index) == Value.Missing) continue
            values[index] = null
            bump(index)
        }
        for (position in 0 until renderedCount) {
            if ((renderedValues[position] ?: Value.Missing) == Value.Missing) continue
            renderedChannels[position]?.value = Unit
        }
        renderedNumbers = EMPTY_NUMBERS
        renderedValues = EMPTY_VALUES
        renderedChannels = EMPTY_CHANNELS
        renderedCount = 0
        errors = null
        staged = null
        swept = true
    }

    /** Drops every value that links to a swept record: a root's links to what a collection removed. */
    internal fun prune() {
        fun linksSwept(value: Value): Boolean = when (value) {
            is Value.Ref -> value.record.swept
            is Value.Refs -> value.records.any { it != null && it.swept }
            else -> false
        }
        val pruned = ArrayList<Slot>()
        forEachValue { slot, value -> if (linksSwept(value)) pruned.add(slot) }
        for (slot in pruned) write(slot, Value.Missing)
    }

    /** Drops the entries under the store's numbers that were freed, with their errors: nothing can name them any more. */
    internal fun drop(freed: Set<Slot>) {
        if (renderedCount == 0) return
        var kept = 0
        for (position in 0 until renderedCount) {
            val number = renderedNumbers[position]
            if (Slot(type, number.inv()) in freed) {
                errors?.remove(number.inv())
                continue
            }
            renderedNumbers[kept] = number
            renderedValues[kept] = renderedValues[position]
            renderedChannels[kept] = renderedChannels[position]
            kept += 1
        }
        for (position in kept until renderedCount) {
            renderedValues[position] = null
            renderedChannels[position] = null
        }
        renderedCount = kept
        if (errors?.isEmpty() == true) errors = null
    }

    /** Calls [body] with every slot that holds a value and its channel, made if the slot was never read; for the harness that observes notifications. */
    internal fun forEachChannel(body: (Slot, Any) -> Unit) {
        for (index in values.indices) {
            if (stored(index) == Value.Missing) continue
            body(Slot(type, index), channel(index))
        }
        for (position in 0 until renderedCount) {
            if ((renderedValues[position] ?: Value.Missing) == Value.Missing) continue
            body(Slot(type, renderedNumbers[position].inv()), renderedChannel(position))
        }
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
        val staged = staged
        for (index in values.indices) {
            val value = staged?.get(index) ?: values[index] ?: continue
            if (value == Value.Missing) continue
            body(Slot(type, index), value)
        }
        for (position in 0 until renderedCount) {
            val index = renderedNumbers[position].inv()
            val value = staged?.get(index) ?: renderedValues[position] ?: continue
            if (value == Value.Missing) continue
            body(Slot(type, index), value)
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

    /** The slot's stored value, missing where the slot was never written; staged values are not read here. */
    private fun stored(index: Int): Value {
        if (index >= 0) return if (index < values.size) values[index] ?: Value.Missing else Value.Missing
        val position = renderedPosition(index.inv())
        return if (position < 0) Value.Missing else renderedValues[position] ?: Value.Missing
    }

    /** The dense array's size once it holds [index]: past the end, half again the size, so a record filled slot by slot grows a few times. */
    private fun grown(index: Int): Int = maxOf(index + 1, values.size + values.size / 2 + 2)

    /** Stores a slot's value, growing the dense array or placing the store's number among the record's as needed. */
    private fun store(index: Int, value: Value) {
        if (index >= 0) {
            if (index >= values.size) values = values.copyOf(grown(index))
            values[index] = value
            return
        }
        // The position first: placing the number may replace the array, and an indexed store reads the array before its index.
        val position = position(index.inv())
        renderedValues[position] = value
    }

    /** Makes a slot's cell, with no value in it: a staged value needs a place the walks over the record find. */
    private fun ensure(index: Int) {
        if (index >= 0) {
            if (index >= values.size) values = values.copyOf(grown(index))
            return
        }
        position(index.inv())
    }

    /** Tells the slot's readers, when it has any: the channel a read made, bumped. */
    private fun bump(index: Int) {
        val channel = if (index >= 0) {
            channels.getOrNull(index)
        } else {
            val position = renderedPosition(index.inv())
            if (position < 0) null else renderedChannels[position]
        }
        channel?.value = Unit
    }

    /** The slot's channel, made at the first read, with the store's number placed among the record's if it is new. */
    private fun channel(slot: Slot): MutableState<Unit> {
        val index = slot.index
        if (index >= 0) return channel(index)
        return renderedChannel(position(index.inv()))
    }

    private fun channel(index: Int): MutableState<Unit> {
        if (index >= channels.size) channels = channels.copyOf(maxOf(index + 1, values.size))
        return channels[index] ?: newChannel().also { channels[index] = it }
    }

    private fun renderedChannel(position: Int): MutableState<Unit> =
        renderedChannels[position] ?: newChannel().also { renderedChannels[position] = it }

    /** The position of a store's number among the record's, placed if it is new, with no value and no channel yet. */
    private fun position(number: Int): Int {
        val found = renderedPosition(number)
        if (found >= 0) return found
        val insertion = -(found + 1)
        if (renderedCount == renderedNumbers.size) {
            val capacity = maxOf(4, renderedCount * 2)
            renderedNumbers = renderedNumbers.copyOf(capacity)
            renderedValues = renderedValues.copyOf(capacity)
            renderedChannels = renderedChannels.copyOf(capacity)
        }
        renderedNumbers.copyInto(renderedNumbers, insertion + 1, insertion, renderedCount)
        renderedValues.copyInto(renderedValues, insertion + 1, insertion, renderedCount)
        renderedChannels.copyInto(renderedChannels, insertion + 1, insertion, renderedCount)
        renderedNumbers[insertion] = number
        renderedValues[insertion] = null
        renderedChannels[insertion] = null
        renderedCount += 1
        return insertion
    }

    /** Where a store's key is among the record's: its position, or `-(insertion + 1)`. */
    private fun renderedPosition(number: Int): Int = renderedNumbers.binarySearch(number, 0, renderedCount)

    override fun toString(): String = "Record($key)"

    internal companion object {
        private val EMPTY_NUMBERS = IntArray(0)
        private val EMPTY_VALUES = arrayOfNulls<Value>(0)
        private val EMPTY_CHANNELS = arrayOfNulls<MutableState<Unit>>(0)

        /**
         * A channel carries no value, so its policy never compares: every
         * bump is a change, and the record decides before bumping whether
         * the slot changed.
         */
        private fun newChannel(): MutableState<Unit> = mutableStateOf(Unit, neverEqualPolicy())

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

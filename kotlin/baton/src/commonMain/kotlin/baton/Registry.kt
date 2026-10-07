package baton

import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi

/** A schema type the build interned; its name is the registry's. */
@Generated
@JvmInline
value class TypeID(val raw: Int) {
    val name: String get() = Registry.typeName(this)
}

/** A field's cell in every record of a type: the type and the cell's index. */
@Generated
data class Slot(val type: TypeID, val index: Int)

/**
 * The process-wide numbering of types and of each type's storage keys, which
 * generated code fills from its `Types` and `Slots` objects and the store
 * reads on every row. Registration is rare and reads are constant, so the
 * state is an immutable snapshot replaced by compare-and-set.
 */
@OptIn(ExperimentalAtomicApi::class)
@Generated
object Registry {
    private class State(
        val typeIDs: Map<String, TypeID>,
        val typeNames: List<String>,
        val slotIndices: List<Map<String, Int>>,
        val slotKeys: List<List<String>>,
        val clientSlots: List<Set<Int>>,
        val transientTypes: List<Boolean>,
        val transientFields: Set<Pair<TypeID, String>>,
        val connections: Map<TypeID, ConnectionSlots>,
    ) {
        fun copy(
            typeIDs: Map<String, TypeID> = this.typeIDs,
            typeNames: List<String> = this.typeNames,
            slotIndices: List<Map<String, Int>> = this.slotIndices,
            slotKeys: List<List<String>> = this.slotKeys,
            clientSlots: List<Set<Int>> = this.clientSlots,
            transientTypes: List<Boolean> = this.transientTypes,
            transientFields: Set<Pair<TypeID, String>> = this.transientFields,
            connections: Map<TypeID, ConnectionSlots> = this.connections,
        ) = State(typeIDs, typeNames, slotIndices, slotKeys, clientSlots, transientTypes, transientFields, connections)
    }

    private val state = AtomicReference(
        State(emptyMap(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptySet(), emptyMap()),
    )

    private inline fun <T> update(transform: (State) -> Pair<State, T>): T {
        while (true) {
            val current = state.load()
            val (next, result) = transform(current)
            if (next === current || state.compareAndSet(current, next)) return result
        }
    }

    fun type(name: String, transient: Boolean = false): TypeID = update { current ->
        val existing = current.typeIDs[name]
        if (existing != null) {
            if (transient && !current.transientTypes[existing.raw]) {
                current.copy(transientTypes = current.transientTypes.toMutableList().also { it[existing.raw] = true }) to existing
            } else {
                current to existing
            }
        } else {
            val id = TypeID(current.typeNames.size)
            current.copy(
                typeIDs = current.typeIDs + (name to id),
                typeNames = current.typeNames + name,
                slotIndices = current.slotIndices + emptyMap(),
                slotKeys = current.slotKeys + listOf(emptyList()),
                // A set is iterable: `+` with a bare set would add its elements, none, not the set.
                clientSlots = current.clientSlots + listOf(emptySet()),
                transientTypes = current.transientTypes + transient,
            ) to id
        }
    }

    fun slot(type: TypeID, storageKey: String): Slot = update { current ->
        val table = type.raw
        val existing = current.slotIndices[table][storageKey]
        if (existing != null) {
            current to Slot(type, existing)
        } else {
            val index = current.slotKeys[table].size
            current.copy(
                slotIndices = current.slotIndices.toMutableList().also { it[table] = it[table] + (storageKey to index) },
                slotKeys = current.slotKeys.toMutableList().also { it[table] = it[table] + storageKey },
            ) to Slot(type, index)
        }
    }

    fun clientSlot(type: TypeID, storageKey: String): Slot {
        val slot = slot(type, storageKey)
        update { current ->
            current.copy(clientSlots = current.clientSlots.toMutableList().also { it[type.raw] = it[type.raw] + slot.index }) to Unit
        }
        return slot
    }

    fun typeName(type: TypeID): String = state.load().typeNames[type.raw]

    fun storageKey(slot: Slot): String {
        require(slot.index >= 0) { "a key a store numbered is named by the store" }
        return state.load().slotKeys[slot.type.raw][slot.index]
    }

    fun slotCount(type: TypeID): Int = state.load().slotKeys[type.raw].size

    internal fun isClient(slot: Slot): Boolean = state.load().clientSlots[slot.type.raw].contains(slot.index)

    internal fun isTransient(type: TypeID): Boolean = state.load().transientTypes[type.raw]

    internal fun markTransient(type: TypeID) {
        update { current ->
            current.copy(transientTypes = current.transientTypes.toMutableList().also { it[type.raw] = true }) to Unit
        }
    }

    internal fun markTransient(type: TypeID, field: String) {
        update { current -> current.copy(transientFields = current.transientFields + (type to field)) to Unit }
    }

    internal fun isTransientField(type: TypeID, storageKey: String): Boolean {
        val name = storageKey.substringBefore('(')
        return state.load().transientFields.contains(type to name)
    }

    internal fun register(slots: ConnectionSlots) {
        update { current -> current.copy(connections = current.connections + (slots.connection to slots)) to Unit }
    }

    internal fun connection(type: TypeID): ConnectionSlots? = state.load().connections[type]

    internal fun typeNames(): List<String> = state.load().typeNames
}

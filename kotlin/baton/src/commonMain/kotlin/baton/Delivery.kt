package baton

/**
 * An incremental response as it arrives: the parts the first announced, by
 * id, and each later part turned into the objects it delivers, each at the
 * record its path names with the selection it fills, or into the streamed
 * list it is an item of, and into the parts the server says it could not
 * deliver. Where an object goes is read from the store, on its thread; the
 * objects are then normalized off it.
 */
internal class Delivery(private val store: Store, private val resolved: ResolvedSelection) {
    private val announced = HashMap<String, IncrementalPart.Pending>()

    /**
     * Each streamed list as this response left it, by its parent record's
     * key and slot: the list as the part that carried it was committed, then
     * the list after each item landed. An item that finds the list changed
     * by anything else, or finds a list this response never wrote, is stale,
     * as Relay's executor holds, and is dropped.
     */
    private val streams = HashMap<Stream, List<Record?>>()

    private data class Stream(val parentKey: String, val slotIndex: Int)

    /** An item's place: the streamed list's storage key and slot on the parent, and the index in it. */
    class Placement(val storageKey: String, val slot: Slot, val index: Int)

    /** A connection, or a paged list, whose page an object lands on: the page merges into it again once the object is in. */
    sealed interface Remerge {
        class Connection(val key: String, val slots: ConnectionSlots, val mode: ConnectionMode) : Remerge
        class Paged(val key: String, val paged: ResolvedPaged, val number: Long) : Remerge
    }

    /**
     * One object a later part delivers: a deferred part's object, at the
     * record its path names, or an item of a streamed list, under the parent
     * record that holds the list.
     */
    class ObjectPart(
        val data: ByteArray,
        val plan: ResolvedSelection,
        /** The record the object fills, or the parent of the list it is an item of. */
        val key: String,
        val type: TypeID,
        val entity: Boolean,
        /** Where the object is in the response, which the errors' paths start with. */
        val path: List<PathSegment>,
        val errors: List<ResponseError>,
        /** The list the object is an item of and its index in it; null for an object that fills its record. */
        val placement: Placement? = null,
        val remerge: Remerge? = null,
    ) {
        /** The object's change set; off the store's thread. */
        fun normalize(): ChangeSet = Ingest.normalize(this)
    }

    /** Notes the parts a part announces, the 2024 shape's `pending`. */
    fun announce(pending: List<IncrementalPart.Pending>) {
        for (part in pending) announced[part.id] = part
    }

    /**
     * The objects a part delivers: each by its own path and label, or by the
     * id of an announced part. A deferred part's object lands at the record
     * the path names, or below a sub-path with the rest of an object the
     * part selects, read by the object's own selection. A streamed list's
     * items land in the list at the parent the path names, at the index the
     * path ends in, or after the last item the stream left when it names
     * none.
     */
    fun objects(part: IncrementalPart): List<ObjectPart> {
        val objects = ArrayList<ObjectPart>()
        for (item in part.items) {
            val base = item.path ?: item.id?.let { announced[it]?.path }
            val label = item.label ?: item.id?.let { announced[it]?.label }
            if (base == null || label == null) {
                dropped(item.path ?: emptyList())
                continue
            }
            val items = item.items
            if (items != null) {
                objects.addAll(streamed(items, base, item.errors))
                continue
            }
            if (base.lastOrNull() is PathSegment.Index) {
                // Relay's shape: one item, its path ending in its index.
                objects.addAll(streamed(listOf(item.data), base, item.errors))
                continue
            }
            val path = base + (item.subPath ?: emptyList())
            val place = store.locate(path, resolved)
            if (place == null) {
                dropped(path)
                continue
            }
            val plan = if (item.subPath?.isNotEmpty() == true) place.selection else place.selection.deferred(label)
            if (plan == null) {
                dropped(path)
                continue
            }
            objects.add(ObjectPart(item.data, plan, place.record.key, place.record.type, place.record.isEntity, path, item.errors, remerge = remerge(place)))
        }
        return objects
    }

    /**
     * The items of a streamed list as objects, each placed at its index in
     * the list at the parent record the path names. The path ends in the
     * first item's index, or in the field, when the items follow the last
     * one the stream left. The path names the list; the part's label is not
     * read again, since the plan marks the field that streams.
     */
    private fun streamed(items: List<ByteArray>, base: List<PathSegment>, errors: List<ResponseError>): List<ObjectPart> {
        var listPath = base
        var start: Int? = null
        val last = listPath.lastOrNull()
        if (last is PathSegment.Index) {
            listPath = listPath.dropLast(1)
            start = last.index
        }
        val name = (listPath.lastOrNull() as? PathSegment.Name)?.name
        val place = if (name == null) null else store.locate(listPath.dropLast(1), resolved)
        if (name == null || place == null) {
            dropped(base)
            return emptyList()
        }
        val field = place.selection.variant(place.record.type).field(name)
        val kind = field?.kind as? ResolvedField.Kind.Linked
        val current = field?.let { place.record.peek(it.slot) as? Value.Refs }
        if (field == null || !field.streams || kind == null || !kind.plural || current == null) {
            dropped(base)
            return emptyList()
        }
        val left = streams[Stream(place.record.key, field.slot.index)]
        if (left == null) {
            dropped(base)
            return emptyList()
        }
        val first = start ?: left.size
        val remerge = remerge(place)
        return items.mapIndexed { offset, data ->
            ObjectPart(
                data, kind.selection, place.record.key, place.record.type, place.record.isEntity,
                listPath + PathSegment.Index(first + offset), errors,
                Placement(field.storageKey, field.slot, first + offset), remerge,
            )
        }
    }

    /** The merge an object landing on a connection's page, or on a paged list's, asks for. */
    private fun remerge(place: Store.Place): Remerge? {
        place.connection?.let { (key, resolved) -> return Remerge.Connection(key, resolved.slots, resolved.mode) }
        val (key, resolved) = place.paged ?: return null
        val number = resolved.page ?: return null
        return Remerge.Paged(key, resolved, number)
    }

    /**
     * Whether a streamed item still fits: the list it is an item of is as
     * the stream left it. A list another commit replaced or edited meanwhile
     * is that commit's; the item is stale, dropped and logged.
     */
    fun fits(obj: ObjectPart): Boolean {
        val placement = obj.placement ?: return true
        val parent = store.existing(obj.key)
        val current = parent?.takeUnless { it.deleted }?.let { it.peek(placement.slot) as? Value.Refs }?.records
        val left = streams[Stream(obj.key, placement.slot.index)]
        if (current == null || left == null || !same(current, left)) {
            dropped(obj.path)
            return false
        }
        return true
    }

    /** Notes every streamed list a committed change set of this response wrote, as the commit left it: the lists a part carried, and the one an item was placed in. */
    fun committed(changes: ChangeSet) {
        for ((record, slotIndex) in changes.streams) {
            val key = changes.recordKeys[record]
            val parent = store.existing(key) ?: continue
            val now = (parent.peek(Slot(parent.type, slotIndex)) as? Value.Refs)?.records ?: continue
            streams[Stream(key, slotIndex)] = now
        }
    }

    private fun same(first: List<Record?>, second: List<Record?>): Boolean {
        if (first.size != second.size) return false
        for (index in first.indices) if (first[index] !== second[index]) return false
        return true
    }

    /**
     * The announced parts a part says the server could not deliver, each as
     * the errors on the fields it would have filled: a deferred part's
     * fields, or the streamed list field whose stream broke off.
     */
    fun failures(part: IncrementalPart): List<Ingest.FailedPart> {
        val failures = ArrayList<Ingest.FailedPart>()
        for (completion in part.completed) {
            if (completion.errors.isEmpty()) continue
            val pending = announced[completion.id]
            val label = pending?.label
            if (pending == null || label == null) {
                dropped(pending?.path ?: emptyList())
                continue
            }
            val place = store.locate(pending.path, resolved)
            val deferred = place?.selection?.deferred(label)
            if (place != null && deferred != null) {
                failures.add(Ingest.failed(deferred, place.record.key, place.record.type, place.record.isEntity, pending.path, completion.errors))
                continue
            }
            val name = (pending.path.lastOrNull() as? PathSegment.Name)?.name
            val parent = if (name == null) null else store.locate(pending.path.dropLast(1), resolved)
            val field = if (parent == null || name == null) null else parent.selection.variant(parent.record.type).field(name)
            if (parent != null && field != null && field.streams) {
                failures.add(Ingest.failedStream(field, parent.record.key, parent.record.type, parent.record.isEntity, pending.path, completion.errors))
                continue
            }
            dropped(pending.path)
        }
        return failures
    }

    /**
     * A part that reaches no record, no deferred selection or no streamed
     * list, or an item whose list changed under it, is dropped and logged:
     * the server and the build disagree.
     */
    private fun dropped(path: List<PathSegment>) {
        store.log?.invoke(LogEvent.PartDropped(Ingest.render(path)))
    }
}

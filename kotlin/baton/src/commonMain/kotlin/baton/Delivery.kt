package baton

/**
 * An incremental response as it arrives: the parts the first announced, by
 * id, and each later part turned into the objects it delivers, each at the
 * record its path names with the selection it fills, and into the parts the
 * server says it could not deliver. Where an object goes is read from the
 * store, on its thread; the objects are then normalized off it.
 */
internal class Delivery(private val store: Store, private val resolved: ResolvedSelection) {
    private val announced = HashMap<String, IncrementalPart.Pending>()

    /** One object a later part delivers, at the record its path names. */
    class ObjectPart(
        val data: ByteArray,
        val plan: ResolvedSelection,
        val key: String,
        val type: TypeID,
        val entity: Boolean,
        /** Where the object is in the response, which the errors' paths start with. */
        val path: List<PathSegment>,
        val errors: List<ResponseError>,
    ) {
        /** The object's change set; off the store's thread. */
        fun normalize(): ChangeSet = Ingest.normalizeObject(data, plan, key, type, entity, path, errors)
    }

    /** Notes the parts a part announces, the 2024 shape's `pending`. */
    fun announce(pending: List<IncrementalPart.Pending>) {
        for (part in pending) announced[part.id] = part
    }

    /**
     * The objects a part delivers: each by its own path and label, or by the
     * id of an announced part, at the record the path names. Below the
     * announced path an item carries the rest of an object the part selects,
     * read by the object's own selection.
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
            val path = base + (item.subPath ?: emptyList())
            val (record, selection) = store.walk(path, resolved) ?: run {
                dropped(path)
                null
            } ?: continue
            val plan = if (item.subPath?.isNotEmpty() == true) selection else selection.deferred(label)
            if (plan == null) {
                dropped(path)
                continue
            }
            objects.add(ObjectPart(item.data, plan, record.key, record.type, record.isEntity, path, item.errors))
        }
        return objects
    }

    /** The announced parts a part says the server could not deliver, each as the errors on the fields it would have filled. */
    fun failures(part: IncrementalPart): List<Ingest.FailedPart> {
        val failures = ArrayList<Ingest.FailedPart>()
        for (completion in part.completed) {
            if (completion.errors.isEmpty()) continue
            val pending = announced[completion.id]
            val label = pending?.label
            val place = if (pending != null && label != null) store.walk(pending.path, resolved) else null
            val deferred = place?.second?.deferred(label!!)
            if (pending == null || place == null || deferred == null) {
                dropped(pending?.path ?: emptyList())
                continue
            }
            val record = place.first
            failures.add(Ingest.failed(deferred, record.key, record.type, record.isEntity, pending.path, completion.errors))
        }
        return failures
    }

    /** A part that reaches no record, or no deferred selection, is dropped and logged: the server and the build disagree. */
    private fun dropped(path: List<PathSegment>) {
        store.log?.invoke(LogEvent.PartDropped(Ingest.render(path)))
    }
}

package baton

import androidx.compose.runtime.mutableStateOf
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.TimeSource

/**
 * The normalized records. The store belongs to the thread that made it, the
 * main thread in an app: its entry points check the caller's thread, and a
 * commit, the only writer, runs there. The ingest runs off it and hands the
 * commit a change set. An app makes one when it makes its environment, and
 * the environment owns it from then on. See `spec/runtime.md`, sections 1
 * and 4.
 */
class Store(
    /**
     * The store's image on disk, when it has one: every server batch is
     * written behind, and the availability check reads from it what memory
     * lacks. The store owns it from here on: the environment's end closes it.
     */
    val persistence: Persistence? = null,
    /**
     * How old an operation's data may be before it reads as stale, for an
     * operation whose document states no `@cacheExpiration` of its own; null
     * is forever. Given when the store is made, where Relay gives it.
     */
    val cacheExpiration: Duration? = null,
    /** How many released roots keep their records alive, oldest out first, and how many completed mutations keep their payloads, apart from them. */
    val releaseBufferSize: Int = 10,
) {
    private val thread = currentThreadId()
    private val records = HashMap<String, Record>()

    /** Whether the store's session has ended: it holds nothing, commits nothing more and reports nothing. */
    internal var ended = false
        private set

    /** Bumped by `invalidate()`; data fetched before it is stale. */
    internal var invalidationEpoch = 0
        private set

    /** Where the store's clock starts. */
    private val origin = TimeSource.Monotonic.markNow()

    /** How far ahead of the monotonic clock the store reads; for the tests and the scripts, which advance time rather than wait for it. */
    internal var clockOffset: Duration = Duration.ZERO

    /** The store's clock, read for every stamp and every staleness: the monotonic clock, run ahead by [clockOffset]. */
    internal val now: TimeSource.Monotonic.ValueTimeMark get() = origin + origin.elapsedNow() + clockOffset

    /** The wall clock the image keeps ages by, in seconds since 1970, run ahead the same way. */
    internal val wallNow: Double
        get() = Clock.System.now().toEpochMilliseconds() / 1000.0 + clockOffset.inWholeNanoseconds / 1e9

    /** How many records have been filled from the image; for tests. */
    internal var hydratedRecords = 0

    /**
     * The root's fields the image filled, by slot index. The image stores
     * the root a row per field and the root is never marked hydrated, so
     * these tell the walk in memory which of its fields came from there.
     */
    internal val hydratedRootSlots = HashSet<Int>()

    /** The store's numbers the image's rows were read under: a value a row filled stays under its number for the image's life. */
    internal val imageSlots = HashSet<Slot>()

    /** What the image was told to forget and has not yet. */
    private val forgotten = Forgotten()

    /**
     * What a server batch could not edit in memory: connection keys, and the
     * bare ids of records `@deleteRecord` named that memory does not hold.
     * Recorded only while a server's payload applies to a store with an
     * image.
     */
    internal class Forgets {
        val keys = ArrayList<String>()
        val ids = ArrayList<String>()
    }

    internal var forgets: Forgets? = null

    /** The roots, by the operation's key: retained, waiting in the release buffer, or a completed mutation's. */
    internal val roots = HashMap<String, Root>()
    /** Released roots' keys, oldest first. */
    internal val releaseBuffer = ArrayList<String>()
    /** Completed mutations' roots' keys, oldest first, apart from the buffer. */
    internal val completedMutations = ArrayList<String>()
    internal var collectionScheduled = false
    /** How many collections have run; for tests. */
    internal var collections = 0

    /**
     * Runs a pass on a later turn of the store's thread; the environment
     * sets it to its main dispatcher. A store without an environment
     * collects when asked.
     */
    internal var scheduler: ((() -> Unit) -> Unit)? = null

    /** The scopes made by hand over the store, whose rendered keys stay numbered for the session. */
    internal val looseScopes = ArrayList<Owner>()

    /** The resolutions of fetches in flight, whose numbers stay until the fetch ends. */
    internal val inFlight = ArrayList<ResolvedSelection>()

    /** Whether the batch in progress moved or dropped a link, which may have orphaned what the link reached: a pass follows the batch. */
    private var linkDropped = false

    /**
     * Whether the batch in progress changed a field error, a null, a link,
     * or whether a record is deleted: what `@throwOnFieldError` and bubbling
     * `@required` read, so the roots' verdicts are settled again.
     */
    private var nullsOrErrorsChanged = false

    /** The record query root fields hang off, typed `Query` whatever the schema calls its root type. */
    internal val root: Record = Record(Registry.type("Query"), ROOT_KEY)
    /** The record mutation payloads hang off. */
    internal val mutationRoot: Record = Record(Registry.type("Mutation"), MUTATION_ROOT_KEY)
    /** The record subscription payloads hang off. */
    internal val subscriptionRoot: Record = Record(Registry.type("Subscription"), SUBSCRIPTION_ROOT_KEY)

    /** The keys the store's session renders from variables. */
    internal val keys = Keys()

    /**
     * Slots that hold one key, each the other's twin: the store's number for
     * a text and the constant the build named for it afterwards. A write to
     * either lands in both.
     */
    internal val twins = HashMap<Slot, Slot>()

    /** The environment's log; the image's writer gets it too, and calls it from its own thread. */
    internal var log: ((LogEvent) -> Unit)? = null
        set(value) {
            field = value
            persistence?.log = value
        }

    /**
     * What an operation's data deserves, by the operation's own policies:
     * sound; failed on the uncaught field errors in the operation's own
     * selection, under `@throwOnFieldError`; or failed on the first
     * `@required` field that is null and bubbles to the root. A fact about
     * data, kept on the root and settled by the store; the handle derives
     * its phase from it and stores none.
     */
    internal sealed interface Verdict {
        data object Sound : Verdict
        data class FieldErrors(val errors: List<FieldError>) : Verdict
        data class RequiredMissing(val path: String) : Verdict
    }

    /** What judges an operation's data: the handle of an operation with a policy, whose generated code walks the operation's own selection. */
    internal fun interface Judge {
        fun judge(): Verdict
    }

    /**
     * An operation's selection and the record it starts from, kept by the
     * store: how many hold it, its age (when the store last received the
     * operation's response, and under which invalidation), whether the
     * store holds its data, and the verdict on that data. Its key is the
     * operation's name and its variables as JSON. Whether the data is
     * present, the verdict and the fetch time are snapshot state, so a
     * composable that reads a handle's phase follows the commit that moves
     * them. See `spec/runtime.md`, sections 7 and 8.
     */
    internal class Root(val key: String, val resolved: ResolvedSelection, val record: Record) {
        internal var holders = 0
        /** How many of the holders attached with a policy that allows the network: a fetch the runtime starts later asks whether any does. */
        internal var networkHolders = 0
        private val fetchTimeState = mutableStateOf<TimeSource.Monotonic.ValueTimeMark?>(null)
        /** When the store last committed the operation's response. */
        val fetchTime: TimeSource.Monotonic.ValueTimeMark? get() = fetchTimeState.value
        /** The invalidation the data was fetched under. */
        internal var fetchEpoch = 0
        /** How many responses the store has committed for the operation. */
        internal var fetches = 0
        /** The fetch a heal asked for, by its number: a miss under that fetch's data is unexpected, and healed no further. */
        internal var healedAt: Int? = null
        private val presentState = mutableStateOf(false)
        /**
         * Whether the store holds the operation's data: a check found it, or
         * the operation's response committed. Once present, it stays so for
         * the root's life; a root pushed out and made again starts over.
         */
        val present: Boolean get() = presentState.value
        private val verdictState = mutableStateOf<Verdict>(Verdict.Sound)
        /**
         * What the data deserves, settled by [settle]: after a batch that
         * changed a null, a link, an error or a deletion, and when the handle
         * finds or fetches the data. A verdict equal to the last is no
         * change, so a body reading a phase it did not move is not woken.
         */
        val verdict: Verdict get() = verdictState.value
        /** Who judges the data: the handle of an operation with a policy; none for an operation whose data is always sound. */
        internal var judge: Judge? = null
        /** The scope that reads under the root, whose rendered keys the root keeps numbered; one per root. */
        internal var scope: Owner? = null

        /** Whether a holder's policy allows the network. */
        val allowsNetwork: Boolean get() = networkHolders > 0

        /** Settles the verdict by the judge, when the root has one and holds data. */
        fun settle() {
            if (!present) return
            val judge = judge ?: return
            val next = judge.judge()
            if (next != verdictState.value) verdictState.value = next
        }

        /** A check found the operation's data in the store; the verdict is settled on it, since a root nobody held saw no batch settle it. */
        fun found() {
            if (!present) presentState.value = true
            settle()
        }

        /** The operation's own response just committed: the first response, and a root nobody holds, are settled here; a batch settled the rest. */
        fun committed() {
            val first = !present
            if (first) presentState.value = true
            if (first || holders == 0) settle()
        }

        internal fun stamp(time: TimeSource.Monotonic.ValueTimeMark?, epoch: Int) {
            fetchTimeState.value = time
            fetchEpoch = epoch
        }

        /** Adds the store's numbers the root's resolution and scopes hold to [into]. */
        internal fun renderedSlots(into: MutableSet<Slot>) {
            resolved.renderedSlots(into)
            scope?.renderedSlots(into)
        }

        override fun toString(): String = "Root($key)"
    }

    /** The placeholder record of each type a non-null link without a record has read. */
    private val placeholders = HashMap<TypeID, Record>()

    init {
        records[ROOT_KEY] = root
        records[MUTATION_ROOT_KEY] = mutationRoot
        records[SUBSCRIPTION_ROOT_KEY] = subscriptionRoot
    }

    /** Fails a call from a thread other than the store's. */
    internal fun checkThread() {
        check(currentThreadId() == thread) { "a store is used on the thread that made it" }
    }

    /** The root a response of the operation kind is committed under. */
    internal fun root(kind: OperationKind): Record = when (kind) {
        OperationKind.QUERY -> root
        OperationKind.MUTATION -> mutationRoot
        OperationKind.SUBSCRIPTION -> subscriptionRoot
    }

    /** Binds an operation's variables under the store's keys: the resolution the ingest and the commit read. */
    internal fun resolve(plan: Plan, variables: Variables): ResolvedSelection {
        checkThread()
        return plan.resolve(variables, keys)
    }

    internal val count: Int get() = records.size

    internal fun existing(key: String): Record? = records[key]

    /** Every record the store holds, by key. */
    internal fun recordsByKey(): Map<String, Record> {
        checkThread()
        return records
    }

    /**
     * Every value a record holds, by storage key, with its error. A key the
     * store holds at two slots, a rendering and the constant adopted for it,
     * is one field: the rendered half yields to the constant's.
     */
    internal fun storedFields(record: Record): List<Triple<String, Value, FieldError?>> {
        checkThread()
        val fields = ArrayList<Triple<String, Value, FieldError?>>()
        for ((slot, value, error) in record.storedSlots()) {
            if (slot.index < 0 && twins.containsKey(slot)) continue
            fields.add(Triple(keys.text(slot), value, error))
        }
        return fields
    }

    /** The record for a key, and whether this call made it. */
    private fun record(key: String, type: TypeID, idOffset: Int): Pair<Record, Boolean> {
        records[key]?.let { found ->
            // A key names one type: an entity's starts with it, and a path key under an interface or union ends with it.
            check(found.type == type) { "$key is a ${found.type.name}, not a ${type.name}" }
            return found to false
        }
        val made = Record(type, key, idOffset)
        records[key] = made
        return made to true
    }

    internal fun recordFor(key: String, type: TypeID, idOffset: Int): Record = record(key, type, idOffset).first

    /**
     * The record a stored link names: the store's, or one made for it. A row
     * says of a link's target that it is an entity, not where its id starts:
     * the type's name gives that.
     */
    internal fun target(key: String, type: TypeID, entity: Boolean): Record {
        records[key]?.let { return it }
        return recordFor(key, type, if (entity) Record.idOffset(type.name) else -1)
    }

    /** Registers a record a lookup made once the image had its row. */
    internal fun register(record: Record) {
        records[record.key] = record
    }

    /** The kinds of batch: the server's, an optimistic response's, and the runtime's own writes (a lookup's link bound, a page's loading flag). */
    internal enum class BatchKind { SERVER, OPTIMISTIC, LOCAL }

    /** One step of a batch, as it was before the batch: reversed when a layer lifts. */
    internal sealed interface Undo {
        class Write(val record: Record, val slot: Slot, val value: Value) : Undo
        class Error(val record: Record, val slot: Slot, val error: FieldError?) : Undo
        class Deletion(val record: Record, val was: Boolean) : Undo
    }

    /** A slot of one record, by the record's identity. */
    private data class SlotKey(val record: Record, val slot: Slot)

    /** A record a server's payload changed, with the slot for the query root, which the image stores a row per field. */
    internal data class Changed(val record: Record, val slot: Slot?)

    /** What a slot held before a netted batch touched it: its error, and whether it counts among the changed, which a twin's write does not. */
    private class Original(val error: FieldError?, val counted: Boolean)

    /**
     * One batch of writes: its kind, the undo log of what it changed, and
     * how it notifies. A direct batch notifies as it writes, since nothing in
     * it can change back: a plain server batch under no optimistic layer, or
     * the runtime's own writes. Any other batch is netted: it stages its
     * writes, keeps every slot it touched with the error before it, and at
     * its end tells only the slots whose value or error differs, so a slot
     * changed and changed back notifies nobody. It counts the slots it
     * changed in records that existed before it, a twin's write once with
     * its twin.
     */
    internal class Batch(val kind: BatchKind, val direct: Boolean) {
        private var directCount = 0
        private val originals = LinkedHashMap<SlotKey, Original>()
        /** The records whose deleted flag the batch changed, with the flag before it. */
        val flagged = HashMap<Record, Boolean>()
        /** The steps taken, each as it was before: a layer's own log. */
        val undo = ArrayList<Undo>()
        /** Whether steps are kept: by a netted batch that is not the runtime's own, and not while a layer is lifted, whose steps undo an earlier log. */
        var keepsUndo = !direct && kind != BatchKind.LOCAL

        /**
         * What a server's payload changed, for the image: each record once,
         * and each of the query root's slots once, in order. Kept only while
         * a payload applies to a store with an image.
         */
        var persisted: LinkedHashSet<Changed>? = null

        /** Notes a change for the image: the query root's by slot, any other record's as the record. */
        fun persist(record: Record, slot: Slot, root: Record) {
            val persisted = persisted ?: return
            persisted.add(if (record === root) Changed(record, slot) else Changed(record, null))
        }

        fun touched(record: Record, slot: Slot, error: FieldError?, twin: Boolean) {
            if (direct) {
                if (!twin) directCount += 1
                return
            }
            originals.getOrPut(SlotKey(record, slot)) { Original(error, counted = !twin) }
        }

        fun record(step: Undo) {
            if (keepsUndo) undo.add(step)
        }

        /** The steps taken since [since], for a layer's own log. */
        fun steps(since: Int): List<Undo> = undo.subList(since, undo.size).toList()

        /** The records whose deleted flag differs at the end. */
        fun flipped(): Set<Record> = flagged.filter { (record, was) -> record.deleted != was }.keys

        /** Settles every staged value and tells the slots whose value or error differs from before the batch; returns how many differ. */
        fun finish(): Int {
            if (direct) return directCount
            var changed = 0
            for ((key, original) in originals) {
                val written = key.record.settle(key.slot)
                val errorChanged = key.record.peekError(key.slot) != original.error
                if (!written && errorChanged) key.record.notify(key.slot)
                if ((written || errorChanged) && original.counted) changed += 1
            }
            return changed
        }
    }

    /**
     * A pending optimistic response: its change set, applied again whenever
     * the layers are lifted and re-applied, and the undo log of what its last
     * application overwrote.
     */
    internal class OptimisticLayer(val changes: ChangeSet) {
        var undo: List<Undo> = emptyList()

        /** Adds the store's numbers the layer writes and its undo restores to [into]: kept while the layer is applied. */
        fun renderedSlots(into: MutableSet<Slot>) {
            for (index in 0 until changes.recordCount) {
                for (position in changes.starts[index] until changes.starts[index + 1]) {
                    val slot = changes.entrySlots[position]
                    if (slot < 0) into.add(Slot(changes.recordTypes[index], slot))
                }
            }
            for (entry in changes.fieldErrors) {
                if (entry.slotIndex < 0) into.add(Slot(changes.recordTypes[entry.record], entry.slotIndex))
            }
            for (step in undo) {
                when (step) {
                    is Undo.Write -> if (step.slot.index < 0) into.add(step.slot)
                    is Undo.Error -> if (step.slot.index < 0) into.add(step.slot)
                    is Undo.Deletion -> Unit
                }
            }
        }
    }

    /** The optimistic responses applied, oldest first. */
    internal val optimisticLayers = ArrayList<OptimisticLayer>()

    /**
     * Applies a change set from the server and reports how many slots of
     * records that existed before it changed. Under optimistic layers the
     * layers are lifted, the payload applied and the layers re-applied, and
     * only the net difference is notified; the server's answer to an
     * optimistic mutation, [replacing] its layer, removes the layer in that
     * same batch.
     */
    internal fun commit(changes: ChangeSet, replacing: OptimisticLayer? = null): Int {
        checkThread()
        if (ended) return 0
        adoptConstants()
        if (replacing == null && optimisticLayers.isEmpty()) {
            val batch = Batch(BatchKind.SERVER, direct = true)
            applyServer(changes, batch)
            return finish(batch).also { settleVerdictsIfNeeded() }
        }
        val batch = Batch(BatchKind.SERVER, direct = false)
        revertLayers(0, batch)
        if (replacing != null) optimisticLayers.remove(replacing)
        applyServer(changes, batch)
        reapplyLayers(0, batch)
        return finish(batch).also { settleVerdictsIfNeeded() }
    }

    /**
     * Applies a server's payload and hands the image what it changed, and
     * what it could not change in memory, for the image to forget. Under
     * optimistic layers it runs while they are lifted, so the image hears the
     * server's values.
     */
    private fun applyServer(changes: ChangeSet, batch: Batch) {
        val persistence = persistence
        if (persistence == null) {
            apply(changes, batch)
            return
        }
        val forgets = Forgets()
        this.forgets = forgets
        batch.persisted = LinkedHashSet()
        apply(changes, batch)
        this.forgets = null
        if (forgets.keys.isNotEmpty() || forgets.ids.isNotEmpty()) {
            persistence.forget(forgets.keys.toList(), forgets.ids.toList())
            forgotten.note(forgets.keys, forgets.ids)
        }
        // The records the payload wrote are the store's again, by their exact
        // keys; the others with a forgotten id stay unread until the writer
        // has dropped them.
        if (!forgotten.isEmpty) {
            for (index in 0 until changes.recordCount) forgotten.wrote(changes.recordKeys[index], changes.recordIDOffsets[index] >= 0)
        }
        persist(batch)
    }

    /** Whether the image's row of a record is not to be read. Once no forget waits for the writer, the rows are gone and nothing is forgotten. */
    internal fun forgotten(record: Record): Boolean {
        if (forgotten.isEmpty) return false
        if (persistence?.forgetting != true) {
            forgotten.clear()
            return false
        }
        return forgotten.contains(record)
    }

    /** Hands the image what a server's payload changed: a snapshot of every changed record, and the changed fields of the root one by one. */
    private fun persist(batch: Batch) {
        val persistence = persistence ?: return
        val changed = batch.persisted ?: return
        batch.persisted = null
        if (changed.isEmpty()) return
        val records = ArrayList<RecordSnapshot>()
        val fields = ArrayList<RootField>()
        for (step in changed) {
            val record = step.record
            if (record === mutationRoot || record === subscriptionRoot) continue
            val slot = step.slot
            if (slot != null) {
                fields.add(RootField(slot, root.peek(slot), root.peekError(slot)))
            } else {
                records.add(record.snapshot())
            }
        }
        if (records.isEmpty() && fields.isEmpty()) return
        persistence.committed(records, fields, keys)
    }

    /** Applies an optimistic response on top of everything else, as a layer a later commit rebases and a failure reverts. */
    internal fun applyOptimistic(changes: ChangeSet): OptimisticLayer {
        checkThread()
        val layer = OptimisticLayer(changes)
        if (ended) return layer
        adoptConstants()
        val batch = Batch(BatchKind.OPTIMISTIC, direct = false)
        apply(changes, batch)
        layer.undo = batch.undo.toList()
        optimisticLayers.add(layer)
        finish(batch)
        settleVerdictsIfNeeded()
        return layer
    }

    /** Removes an optimistic layer; the layers after it are re-applied over the gap. */
    internal fun revertOptimistic(layer: OptimisticLayer) {
        checkThread()
        val index = optimisticLayers.indexOf(layer)
        if (index < 0 || ended) return
        val batch = Batch(BatchKind.OPTIMISTIC, direct = false)
        revertLayers(index, batch)
        optimisticLayers.removeAt(index)
        reapplyLayers(index, batch)
        finish(batch)
        settleVerdictsIfNeeded()
    }

    /** Lifts the layers from [index] on, newest first, writing back what each overwrote. */
    private fun revertLayers(index: Int, batch: Batch) {
        batch.keepsUndo = false
        for (position in optimisticLayers.indices.reversed()) {
            if (position < index) break
            for (step in optimisticLayers[position].undo.asReversed()) {
                when (step) {
                    is Undo.Write -> {
                        val error = step.record.peekError(step.slot)
                        step.record.stage(step.slot, step.value)?.let { previous ->
                            batch.touched(step.record, step.slot, error, twin = false)
                            noteNulls(previous, step.value)
                        }
                    }
                    is Undo.Error -> setError(step.record, step.slot, step.error, batch)
                    is Undo.Deletion -> setDeleted(step.record, step.was, batch)
                }
            }
        }
        for (position in index until optimisticLayers.size) optimisticLayers[position].undo = emptyList()
        batch.keepsUndo = true
    }

    /** Applies the layers from [index] on again, oldest first, each keeping the undo log of this application. */
    private fun reapplyLayers(index: Int, batch: Batch) {
        for (position in index until optimisticLayers.size) {
            val start = batch.undo.size
            apply(optimisticLayers[position].changes, batch)
            optimisticLayers[position].undo = batch.steps(since = start)
        }
    }

    /**
     * Ends a batch: notifies the slots that changed, and when the batch
     * changed whether records are deleted, every slot that links to one of
     * them, since a link to a deleted record reads as null and a list skips
     * it; a pass is scheduled when a link moved or dropped; the log hears of
     * what the server and the app wrote. Returns how many slots changed.
     */
    private fun finish(batch: Batch): Int {
        if (linkDropped) {
            linkDropped = false
            scheduleCollection()
        }
        val changed = batch.finish()
        val flipped = batch.flipped()
        if (flipped.isNotEmpty()) {
            for (record in records.values) record.notifyLinks(flipped)
        }
        when (batch.kind) {
            BatchKind.SERVER -> log?.invoke(LogEvent.Committed(LogEvent.CommitKind.SERVER, changed))
            BatchKind.OPTIMISTIC -> log?.invoke(LogEvent.Committed(LogEvent.CommitKind.OPTIMISTIC, changed))
            // A local batch is the runtime's own writing, as frequent as a read walk.
            BatchKind.LOCAL -> Unit
        }
        return changed
    }

    /** Runs the runtime's own writes as one local batch: a lookup's link bound, a page's loading flag. */
    internal fun local(writes: (Batch) -> Unit) {
        val batch = Batch(BatchKind.LOCAL, direct = true)
        writes(batch)
        finish(batch)
    }

    /** Settles the roots' verdicts once a batch that changed a null, a link, an error or a deletion has notified. */
    private fun settleVerdictsIfNeeded() {
        if (!nullsOrErrorsChanged) return
        nullsOrErrorsChanged = false
        settleVerdicts()
    }

    /**
     * Ends the store, once and for good: the roots go, every record is
     * cleared and its readers told, the session's keys are forgotten, and
     * nothing is committed or reported after.
     */
    internal fun end() {
        checkThread()
        if (ended) return
        ended = true
        roots.clear()
        releaseBuffer.clear()
        completedMutations.clear()
        looseScopes.clear()
        inFlight.clear()
        optimisticLayers.clear()
        for (record in records.values) record.clear()
        records.clear()
        records[ROOT_KEY] = root
        records[MUTATION_ROOT_KEY] = mutationRoot
        records[SUBSCRIPTION_ROOT_KEY] = subscriptionRoot
        placeholders.clear()
        twins.clear()
        imageSlots.clear()
        hydratedRootSlots.clear()
        forgotten.clear()
        keys.clear()
        log = null
    }

    /** Marks everything fetched so far as stale; `Environment.invalidate()` is the public way, which also refetches. */
    internal fun invalidate() {
        if (ended) return
        invalidationEpoch += 1
        persistence?.invalidate()
    }

    /** Runs a pass on a later turn of the store's thread; several reasons in one turn run one pass. */
    internal fun scheduleCollection() {
        if (collectionScheduled || ended) return
        val scheduler = scheduler ?: return
        collectionScheduled = true
        scheduler {
            collectionScheduled = false
            if (!ended) collect()
        }
    }

    /**
     * Adopts the constants the build named after the store rendered their
     * texts: the two slots become twins, the records' values are copied
     * under the constant, and every later write to either lands in both.
     */
    internal fun adoptConstants() {
        for ((rendered, dense) in keys.takeAdoptions()) {
            twins[rendered] = dense
            twins[dense] = rendered
            for (record in records.values) {
                if (record.type == rendered.type) record.twin(rendered, dense)
            }
        }
    }

    /**
     * Removes every record not in [reachable] (the three roots stay), clears
     * their slots so links between them break, and drops the roots' links to
     * them. Returns how many records were removed.
     */
    internal fun sweep(reachable: Set<Record>): Int {
        val unreachable = ArrayList<String>()
        for ((key, record) in records) {
            if (key == ROOT_KEY || key == MUTATION_ROOT_KEY || key == SUBSCRIPTION_ROOT_KEY || record in reachable) continue
            unreachable.add(key)
        }
        val swept = HashSet<Record>()
        for (key in unreachable) {
            val record = records.remove(key) ?: continue
            swept.add(record)
            record.clear()
        }
        if (swept.isNotEmpty()) {
            root.prune(swept)
            mutationRoot.prune(swept)
            subscriptionRoot.prune(swept)
        }
        return swept.size
    }

    /** Adds every slot that has a twin, whose number the constant it was adopted for keeps, to [into]. */
    internal fun twinSlots(into: MutableSet<Slot>) {
        into.addAll(twins.keys)
    }

    /**
     * The placeholder record of a type: what a non-null link with no record
     * reads, every field missing, never among the store's records and never
     * written. See `spec/runtime.md`, section 1.
     */
    internal fun placeholder(type: TypeID): Record = placeholders.getOrPut(type) { Record(type, PLACEHOLDER_PREFIX + type.name) }

    /** Writes one slot inside a batch, and its twin when it has one, recorded for the batch's notification and its undo log. */
    internal fun set(record: Record, slot: Slot, value: Value, batch: Batch) {
        write(record, slot, value, batch, twin = false)
        val twin = twins[slot] ?: return
        write(record, twin, value, batch, twin = true)
    }

    private fun write(record: Record, slot: Slot, value: Value, batch: Batch, twin: Boolean) {
        val error = record.peekError(slot)
        val previous = (if (batch.direct) record.write(slot, value) else record.stage(slot, value)) ?: return
        batch.touched(record, slot, error, twin)
        batch.record(Undo.Write(record, slot, previous))
        batch.persist(record, slot, root)
        // A local write binds a link or sets a flag; it brings no new null or error into a selection.
        if (batch.kind != BatchKind.LOCAL) noteNulls(previous, value)
    }

    /** Sets or clears a slot's error inside a batch, and its twin's when it has one. */
    private fun setError(record: Record, slot: Slot, error: FieldError?, batch: Batch) {
        setOwnError(record, slot, error, batch, twin = false)
        val twin = twins[slot] ?: return
        setOwnError(record, twin, error, batch, twin = true)
    }

    private fun setOwnError(record: Record, slot: Slot, error: FieldError?, batch: Batch, twin: Boolean) {
        val previous = record.peekError(slot)
        if (!record.setError(slot, error, notifying = batch.direct)) return
        batch.touched(record, slot, previous, twin)
        batch.record(Undo.Error(record, slot, previous))
        batch.persist(record, slot, root)
        nullsOrErrorsChanged = true
    }

    /** Marks a record deleted or revives it inside a batch, recorded for the notification of what links to it and for the undo log. */
    private fun setDeleted(record: Record, deleted: Boolean, batch: Batch) {
        if (record.deleted == deleted) return
        if (!batch.flagged.containsKey(record)) batch.flagged[record] = record.deleted
        batch.record(Undo.Deletion(record, record.deleted))
        batch.persist(record, Slot(record.type, 0), root)
        record.setDeleted(deleted)
        nullsOrErrorsChanged = true
    }

    /** Notes for the batch a write to or from null, or a link that moved. */
    private fun noteNulls(previous: Value, value: Value) {
        when {
            previous is Value.Refs && value is Value.Refs -> {
                // A list that only grew, a page appended or prepended to a connection, left what it reached reachable.
                if (!keeps(previous.records, value.records)) linkDropped = true
                nullsOrErrorsChanged = true
            }
            previous is Value.Ref || previous is Value.Refs -> {
                // A link that moved, was nulled or was cleared may have left what it reached unreachable.
                linkDropped = true
                nullsOrErrorsChanged = true
            }
            previous == Value.Null || value == Value.Null -> nullsOrErrorsChanged = true
        }
    }

    /** Whether every link of [old] is still in [new], which a page appended or prepended leaves true: [old] is a prefix or a suffix of [new], by identity. */
    private fun keeps(old: List<Record?>, new: List<Record?>): Boolean {
        if (old.size > new.size) return false
        if (old.isEmpty()) return true
        var prefix = true
        var suffix = true
        val offset = new.size - old.size
        for (index in old.indices) {
            if (prefix && old[index] !== new[index]) prefix = false
            if (suffix && old[index] !== new[offset + index]) suffix = false
            if (!prefix && !suffix) return false
        }
        return true
    }

    private fun apply(changes: ChangeSet, batch: Batch) {
        // What the response said of types the build did not list; the image keeps it for the next launch.
        if (changes.memberships.isNotEmpty()) {
            for ((type, condition) in changes.memberships) Membership.learn(type, condition)
            persistence?.learned(changes.memberships.map { (type, condition) -> type.name to condition.name })
        }
        val objects = arrayOfNulls<Record>(changes.recordCount)
        val created = BooleanArray(changes.recordCount)
        for (index in 0 until changes.recordCount) {
            val (record, made) = record(changes.recordKeys[index], changes.recordTypes[index], changes.recordIDOffsets[index])
            objects[index] = record
            created[index] = made
        }

        // Slots this change set carries an error for keep it below rather than clearing it here.
        val erroring = HashSet<Pair<Int, Int>>()
        for (entry in changes.fieldErrors) erroring.add(entry.record to entry.slotIndex)

        val values = changes.values
        for (index in 0 until changes.recordCount) {
            val record = objects[index]!!
            // A deleted record a payload names again comes back.
            if (record.deleted) setDeleted(record, false, batch)
            for (position in changes.starts[index] until changes.starts[index + 1]) {
                val slot = Slot(record.type, changes.entrySlots[position])
                // A field the payload answers without an error has none, whether or not its value changed.
                if (record.hasErrors && record.peekError(slot) != null && (index to slot.index) !in erroring) {
                    setError(record, slot, null, batch)
                }
                val first = values.first[position]
                val second = values.second[position]
                val value: Value = when (values.kinds[position]) {
                    Raw.NULL -> Value.Null
                    Raw.BOOL -> if (first != 0L) Value.True else Value.False
                    Raw.INT -> Value.Int(first)
                    Raw.DOUBLE -> Value.Double(Double.fromBits(first))
                    Raw.STRING, Raw.ESCAPED_STRING -> {
                        val escaped = values.kinds[position] == Raw.ESCAPED_STRING
                        val existing = record.peek(slot)
                        if (existing is Value.String && changes.stringEquals(first.toInt(), second, escaped, existing.value)) continue
                        Value.String(changes.string(first.toInt(), second, escaped))
                    }
                    Raw.REF -> Value.Ref(objects[first.toInt()]!!)
                    Raw.REFS -> Value.Refs(List(second) { offset -> changes.refs[first.toInt() + offset].let { if (it < 0) null else objects[it] } })
                    else -> Value.List(List(second) { offset -> scalar(changes, first.toInt() + offset) })
                }
                if (created[index]) {
                    // Nobody can have read a record this batch made: its slots, and their twins, count among nothing changed.
                    record.write(slot, value)?.let { previous ->
                        batch.record(Undo.Write(record, slot, previous))
                        batch.persist(record, slot, root)
                        noteNulls(previous, value)
                    }
                    twins[slot]?.let { twin ->
                        record.write(twin, value)?.let { previous ->
                            batch.record(Undo.Write(record, twin, previous))
                            batch.persist(record, twin, root)
                        }
                    }
                } else {
                    set(record, slot, value, batch)
                }
            }
        }

        for (edit in changes.edits) {
            when (edit) {
                is ChangeSet.Edit.Merge -> merge(objects[edit.connection]!!, objects[edit.page]!!, edit.slots, edit.mode, batch)
                is ChangeSet.Edit.InsertEdge -> for (key in edit.connections) insertEdge(objects[edit.edge]!!, key, edit.prepend, batch)
                is ChangeSet.Edit.InsertNode -> for (key in edit.connections) insertNode(objects[edit.node]!!, edit.edgeType, key, edit.prepend, batch)
                is ChangeSet.Edit.DeleteEdge -> for (key in edit.connections) deleteEdges(edit.id, key, batch)
                is ChangeSet.Edit.DeleteRecord -> {
                    // The directive names a bare id: the record is the one live entity of any type with it.
                    val found = live(edit.id, Registry.typeNames())
                    // One memory does not hold may be in the image, which forgets every record with the id.
                    when (found.size) {
                        0 -> forgets?.ids?.add(edit.id)
                        1 -> delete(found[0], batch)
                        else -> log?.invoke(LogEvent.AmbiguousIdentity(edit.id, found.map { it.type.name }))
                    }
                }
            }
        }

        // Field errors land beside the field; an error arriving counts as a change of the slot.
        for (entry in changes.fieldErrors) {
            val record = objects[entry.record]!!
            setError(record, Slot(record.type, entry.slotIndex), entry.error, batch)
        }
    }

    private fun scalar(changes: ChangeSet, position: Int): Value {
        val scalars = changes.scalars
        val first = scalars.first[position]
        return when (scalars.kinds[position]) {
            Raw.BOOL -> if (first != 0L) Value.True else Value.False
            Raw.INT -> Value.Int(first)
            Raw.DOUBLE -> Value.Double(Double.fromBits(first))
            Raw.STRING -> Value.String(changes.string(first.toInt(), scalars.second[position], false))
            Raw.ESCAPED_STRING -> Value.String(changes.string(first.toInt(), scalars.second[position], true))
            else -> Value.Null
        }
    }

    /** Deletes a record: its values are cleared through the batch, and it is marked deleted, so links to it read as null and lists skip it. */
    private fun delete(record: Record, batch: Batch) {
        val slots = ArrayList<Slot>()
        record.forEachValue { slot, _ -> slots.add(slot) }
        for (slot in slots) set(record, slot, Value.Missing, batch)
        setDeleted(record, true, batch)
    }

    /** The live entities with this id among the named types. */
    private fun live(id: String, typeNames: List<String>): List<Record> =
        typeNames.mapNotNull { name -> records[Record.entityKey(name, id)]?.takeIf { !it.deleted } }

    // Connections: the merge of a page into its connection record and the edge directives' edits, where Relay keeps its connection handler.

    /**
     * The connection an edit may change: in memory, live, and holding what
     * the image has or more. One the store holds only as an empty record a
     * link made, or not at all, would be written back with the edit alone or
     * keep its old edges in the image: the image forgets it instead, so the
     * next read fetches it.
     */
    private fun editable(key: String): Pair<Record, ConnectionSlots>? {
        val connection = records[key]
        if (connection == null || connection.deleted || (connection.isEmpty && !connection.hydrated)) {
            forgets?.keys?.add(key)
            return null
        }
        val slots = Registry.connection(connection.type) ?: return null
        return connection to slots
    }

    private fun edges(record: Record, slot: Slot): List<Record?> = (record.peek(slot) as? Value.Refs)?.records ?: emptyList()

    private fun node(edge: Record, slot: Slot): Record? = (edge.peek(slot) as? Value.Ref)?.record

    /** Edges in order with every node at most once; null edges dropped. */
    private fun merged(first: List<Record?>, second: List<Record?>, nodeSlot: Slot): List<Record?> {
        val result = ArrayList<Record?>(first.size + second.size)
        val seen = HashSet<Record>()
        for (edge in first + second) {
            if (edge == null) continue
            val node = node(edge, nodeSlot)
            if (node != null && !seen.add(node)) continue
            result.add(edge)
        }
        return result
    }

    /**
     * Merges a page into its connection record as Relay's connection handler
     * does: the connection's own fields follow the page's; edges replace,
     * append or prepend by the cursor the page was fetched with,
     * deduplicated by node; the page info merges per direction. A page
     * fetched after a cursor that is no longer the end, or before one no
     * longer the start, is ignored.
     */
    private fun merge(connection: Record, page: Record, slots: ConnectionSlots, mode: ConnectionMode, batch: Batch) {
        val own = ArrayList<Pair<Slot, Value>>()
        page.forEachValue { slot, value ->
            if (slot.index != slots.edges.index && slot.index != slots.pageInfoLink.index) own.add(Slot(slots.connection, slot.index) to value)
        }
        for ((slot, value) in own) set(connection, slot, value, batch)

        val pageInfo = (connection.peek(slots.pageInfoLink) as? Value.Ref)?.record
            ?: recordFor(connection.key + ":pageInfo", slots.pageInfo, -1).also { set(connection, slots.pageInfoLink, Value.Ref(it), batch) }
        val existing = edges(connection, slots.edges)
        val incoming = edges(page, slots.edges)
        val edges: List<Record?>
        val copied: List<Slot>
        when (mode) {
            ConnectionMode.Replace -> {
                edges = merged(incoming, emptyList(), slots.node)
                copied = listOf(slots.hasNextPage, slots.hasPreviousPage, slots.startCursor, slots.endCursor)
            }
            is ConnectionMode.Append -> {
                val end = pageInfo.peek(slots.endCursor)
                if (mode.after != null && existing.isNotEmpty() && end is Value.String && end.value != mode.after) return
                edges = merged(existing, incoming, slots.node)
                copied = listOf(slots.hasNextPage, slots.endCursor)
            }
            is ConnectionMode.Prepend -> {
                val start = pageInfo.peek(slots.startCursor)
                if (mode.before != null && existing.isNotEmpty() && start is Value.String && start.value != mode.before) return
                edges = merged(incoming, existing, slots.node)
                copied = listOf(slots.hasPreviousPage, slots.startCursor)
            }
        }
        set(connection, slots.edges, Value.Refs(edges), batch)
        val serverPageInfo = (page.peek(slots.pageInfoLink) as? Value.Ref)?.record ?: return
        for (slot in copied) {
            val value = serverPageInfo.peek(slot)
            if (value == Value.Missing) continue
            set(pageInfo, slot, value, batch)
        }
    }

    /**
     * Inserts a copy of a payload's edge into a connection named by key,
     * unless an edge for the same node is there. The copy is the
     * connection's own record, as in Relay, since the payload's edge is keyed
     * by its path and the next mutation of the kind would alias it.
     */
    private fun insertEdge(edge: Record, connectionKey: String, prepend: Boolean, batch: Batch) {
        val (connection, slots) = editable(connectionKey) ?: return
        if (edge.type != slots.edge) return
        if (contains(connection, node(edge, slots.node), slots)) return
        val copy = ownEdge(connection, slots, batch)
        val values = ArrayList<Pair<Slot, Value>>()
        edge.forEachValue { slot, value -> values.add(Slot(slots.edge, slot.index) to value) }
        for ((slot, value) in values) set(copy, slot, value, batch)
        append(copy, connection, slots, prepend, batch)
    }

    /** Wraps a node in a new edge of the connection and inserts it, when the edge type the directive names is the connection's. */
    private fun insertNode(node: Record, edgeType: TypeID, connectionKey: String, prepend: Boolean, batch: Batch) {
        val (connection, slots) = editable(connectionKey) ?: return
        if (edgeType != slots.edge) return
        if (contains(connection, node, slots)) return
        val edge = ownEdge(connection, slots, batch)
        set(edge, slots.node, Value.Ref(node), batch)
        set(edge, slots.cursor, Value.Null, batch)
        append(edge, connection, slots, prepend, batch)
    }

    /** A new edge record the connection owns, numbered by Relay's `__connection_next_edge_index` client field. */
    private fun ownEdge(connection: Record, slots: ConnectionSlots, batch: Batch): Record {
        val index = (connection.peek(slots.nextEdgeIndex) as? Value.Int)?.value ?: 0L
        set(connection, slots.nextEdgeIndex, Value.Int(index + 1), batch)
        return recordFor(connection.key + ":edges:" + index, slots.edge, -1)
    }

    private fun contains(connection: Record, node: Record?, slots: ConnectionSlots): Boolean {
        if (node == null) return false
        return edges(connection, slots.edges).any { edge -> edge != null && node(edge, slots.node) === node }
    }

    private fun append(edge: Record, connection: Record, slots: ConnectionSlots, prepend: Boolean, batch: Batch) {
        val edges = edges(connection, slots.edges)
        set(connection, slots.edges, Value.Refs(if (prepend) listOf(edge) + edges else edges + edge), batch)
    }

    /** Removes every edge whose node is an entity with this id, of whatever type, from a connection named by key. */
    private fun deleteEdges(id: String, connectionKey: String, batch: Batch) {
        val (connection, slots) = editable(connectionKey) ?: return
        val edges = edges(connection, slots.edges)
        val kept = edges.filter { edge -> edge == null || node(edge, slots.node)?.hasID(id) != true }
        if (kept.size == edges.size) return
        set(connection, slots.edges, Value.Refs(kept), batch)
    }

    /**
     * The record and selection a response path names, from the root: for an
     * incremental part's `path`. Null when the path leads through data the
     * store never received.
     */
    internal fun walk(path: List<PathSegment>, selection: ResolvedSelection, from: Record = root): Pair<Record, ResolvedSelection>? {
        checkThread()
        var record = from
        var current = selection
        var position = 0
        while (position < path.size) {
            val segment = path[position] as? PathSegment.Name ?: return null
            position += 1
            val field = current.variant(record.type).field(segment.name) ?: return null
            val kind = field.kind as? ResolvedField.Kind.Linked ?: return null
            record = when (val value = record.peek(field.slot)) {
                is Value.Ref -> value.record
                is Value.Refs -> {
                    val index = path.getOrNull(position) as? PathSegment.Index ?: return null
                    position += 1
                    value.records.getOrNull(index.index) ?: return null
                }
                else -> return null
            }
            current = kind.selection
        }
        return record to current
    }

    internal companion object {
        const val ROOT_KEY = "client:root"
        const val MUTATION_ROOT_KEY = "client:root:mutation"
        const val SUBSCRIPTION_ROOT_KEY = "client:root:subscription"
        const val PLACEHOLDER_PREFIX = "client:placeholder:"

        /** The key of the root a response of the operation kind is committed under. */
        fun rootKey(kind: OperationKind): String = when (kind) {
            OperationKind.QUERY -> ROOT_KEY
            OperationKind.MUTATION -> MUTATION_ROOT_KEY
            OperationKind.SUBSCRIPTION -> SUBSCRIPTION_ROOT_KEY
        }

        /** The key of an operation's root: its name and its variables as JSON, which names the root in the store and the handle in the environment. */
        fun rootKey(name: String, variables: Variables): String = name + variables.json
    }
}

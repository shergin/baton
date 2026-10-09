package baton

import androidx.compose.runtime.Stable

/**
 * A view of one record through one selection: generated code's accessors
 * read the store through the anchor at each access, so a read in composition
 * registers the slot and a write invalidates its readers alone. Equal by
 * anchor. See `spec/runtime.md`, section 6.
 */
@Stable
interface Lens {
    @Generated
    val anchor: Anchor

    /** The identity of the record the lens reads, for a list's key. */
    val recordID: RecordID get() = RecordID(anchor.record.key)
}

/** A record's identity across reads: its key. */
@JvmInline
value class RecordID(val key: String)

/**
 * A plural link: lenses over the linked records, in order. Null elements,
 * deleted records and elements the caller rejects (a `@required` field of
 * theirs is null) are dropped. A nullable list reads as `List?`, since the
 * server's null and its empty list differ; `empty()` is the value a view
 * substitutes when it does not care.
 */
@Stable
class LensList<Element : Lens> @Generated constructor(
    private val anchors: List<Anchor>,
    private val build: (Anchor) -> Element,
) : AbstractList<Element>() {
    override val size: Int get() = anchors.size
    override fun get(index: Int): Element = build(anchors[index])

    companion object {
        fun <Element : Lens> empty(): LensList<Element> = LensList(emptyList()) { throw IndexOutOfBoundsException() }
    }
}

/**
 * Where a lens stands: the record it reads and the owner whose variables and
 * store it reads under. Its readers, one per field shape, are the runtime's
 * contract with generated code: a scalar reads as its value or null, a
 * `required` reader as a zero value where a value is missing, a link as the
 * record behind it, a list as lenses over the linked records; the honest-data
 * readers carry `@required`, `@catch`, `@throwOnFieldError` and `@defer`; the
 * connection readers read a connection's state and fetch its pages. Each is
 * read on the store's thread.
 *
 * An anchor also carries its origin, the record the enclosing fragment starts
 * at, whose id a connection's pagination and a refetch pass to the fragment's
 * query; none at an operation's root. Two anchors are equal when the record,
 * the owner and the origin are the same objects.
 */
@Stable
class Anchor @Generated constructor(val record: Record, val owner: Owner) {
    /** The record the enclosing fragment starts at; null at an operation's root, where no fragment has been entered. */
    internal var origin: Record? = null
        private set

    internal constructor(record: Record, owner: Owner, origin: Record?) : this(record, owner) {
        this.origin = origin
    }

    val variables: Variables get() = owner.variables

    private val store: Store? get() = owner.store

    /** The anchor of a record this one links to: the same scope and origin. */
    private fun child(target: Record): Anchor = Anchor(target, owner, origin)

    /** The anchor a fragment spread reads through: the same record and scope, with this record as the fragment's own. */
    @Generated
    fun entering(): Anchor = Anchor(record, owner, record)

    /** The anchor a spread with `@arguments` reads through. */
    @Generated
    fun binding(site: ArgumentSite, values: () -> Map<String, Variable?>): Anchor = Anchor(record, owner.binding(site, values), origin)

    /** The slot's value, read on the store's thread through its channel, so a read in composition registers the slot. */
    private fun load(slot: Slot): Value {
        store?.checkThread()
        return record.read(slot)
    }

    /**
     * Reports a slot the store never received. A deleted record's fields are
     * gone on purpose; a client field is absent until a payload writes it;
     * a placeholder's link reported already. The owner's environment is
     * asked to heal: mark the operation stale and refetch it.
     */
    private fun missing(slot: Slot) {
        if (record.deleted || !owner.reports || Registry.isClient(slot)) return
        val store = store ?: return
        store.log?.invoke(LogEvent.Missing(record.type.name, store.keys.text(slot)))
        owner.environment?.heal(owner.root, record, slot)
    }

    /** Reports a value the reader's type cannot hold: a null in a non-null field, or a value of another kind. */
    private fun unexpected(slot: Slot) {
        if (!owner.reports) return
        val store = store ?: return
        store.log?.invoke(LogEvent.Unexpected(record.type.name, store.keys.text(slot)))
    }

    /**
     * A scalar read through [transform], the element's reader: null and the
     * value reported where it is missing, null where the server sent null
     * (reported when the field is non-null), null and reported where the
     * transform cannot hold it.
     */
    private inline fun <T : Any> scalar(slot: Slot, nonNull: Boolean, transform: (Value) -> T?): T? {
        when (val value = load(slot)) {
            Value.Null -> if (nonNull) unexpected(slot)
            Value.Missing -> missing(slot)
            else -> transform(value)?.let { return it } ?: unexpected(slot)
        }
        return null
    }

    // Scalars. A `required` reader returns a zero value where a value is missing or null.

    @Generated fun string(slot: Slot): String? = scalar(slot, nonNull = false, ::text)
    @Generated fun requiredString(slot: Slot): String = scalar(slot, nonNull = true, ::text) ?: ""
    @Generated fun int(slot: Slot): Int? = scalar(slot, nonNull = false, ::integer)
    @Generated fun requiredInt(slot: Slot): Int = scalar(slot, nonNull = true, ::integer) ?: 0
    @Generated fun double(slot: Slot): Double? = scalar(slot, nonNull = false, ::float)
    @Generated fun requiredDouble(slot: Slot): Double = scalar(slot, nonNull = true, ::float) ?: 0.0
    @Generated fun bool(slot: Slot): Boolean? = scalar(slot, nonNull = false, ::boolean)
    @Generated fun requiredBool(slot: Slot): Boolean = scalar(slot, nonNull = true, ::boolean) ?: false

    // Mapped scalars, through the converter the configuration names, and enums, through the generated `of`.
    // A text the type cannot hold is reported as unexpected, never as missing, and reads as null.

    /**
     * A mapped scalar: the stored text converted to the type the field reads
     * as. A text the type cannot hold is reported as unexpected, never as
     * missing, which the heal would refetch forever, and reads as null.
     */
    @Generated fun <T : Any> mapped(slot: Slot, converter: ScalarConverter<T>): T? {
        val text = string(slot) ?: return null
        return converter.parse(text) ?: run {
            unexpected(slot)
            null
        }
    }

    /**
     * `@required(action: THROW)` or `@throwOnFieldError` on a mapped scalar:
     * the value, or the field's error, or the conversion's. A failure has no
     * zero to read as, so the accessor throws where a scalar's would read one.
     */
    @Generated fun <T : Any> throwingMapped(slot: Slot, path: String, converter: ScalarConverter<T>): T {
        record.error(slot)?.let { throw FieldErrors(listOf(it)) }
        when (load(slot)) {
            Value.Missing -> {
                missing(slot)
                throw RequiredFieldError(path)
            }
            Value.Null -> throw RequiredFieldError(path)
            else -> return mapped(slot, converter) ?: throw FieldErrors(listOf(FieldError.conversion(path, converter)))
        }
    }

    /** `@catch` on a non-null mapped scalar: the value, or the field's error, or the conversion's. */
    @Generated fun <T : Any> caughtMapped(slot: Slot, path: String, converter: ScalarConverter<T>): Result<T> {
        record.error(slot)?.let { return Result.failure(FieldErrors(listOf(it))) }
        val text = scalar(slot, nonNull = true, ::text) ?: return Result.failure(FieldErrors(listOf(FieldError.nullValue(path))))
        val value = converter.parse(text) ?: run {
            unexpected(slot)
            return Result.failure(FieldErrors(listOf(FieldError.conversion(path, converter))))
        }
        return Result.success(value)
    }

    /** `@catch` on a nullable mapped scalar: a null reads as null; a text that does not convert is the failure. */
    @Generated fun <T : Any> caughtOptionalMapped(slot: Slot, path: String, converter: ScalarConverter<T>): Result<T?> {
        record.error(slot)?.let { return Result.failure(FieldErrors(listOf(it))) }
        val text = string(slot) ?: return Result.success(null)
        val value = converter.parse(text) ?: run {
            unexpected(slot)
            return Result.failure(FieldErrors(listOf(FieldError.conversion(path, converter))))
        }
        return Result.success(value)
    }

    /**
     * Whether a `@required` mapped scalar has a value that converts, for
     * `satisfied`: a text the type cannot hold leaves the lens unsatisfied
     * as a null would, and is reported as unexpected.
     */
    @Generated fun <T : Any> converts(slot: Slot, converter: ScalarConverter<T>, path: String, log: Boolean): Boolean {
        if (!hasValue(slot, path, log)) return false
        val text = string(slot)
        if (text != null && converter.parse(text) != null) return true
        unexpected(slot)
        return requiredMissing(path, log)
    }

    /** Appends the conversion's error when a mapped scalar's text does not convert, for an error policy to handle. */
    @Generated fun <T : Any> collectConversion(slot: Slot, converter: ScalarConverter<T>, path: String, into: MutableList<FieldError>) {
        val text = string(slot) ?: return
        if (converter.parse(text) != null) return
        into.add(FieldError.conversion(path, converter))
    }

    // Lists of a mapped scalar. An element that does not convert is reported once; a list of non-null elements
    // leaves it out, and a list of nullable elements reads it as null.

    @Generated fun <T : Any> mappedList(slot: Slot, converter: ScalarConverter<T>): List<T>? =
        scalars(slot, nonNull = false) { converted(it, converter) }
    @Generated fun <T : Any> requiredMappedList(slot: Slot, converter: ScalarConverter<T>): List<T> =
        scalars(slot, nonNull = true) { converted(it, converter) } ?: emptyList()
    @Generated fun <T : Any> nullableMappedList(slot: Slot, converter: ScalarConverter<T>): List<T?>? =
        nullableScalars(slot, nonNull = false) { converted(it, converter) }
    @Generated fun <T : Any> requiredNullableMappedList(slot: Slot, converter: ScalarConverter<T>): List<T?> =
        nullableScalars(slot, nonNull = true) { converted(it, converter) } ?: emptyList()

    /**
     * A schema enum, as the type generated for it; a value this build does
     * not know is its `Undeclared`. A null on a non-null enum reads as the
     * undeclared value with an empty text and is reported.
     */
    @Generated fun <T : GeneratedEnum> enumValue(slot: Slot, of: (String) -> T): T? = string(slot)?.let(of)
    @Generated fun <T : GeneratedEnum> requiredEnumValue(slot: Slot, of: (String) -> T): T = of(requiredString(slot))
    @Generated fun <T : GeneratedEnum> enumValues(slot: Slot, of: (String) -> T): List<T>? =
        scalars(slot, nonNull = false) { (it as? Value.String)?.value?.let(of) }
    @Generated fun <T : GeneratedEnum> requiredEnumValues(slot: Slot, of: (String) -> T): List<T> =
        scalars(slot, nonNull = true) { (it as? Value.String)?.value?.let(of) } ?: emptyList()
    @Generated fun <T : GeneratedEnum> nullableEnumValues(slot: Slot, of: (String) -> T): List<T?>? =
        nullableScalars(slot, nonNull = false) { (it as? Value.String)?.value?.let(of) }
    @Generated fun <T : GeneratedEnum> requiredNullableEnumValues(slot: Slot, of: (String) -> T): List<T?> =
        nullableScalars(slot, nonNull = true) { (it as? Value.String)?.value?.let(of) } ?: emptyList()

    // Lists of scalars: an element a non-null list cannot hold is reported once and left out; a nullable list reads it as null.
    // An element reads as the scalar of its type does.

    @Generated fun strings(slot: Slot): List<String>? = scalars(slot, nonNull = false, ::text)
    @Generated fun requiredStrings(slot: Slot): List<String> = scalars(slot, nonNull = true, ::text) ?: emptyList()
    @Generated fun ints(slot: Slot): List<Int>? = scalars(slot, nonNull = false, ::integer)
    @Generated fun requiredInts(slot: Slot): List<Int> = scalars(slot, nonNull = true, ::integer) ?: emptyList()
    @Generated fun doubles(slot: Slot): List<Double>? = scalars(slot, nonNull = false, ::float)
    @Generated fun requiredDoubles(slot: Slot): List<Double> = scalars(slot, nonNull = true, ::float) ?: emptyList()
    @Generated fun bools(slot: Slot): List<Boolean>? = scalars(slot, nonNull = false, ::boolean)
    @Generated fun requiredBools(slot: Slot): List<Boolean> = scalars(slot, nonNull = true, ::boolean) ?: emptyList()
    @Generated fun nullableStrings(slot: Slot): List<String?>? = nullableScalars(slot, nonNull = false, ::text)
    @Generated fun requiredNullableStrings(slot: Slot): List<String?> = nullableScalars(slot, nonNull = true, ::text) ?: emptyList()
    @Generated fun nullableInts(slot: Slot): List<Int?>? = nullableScalars(slot, nonNull = false, ::integer)
    @Generated fun requiredNullableInts(slot: Slot): List<Int?> = nullableScalars(slot, nonNull = true, ::integer) ?: emptyList()
    @Generated fun nullableDoubles(slot: Slot): List<Double?>? = nullableScalars(slot, nonNull = false, ::float)
    @Generated fun requiredNullableDoubles(slot: Slot): List<Double?> = nullableScalars(slot, nonNull = true, ::float) ?: emptyList()
    @Generated fun nullableBools(slot: Slot): List<Boolean?>? = nullableScalars(slot, nonNull = false, ::boolean)
    @Generated fun requiredNullableBools(slot: Slot): List<Boolean?> = nullableScalars(slot, nonNull = true, ::boolean) ?: emptyList()

    /** A list of scalars the schema types non-null: an element the list cannot hold, a null or a value of another kind, is reported once and left out. */
    private inline fun <T : Any> scalars(slot: Slot, nonNull: Boolean, transform: (Value) -> T?): List<T>? {
        when (val value = load(slot)) {
            is Value.List -> {
                val items = ArrayList<T>(value.values.size)
                var reported = false
                for (element in value.values) {
                    val item = transform(element)
                    if (item != null) {
                        items.add(item)
                    } else if (!reported) {
                        unexpected(slot)
                        reported = true
                    }
                }
                return items
            }
            Value.Null -> if (nonNull) unexpected(slot)
            Value.Missing -> missing(slot)
            else -> unexpected(slot)
        }
        return null
    }

    /** A list of scalars the schema types nullable: a null element reads as null; a value it cannot hold is reported once and reads as null. */
    private inline fun <T : Any> nullableScalars(slot: Slot, nonNull: Boolean, transform: (Value) -> T?): List<T?>? {
        when (val value = load(slot)) {
            is Value.List -> {
                val items = ArrayList<T?>(value.values.size)
                var reported = false
                for (element in value.values) {
                    if (element == Value.Null) {
                        items.add(null)
                        continue
                    }
                    val item = transform(element)
                    if (item == null && !reported) {
                        unexpected(slot)
                        reported = true
                    }
                    items.add(item)
                }
                return items
            }
            Value.Null -> if (nonNull) unexpected(slot)
            Value.Missing -> missing(slot)
            else -> unexpected(slot)
        }
        return null
    }

    // Links. A deleted record reads as null; a non-null link with no record reads the type's placeholder, reported once.

    /** The record behind a singular link. A deleted record reads as null. A lookup was bound by the availability check, so a read never writes. */
    @Generated fun linked(slot: Slot): Anchor? {
        when (val value = load(slot)) {
            is Value.Ref -> return if (value.record.deleted) null else child(value.record)
            Value.Null -> Unit
            Value.Missing -> missing(slot)
            else -> unexpected(slot)
        }
        return null
    }

    /**
     * A non-null link. When it has no record, missing or null, the type's
     * placeholder stands in, read under an owner that reports nothing, so
     * the reads below yield zero values and the link alone is reported. A
     * deleted record reads the placeholder unreported.
     */
    @Generated fun requiredLinked(slot: Slot, type: TypeID): Anchor {
        when (val value = load(slot)) {
            is Value.Ref -> if (!value.record.deleted) return child(value.record)
            Value.Missing -> missing(slot)
            else -> unexpected(slot)
        }
        val placeholder = store?.placeholder(type) ?: Record(type, Store.PLACEHOLDER_PREFIX + type.name)
        return Anchor(placeholder, owner.inert)
    }

    /** A plural link. Elements that `keep` rejects are dropped, as Relay nulls a list item whose `@required` field is null. */
    @Generated fun <Element : Lens> list(slot: Slot, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): LensList<Element>? =
        list(slot, nonNull = false, build, keep)

    @Generated fun <Element : Lens> requiredList(slot: Slot, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): LensList<Element> =
        list(slot, nonNull = true, build, keep) ?: LensList(emptyList(), build)

    private fun <Element : Lens> list(slot: Slot, nonNull: Boolean, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)?): LensList<Element>? {
        when (val value = load(slot)) {
            is Value.Refs -> {
                val anchors = ArrayList<Anchor>(value.records.size)
                for (target in value.records) {
                    if (target == null || target.deleted) continue
                    val anchor = child(target)
                    if (keep != null && !keep(anchor)) continue
                    anchors.add(anchor)
                }
                return LensList(anchors, build)
            }
            Value.Null -> if (nonNull) unexpected(slot)
            Value.Missing -> missing(slot)
            else -> unexpected(slot)
        }
        return null
    }

    /**
     * A plural link read out as values, for an `@inline` fragment: `build`
     * runs once per linked record, in order, at the read. Null elements and
     * deleted records are dropped, as a `LensList` drops them.
     */
    @Generated fun <Element> values(slot: Slot, build: (Anchor) -> Element): List<Element>? = values(slot, nonNull = false, build)

    @Generated fun <Element> requiredValues(slot: Slot, build: (Anchor) -> Element): List<Element> = values(slot, nonNull = true, build) ?: emptyList()

    private fun <Element> values(slot: Slot, nonNull: Boolean, build: (Anchor) -> Element): List<Element>? {
        when (val value = load(slot)) {
            is Value.Refs -> {
                val elements = ArrayList<Element>(value.records.size)
                for (target in value.records) {
                    if (target == null || target.deleted) continue
                    elements.add(build(child(target)))
                }
                return elements
            }
            Value.Null -> if (nonNull) unexpected(slot)
            Value.Missing -> missing(slot)
            else -> unexpected(slot)
        }
        return null
    }

    // Honest data: `@required`, `@catch`, `@throwOnFieldError` and `@defer`. Field errors live beside the field
    // they name; a required field that is null bubbles, logs or throws as the directive says; a deferred fragment
    // is present once its fields are.

    /** Whether a `@required` field is present. When it is not and the action is LOG, the environment's log is told. */
    @Generated fun hasValue(slot: Slot, path: String, log: Boolean): Boolean {
        when (val value = load(slot)) {
            Value.Missing -> {
                missing(slot)
                return requiredMissing(path, log)
            }
            Value.Null -> return requiredMissing(path, log)
            // A link to a deleted record reads as null, so it is null here too.
            is Value.Ref -> if (value.record.deleted) return requiredMissing(path, log)
            else -> Unit
        }
        return true
    }

    /** Reports a `@required(action: LOG)` field that is null, unless a placeholder holds it, whose link reported already; always false, so a guard can return it. */
    @Generated fun requiredMissing(path: String, log: Boolean): Boolean {
        if (log && owner.reports) store?.log?.invoke(LogEvent.RequiredFieldMissing(record.type.name, path))
        return false
    }

    /** Whether the field has arrived, for a deferred fragment's presence. */
    @Generated fun present(slot: Slot): Boolean = load(slot) != Value.Missing

    /** `@required(action: THROW)` on a scalar: the value, or the field's error, or `RequiredFieldError` when null. */
    @Generated fun <T : Any> throwing(slot: Slot, path: String, read: (Anchor) -> T?): T {
        record.error(slot)?.let { throw FieldErrors(listOf(it)) }
        return read(this) ?: throw RequiredFieldError(path)
    }

    /** `@required(action: THROW)` on a link: the linked record, satisfied, or the field's error, or `RequiredFieldError`. */
    @Generated fun throwingLinked(slot: Slot, path: String, satisfied: (Anchor) -> Boolean): Anchor {
        record.error(slot)?.let { throw FieldErrors(listOf(it)) }
        val target = linked(slot)
        if (target == null || !satisfied(target)) throw RequiredFieldError(path)
        return target
    }

    /** `@required(action: THROW)` on a plural link. */
    @Generated fun <Element : Lens> throwingList(slot: Slot, path: String, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): LensList<Element> {
        record.error(slot)?.let { throw FieldErrors(listOf(it)) }
        return list(slot, build, keep) ?: throw RequiredFieldError(path)
    }

    /** `@catch` on a scalar: the value, or the field's error. */
    @Generated fun <T> caught(slot: Slot, read: (Anchor) -> T): Result<T> {
        record.error(slot)?.let { return Result.failure(FieldErrors(listOf(it))) }
        return Result.success(read(this))
    }

    /** `@catch` on a link: the lens, or the field's error and every error inside the linked selection. */
    @Generated fun <T> caught(slot: Slot, within: (Anchor) -> List<FieldError>, read: (Anchor) -> T): Result<T> {
        val errors = ArrayList<FieldError>()
        collectErrors(slot, within, errors)
        if (errors.isNotEmpty()) return Result.failure(FieldErrors(errors))
        return Result.success(read(this))
    }

    /** `@catch` on a plural link. */
    @Generated fun <Element : Lens> caughtList(slot: Slot, within: (Anchor) -> List<FieldError>, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): Result<LensList<Element>?> {
        val errors = ArrayList<FieldError>()
        collectListErrors(slot, within, errors)
        if (errors.isNotEmpty()) return Result.failure(FieldErrors(errors))
        return Result.success(list(slot, build, keep))
    }

    @Generated fun <Element : Lens> caughtRequiredList(slot: Slot, within: (Anchor) -> List<FieldError>, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): Result<LensList<Element>> {
        val errors = ArrayList<FieldError>()
        collectListErrors(slot, within, errors)
        if (errors.isNotEmpty()) return Result.failure(FieldErrors(errors))
        return Result.success(requiredList(slot, build, keep))
    }

    /** `@catch` on a plural link read out as values. */
    @Generated fun <Element> caughtValues(slot: Slot, within: (Anchor) -> List<FieldError>, build: (Anchor) -> Element): Result<List<Element>?> {
        val errors = ArrayList<FieldError>()
        collectListErrors(slot, within, errors)
        if (errors.isNotEmpty()) return Result.failure(FieldErrors(errors))
        return Result.success(values(slot, build))
    }

    @Generated fun <Element> caughtRequiredValues(slot: Slot, within: (Anchor) -> List<FieldError>, build: (Anchor) -> Element): Result<List<Element>> {
        val errors = ArrayList<FieldError>()
        collectListErrors(slot, within, errors)
        if (errors.isNotEmpty()) return Result.failure(FieldErrors(errors))
        return Result.success(requiredValues(slot, build))
    }

    /** Appends the field's own error, if any. */
    @Generated fun collectError(slot: Slot, into: MutableList<FieldError>) {
        store?.checkThread()
        record.error(slot)?.let { into.add(it) }
    }

    /** Appends the error a `@required(action: THROW)` field raises when null. */
    @Generated fun collectRequired(slot: Slot, path: String, into: MutableList<FieldError>) {
        when (val value = load(slot)) {
            Value.Missing -> {
                missing(slot)
                into.add(FieldError.required(path))
            }
            Value.Null -> into.add(FieldError.required(path))
            is Value.Ref -> if (value.record.deleted) into.add(FieldError.required(path))
            else -> Unit
        }
    }

    /** Appends the field's own error and the errors inside the linked record. */
    @Generated fun collectErrors(slot: Slot, within: (Anchor) -> List<FieldError>, into: MutableList<FieldError>) {
        collectError(slot, into)
        val value = record.read(slot)
        if (value is Value.Ref && !value.record.deleted) into.addAll(within(child(value.record)))
    }

    /** Appends the field's own error and the errors inside every linked record. */
    @Generated fun collectListErrors(slot: Slot, within: (Anchor) -> List<FieldError>, into: MutableList<FieldError>) {
        collectError(slot, into)
        val value = record.read(slot) as? Value.Refs ?: return
        for (target in value.records) {
            if (target == null || target.deleted) continue
            into.addAll(within(child(target)))
        }
    }

    // Connections: the state Relay keeps on the connection record, and the fetches that extend or refresh it. The
    // anchor's record is the connection record; its origin is the fragment's, whose id the fragment's query takes.

    private fun pageInfo(slots: ConnectionSlots): Record? = (load(slots.pageInfoLink) as? Value.Ref)?.record

    private fun flag(record: Record?, slot: Slot): Boolean = (record?.read(slot) as? Value.Bool)?.value ?: false

    /** The edges' nodes, in order, without null edges, null nodes, deleted records or nodes that `keep` rejects. */
    @Generated fun <Element : Lens> nodes(slots: ConnectionSlots, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): List<Element> {
        val edges = load(slots.edges) as? Value.Refs ?: return emptyList()
        val nodes = ArrayList<Element>(edges.records.size)
        for (edge in edges.records) {
            if (edge == null || edge.deleted) continue
            val node = (edge.read(slots.node) as? Value.Ref)?.record ?: continue
            if (node.deleted) continue
            val anchor = child(node)
            if (keep != null && !keep(anchor)) continue
            nodes.add(build(anchor))
        }
        return nodes
    }

    @Generated fun hasNext(slots: ConnectionSlots): Boolean = flag(pageInfo(slots), slots.hasNextPage)
    @Generated fun hasPrevious(slots: ConnectionSlots): Boolean = flag(pageInfo(slots), slots.hasPreviousPage)
    @Generated fun isLoadingNext(slots: ConnectionSlots): Boolean = flag(record.also { store?.checkThread() }, slots.isLoadingNext)
    @Generated fun isLoadingPrevious(slots: ConnectionSlots): Boolean = flag(record.also { store?.checkThread() }, slots.isLoadingPrevious)

    /**
     * Fetches the next [count] edges with the fragment's refetch query, after
     * the merged end cursor; the commit appends them. A no-op while a page is
     * loading or when there is no next page; a lens made by hand, with no
     * environment, throws `EnvironmentError.OutsideEnvironment`.
     */
    @Generated suspend fun loadNext(operation: OperationType<*>, slots: ConnectionSlots, refetch: Refetch, count: Int) {
        val first = refetch.first ?: return
        val after = refetch.after ?: return
        if (!hasNext(slots) || isLoadingNext(slots)) return
        val cursor = (pageInfo(slots)?.peek(slots.endCursor) as? Value.String)?.value ?: return
        val values = refetchVariables(refetch, origin ?: record)
        values[first] = Variable.Int(count.toLong())
        values[after] = Variable.String(cursor)
        environment().paginate(operation, Variables(values), record, slots.isLoadingNext)
    }

    /** Fetches the previous [count] edges before the merged start cursor; the commit prepends them. A no-op while a page is loading or when there is no previous page. */
    @Generated suspend fun loadPrevious(operation: OperationType<*>, slots: ConnectionSlots, refetch: Refetch, count: Int) {
        val last = refetch.last ?: return
        val before = refetch.before ?: return
        if (!hasPrevious(slots) || isLoadingPrevious(slots)) return
        val cursor = (pageInfo(slots)?.peek(slots.startCursor) as? Value.String)?.value ?: return
        val values = refetchVariables(refetch, origin ?: record)
        values[last] = Variable.Int(count.toLong())
        values[before] = Variable.String(cursor)
        environment().paginate(operation, Variables(values), record, slots.isLoadingPrevious)
    }

    /** Fetches the fragment again with the lens's variables and its record's id; the records update in place. */
    @Generated suspend fun refetch(operation: OperationType<*>, refetch: Refetch) {
        environment().fetch(operation, Variables(refetchVariables(refetch, record)))
    }

    /** The refetch query's variables: the lens's scope filtered to the query's definitions, plus the id of [owner], the fragment's record. */
    private fun refetchVariables(refetch: Refetch, owner: Record?): HashMap<String, Variable> {
        val values = HashMap<String, Variable>()
        for ((name, value) in variables.values) if (name in refetch.variables) values[name] = value
        val identifier = refetch.identifier ?: return values
        if (owner == null) return values
        // The id is read from the slot the query names, where the key was built from; the key's own text is the fallback.
        when (val id = refetch.identity?.let { owner.peek(it) }) {
            is Value.String -> values[identifier] = Variable.String(id.value)
            is Value.Int -> values[identifier] = Variable.Int(id.value)
            else -> owner.entityID?.let { values[identifier] = Variable.String(it) }
        }
        return values
    }

    /** The environment the lens fetches through: its owner's, which a lens made by hand has none of. */
    private fun environment(): Environment = owner.environment ?: throw EnvironmentError.OutsideEnvironment

    override fun equals(other: Any?): Boolean =
        other is Anchor && other.record === record && other.owner === owner && other.origin === origin

    override fun hashCode(): Int = (record.hashCode() * 31 + owner.hashCode()) * 31 + (origin?.hashCode() ?: 0)

    private companion object {
        /** A stored scalar as a string reads it: a string, or a number or a boolean as its text. */
        fun text(value: Value): String? = when (value) {
            is Value.String -> value.value
            is Value.Int -> value.value.toString()
            is Value.Double -> Variable.renderDouble(value.value)
            is Value.Bool -> if (value.value) "true" else "false"
            else -> null
        }

        /** A stored scalar as an int reads it: an int in range, or a float that is a whole number in range. */
        fun integer(value: Value): Int? = when (value) {
            is Value.Int -> if (value.value in Int.MIN_VALUE..Int.MAX_VALUE) value.value.toInt() else null
            is Value.Double -> {
                val double = value.value
                if (double % 1.0 == 0.0 && double >= Int.MIN_VALUE && double <= Int.MAX_VALUE) double.toInt() else null
            }
            else -> null
        }

        /** A stored scalar as a float reads it: a float, or an int. */
        fun float(value: Value): Double? = when (value) {
            is Value.Double -> value.value
            is Value.Int -> value.value.toDouble()
            else -> null
        }

        fun boolean(value: Value): Boolean? = (value as? Value.Bool)?.value

        /** A stored scalar as its text, converted; null for a value of another kind or one the type cannot hold. */
        fun <T : Any> converted(value: Value, converter: ScalarConverter<T>): T? = text(value)?.let(converter::parse)
    }
}

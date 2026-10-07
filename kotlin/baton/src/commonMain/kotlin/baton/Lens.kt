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

/** A spread site that passes `@arguments`, by identity, so one lens binds its fragment's arguments once per site. */
@Generated
class ArgumentSite

/**
 * The scope a lens reads under: the operation's variables, the store it
 * reads, the environment that can fetch for it (none for a lens made by
 * hand), and the root the operation's data hangs off. A spread with
 * `@arguments` binds a child owner with the fragment's variables.
 */
class Owner internal constructor(val variables: Variables) {
    /** The slot a rendered key names under this owner's variables. */
    @Generated
    fun slot(key: DynamicKey): Slot = TODO("milestone 2: the readers")

    /** Whether a guarded field is selected under this owner's variables. */
    @Generated
    fun selects(guard: Guard): Boolean = TODO("milestone 2: the readers")

    /** The owner a spread with `@arguments` reads under: these variables with the site's values over them. */
    @Generated
    fun binding(site: ArgumentSite, values: () -> Map<String, Variable?>): Owner = TODO("milestone 2: the readers")
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
 */
@Stable
class Anchor @Generated constructor(val record: Record, val owner: Owner) {
    val variables: Variables get() = owner.variables

    /** The anchor a fragment spread reads through: the same record, the fragment's scope. */
    @Generated
    fun entering(): Anchor = TODO("milestone 2: the readers")

    /** The anchor a spread with `@arguments` reads through. */
    @Generated
    fun binding(site: ArgumentSite, values: () -> Map<String, Variable?>): Anchor = Anchor(record, owner.binding(site, values))

    // Scalars. A `required` reader returns a zero value where a value is missing or null.

    @Generated fun string(slot: Slot): String? = TODO("milestone 2: the readers")
    @Generated fun requiredString(slot: Slot): String = TODO("milestone 2: the readers")
    @Generated fun int(slot: Slot): Int? = TODO("milestone 2: the readers")
    @Generated fun requiredInt(slot: Slot): Int = TODO("milestone 2: the readers")
    @Generated fun double(slot: Slot): Double? = TODO("milestone 2: the readers")
    @Generated fun requiredDouble(slot: Slot): Double = TODO("milestone 2: the readers")
    @Generated fun bool(slot: Slot): Boolean? = TODO("milestone 2: the readers")
    @Generated fun requiredBool(slot: Slot): Boolean = TODO("milestone 2: the readers")

    // Mapped scalars, through the converter the configuration names, and enums, through the generated `of`.
    // A text the type cannot hold is reported as unexpected, never as missing, and reads as null.

    @Generated fun <T : Any> mapped(slot: Slot, converter: ScalarConverter<T>): T? = TODO("milestone 2: the readers")
    @Generated fun <T : Any> throwingMapped(slot: Slot, path: String, converter: ScalarConverter<T>): T = TODO("milestone 2: the readers")
    @Generated fun <T : Any> caughtMapped(slot: Slot, path: String, converter: ScalarConverter<T>): Result<T> = TODO("milestone 2: the readers")
    @Generated fun <T : Any> caughtOptionalMapped(slot: Slot, path: String, converter: ScalarConverter<T>): Result<T?> = TODO("milestone 2: the readers")
    @Generated fun <T : Any> converts(slot: Slot, converter: ScalarConverter<T>, path: String, log: Boolean): Boolean = TODO("milestone 2: the readers")
    @Generated fun <T : Any> collectConversion(slot: Slot, converter: ScalarConverter<T>, path: String, into: MutableList<FieldError>): Unit = TODO("milestone 2: the readers")
    @Generated fun <T : Any> mappedList(slot: Slot, converter: ScalarConverter<T>): List<T>? = TODO("milestone 2: the readers")
    @Generated fun <T : Any> requiredMappedList(slot: Slot, converter: ScalarConverter<T>): List<T> = TODO("milestone 2: the readers")
    @Generated fun <T : Any> nullableMappedList(slot: Slot, converter: ScalarConverter<T>): List<T?>? = TODO("milestone 2: the readers")
    @Generated fun <T : Any> requiredNullableMappedList(slot: Slot, converter: ScalarConverter<T>): List<T?> = TODO("milestone 2: the readers")

    @Generated fun <T : GeneratedEnum> enumValue(slot: Slot, of: (String) -> T): T? = TODO("milestone 2: the readers")
    @Generated fun <T : GeneratedEnum> requiredEnumValue(slot: Slot, of: (String) -> T): T = TODO("milestone 2: the readers")
    @Generated fun <T : GeneratedEnum> enumValues(slot: Slot, of: (String) -> T): List<T>? = TODO("milestone 2: the readers")
    @Generated fun <T : GeneratedEnum> requiredEnumValues(slot: Slot, of: (String) -> T): List<T> = TODO("milestone 2: the readers")
    @Generated fun <T : GeneratedEnum> nullableEnumValues(slot: Slot, of: (String) -> T): List<T?>? = TODO("milestone 2: the readers")
    @Generated fun <T : GeneratedEnum> requiredNullableEnumValues(slot: Slot, of: (String) -> T): List<T?> = TODO("milestone 2: the readers")

    // Lists of scalars: an element a non-null list cannot hold is reported once and left out; a nullable list reads it as null.

    @Generated fun strings(slot: Slot): List<String>? = TODO("milestone 2: the readers")
    @Generated fun requiredStrings(slot: Slot): List<String> = TODO("milestone 2: the readers")
    @Generated fun ints(slot: Slot): List<Int>? = TODO("milestone 2: the readers")
    @Generated fun requiredInts(slot: Slot): List<Int> = TODO("milestone 2: the readers")
    @Generated fun doubles(slot: Slot): List<Double>? = TODO("milestone 2: the readers")
    @Generated fun requiredDoubles(slot: Slot): List<Double> = TODO("milestone 2: the readers")
    @Generated fun bools(slot: Slot): List<Boolean>? = TODO("milestone 2: the readers")
    @Generated fun requiredBools(slot: Slot): List<Boolean> = TODO("milestone 2: the readers")
    @Generated fun nullableStrings(slot: Slot): List<String?>? = TODO("milestone 2: the readers")
    @Generated fun requiredNullableStrings(slot: Slot): List<String?> = TODO("milestone 2: the readers")
    @Generated fun nullableInts(slot: Slot): List<Int?>? = TODO("milestone 2: the readers")
    @Generated fun requiredNullableInts(slot: Slot): List<Int?> = TODO("milestone 2: the readers")
    @Generated fun nullableDoubles(slot: Slot): List<Double?>? = TODO("milestone 2: the readers")
    @Generated fun requiredNullableDoubles(slot: Slot): List<Double?> = TODO("milestone 2: the readers")
    @Generated fun nullableBools(slot: Slot): List<Boolean?>? = TODO("milestone 2: the readers")
    @Generated fun requiredNullableBools(slot: Slot): List<Boolean?> = TODO("milestone 2: the readers")

    // Links. A deleted record reads as null; a non-null link with no record reads the type's placeholder, reported once.

    @Generated fun linked(slot: Slot): Anchor? = TODO("milestone 2: the readers")
    @Generated fun requiredLinked(slot: Slot, type: TypeID): Anchor = TODO("milestone 2: the readers")
    @Generated fun <Element : Lens> list(slot: Slot, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): LensList<Element>? = TODO("milestone 2: the readers")
    @Generated fun <Element : Lens> requiredList(slot: Slot, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): LensList<Element> = TODO("milestone 2: the readers")
    @Generated fun <Element> values(slot: Slot, build: (Anchor) -> Element): List<Element>? = TODO("milestone 2: the readers")
    @Generated fun <Element> requiredValues(slot: Slot, build: (Anchor) -> Element): List<Element> = TODO("milestone 2: the readers")

    // Honest data: `@required`, `@catch`, `@throwOnFieldError` and `@defer`.

    @Generated fun hasValue(slot: Slot, path: String, log: Boolean): Boolean = TODO("milestone 2: the readers")
    @Generated fun requiredMissing(path: String, log: Boolean): Boolean = TODO("milestone 2: the readers")
    @Generated fun present(slot: Slot): Boolean = TODO("milestone 2: the readers")
    @Generated fun <T : Any> throwing(slot: Slot, path: String, read: (Anchor) -> T?): T = TODO("milestone 2: the readers")
    @Generated fun throwingLinked(slot: Slot, path: String, satisfied: (Anchor) -> Boolean): Anchor = TODO("milestone 2: the readers")
    @Generated fun <Element : Lens> throwingList(slot: Slot, path: String, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): LensList<Element> = TODO("milestone 2: the readers")
    @Generated fun <T> caught(slot: Slot, read: (Anchor) -> T): Result<T> = TODO("milestone 2: the readers")
    @Generated fun <T> caught(slot: Slot, within: (Anchor) -> List<FieldError>, read: (Anchor) -> T): Result<T> = TODO("milestone 2: the readers")
    @Generated fun <Element : Lens> caughtList(slot: Slot, within: (Anchor) -> List<FieldError>, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): Result<LensList<Element>?> = TODO("milestone 2: the readers")
    @Generated fun <Element : Lens> caughtRequiredList(slot: Slot, within: (Anchor) -> List<FieldError>, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): Result<LensList<Element>> = TODO("milestone 2: the readers")
    @Generated fun <Element> caughtValues(slot: Slot, within: (Anchor) -> List<FieldError>, build: (Anchor) -> Element): Result<List<Element>?> = TODO("milestone 2: the readers")
    @Generated fun <Element> caughtRequiredValues(slot: Slot, within: (Anchor) -> List<FieldError>, build: (Anchor) -> Element): Result<List<Element>> = TODO("milestone 2: the readers")
    @Generated fun collectError(slot: Slot, into: MutableList<FieldError>): Unit = TODO("milestone 2: the readers")
    @Generated fun collectRequired(slot: Slot, path: String, into: MutableList<FieldError>): Unit = TODO("milestone 2: the readers")
    @Generated fun collectErrors(slot: Slot, within: (Anchor) -> List<FieldError>, into: MutableList<FieldError>): Unit = TODO("milestone 2: the readers")
    @Generated fun collectListErrors(slot: Slot, within: (Anchor) -> List<FieldError>, into: MutableList<FieldError>): Unit = TODO("milestone 2: the readers")

    // Connections: the state Relay keeps on the connection record, and the fetches that extend or refresh it.

    @Generated fun <Element : Lens> nodes(slots: ConnectionSlots, build: (Anchor) -> Element, keep: ((Anchor) -> Boolean)? = null): List<Element> = TODO("milestone 2: the readers")
    @Generated fun hasNext(slots: ConnectionSlots): Boolean = TODO("milestone 2: the readers")
    @Generated fun hasPrevious(slots: ConnectionSlots): Boolean = TODO("milestone 2: the readers")
    @Generated fun isLoadingNext(slots: ConnectionSlots): Boolean = TODO("milestone 2: the readers")
    @Generated fun isLoadingPrevious(slots: ConnectionSlots): Boolean = TODO("milestone 2: the readers")
    @Generated suspend fun loadNext(operation: OperationType<*>, slots: ConnectionSlots, refetch: Refetch, count: Int): Unit = TODO("milestone 3: the environment")
    @Generated suspend fun loadPrevious(operation: OperationType<*>, slots: ConnectionSlots, refetch: Refetch, count: Int): Unit = TODO("milestone 3: the environment")
    @Generated suspend fun refetch(operation: OperationType<*>, refetch: Refetch): Unit = TODO("milestone 3: the environment")

    override fun equals(other: Any?): Boolean = other is Anchor && other.record === record && other.owner === owner
    override fun hashCode(): Int = record.hashCode() * 31 + owner.hashCode()
}

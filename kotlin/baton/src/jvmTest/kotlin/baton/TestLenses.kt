// Lenses written by hand after the Swift goldens' lenses for the operations
// whose `reads` the harness compares, in the shapes the Kotlin emitter will
// print, until it prints them. Each lens also answers `field`, the path
// table the harness walks a row by: a response key to what the accessor
// reads, a fragment spread's fields reached through the spread.
@file:Suppress("ClassName", "PropertyName", "unused")

package baton

import java.math.BigDecimal
import java.net.URI
import java.time.Instant
import java.time.format.DateTimeParseException

/** A lens the harness walks: the value at a response key, as the lens's accessor reads it. */
internal interface Walkable {
    fun field(key: String): Any?
}

/** What every generated lens declares: its anchor, and equality by it. */
internal abstract class TestLens(final override val anchor: Anchor) : Lens, Walkable {
    final override fun equals(other: Any?): Boolean = other is TestLens && other::class == this::class && other.anchor == anchor
    final override fun hashCode(): Int = anchor.hashCode()

    protected fun unknown(key: String): Nothing = error("${this::class.simpleName} reads no field $key")
}

/** The spread sites that pass `@arguments`, as generated code declares them. */
internal object Sites {
    val TestNotesQuery_testNotes = ArgumentSite()
}

// Converters a `kotlin` entry of `customScalarTypes` would name.

internal object DecimalConverter : ScalarConverter<BigDecimal> {
    override fun parse(text: String): BigDecimal? = try {
        BigDecimal(text)
    } catch (_: NumberFormatException) {
        null
    }

    override fun render(value: BigDecimal): String = value.toPlainString()
}

internal object InstantConverter : ScalarConverter<Instant> {
    override fun parse(text: String): Instant? = try {
        Instant.parse(text)
    } catch (_: DateTimeParseException) {
        null
    }

    override fun render(value: Instant): String = value.toString()
}

/** A URL, as Foundation's `URL(string:)` reads one: an empty text is none. */
internal object UriConverter : ScalarConverter<URI> {
    override fun parse(text: String): URI? {
        if (text.isEmpty()) return null
        return try {
            URI(text)
        } catch (_: java.net.URISyntaxException) {
            null
        }
    }

    override fun render(value: URI): String = value.toString()
}

/**
 * The schema's enum `Status`, as the emitter prints an enum. The value the
 * schema does not declare is `Undeclared` here, not `Unknown`: the schema
 * has a value `UNKNOWN`, and `Status$UNKNOWN` and `Status$Unknown` are one
 * class file on a case-insensitive file system.
 */
internal sealed interface Status : GeneratedEnum {
    data object ALIVE : Status
    data object DEAD : Status
    data object UNKNOWN : Status
    data class Undeclared(val text: String) : Status

    override val scalarText: String
        get() = when (this) {
            ALIVE -> "ALIVE"
            DEAD -> "DEAD"
            UNKNOWN -> "UNKNOWN"
            is Undeclared -> text
        }

    companion object {
        fun of(text: String): Status = when (text) {
            "ALIVE" -> ALIVE
            "DEAD" -> DEAD
            "UNKNOWN" -> UNKNOWN
            else -> Undeclared(text)
        }
    }
}

/** The lens of each operation whose `reads` the harness compares, over its root's anchor. */
internal object TestLenses {
    val byOperation: Map<String, (Anchor) -> Walkable> = mapOf(
        "Fixture" to Fixture::Data,
        "TestNotesQuery" to TestNotesQuery::Data,
        "TestProfileQuery" to TestProfileQuery::Data,
        "TestStrictQuery" to TestStrictQuery::Data,
        "TestConditions" to TestConditions::Data,
        "TestUnion" to TestUnion::Data,
        "TestAssetQuery" to TestAssetQuery::Data,
        "TestQuoteQuery" to TestQuoteQuery::Data,
        "TestAssetPricesQuery" to TestAssetPricesQuery::Data,
        "TestSetStatuses" to TestSetStatuses::Data,
    )
}

internal object Fixture {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val characters: Characters? get() = anchor.linked(anchor.owner.slot(Slots.Query.characters_5517f9))?.let(::Characters)

        override fun field(key: String): Any? = when (key) {
            "characters" -> characters
            else -> unknown(key)
        }

        class Characters(anchor: Anchor) : TestLens(anchor) {
            val info: Info? get() = anchor.linked(Slots.Characters.info)?.let(::Info)
            val results: List<Results>? get() = anchor.list(Slots.Characters.results, ::Results)

            override fun field(key: String): Any? = when (key) {
                "info" -> info
                "results" -> results
                else -> unknown(key)
            }

            class Info(anchor: Anchor) : TestLens(anchor) {
                val count: Int? get() = anchor.int(Slots.Info.count)
                val pages: Int? get() = anchor.int(Slots.Info.pages)
                val next: Int? get() = anchor.int(Slots.Info.next)
                val prev: Int? get() = anchor.int(Slots.Info.prev)

                override fun field(key: String): Any? = when (key) {
                    "count" -> count
                    "pages" -> pages
                    "next" -> next
                    "prev" -> prev
                    else -> unknown(key)
                }
            }

            class Results(anchor: Anchor) : TestLens(anchor) {
                val id: String? get() = anchor.string(Slots.Character.id)
                val name: String? get() = anchor.string(Slots.Character.name)
                val status: String? get() = anchor.string(Slots.Character.status)
                val species: String? get() = anchor.string(Slots.Character.species)
                val type: String? get() = anchor.string(Slots.Character.type)
                val gender: String? get() = anchor.string(Slots.Character.gender)
                val image: String? get() = anchor.string(Slots.Character.image)
                val created: String? get() = anchor.string(Slots.Character.created)
                val origin: Place? get() = anchor.linked(Slots.Character.origin)?.let(::Place)
                val location: Place? get() = anchor.linked(Slots.Character.location)?.let(::Place)
                val episode: List<Episode> get() = anchor.requiredList(Slots.Character.episode, ::Episode)

                override fun field(key: String): Any? = when (key) {
                    "id" -> id
                    "name" -> name
                    "status" -> status
                    "species" -> species
                    "type" -> type
                    "gender" -> gender
                    "image" -> image
                    "created" -> created
                    "origin" -> origin
                    "location" -> location
                    "episode" -> episode
                    else -> unknown(key)
                }

                /** The golden's `Origin` and `Location`, which select the same fields. */
                class Place(anchor: Anchor) : TestLens(anchor) {
                    val id: String? get() = anchor.string(Slots.Location.id)
                    val name: String? get() = anchor.string(Slots.Location.name)
                    val type: String? get() = anchor.string(Slots.Location.type)
                    val dimension: String? get() = anchor.string(Slots.Location.dimension)
                    val created: String? get() = anchor.string(Slots.Location.created)

                    override fun field(key: String): Any? = when (key) {
                        "id" -> id
                        "name" -> name
                        "type" -> type
                        "dimension" -> dimension
                        "created" -> created
                        else -> unknown(key)
                    }
                }

                class Episode(anchor: Anchor) : TestLens(anchor) {
                    val id: String? get() = anchor.string(Slots.Episode.id)
                    val name: String? get() = anchor.string(Slots.Episode.name)
                    val air_date: String? get() = anchor.string(Slots.Episode.air_date)
                    val episode: String? get() = anchor.string(Slots.Episode.episode)
                    val created: String? get() = anchor.string(Slots.Episode.created)
                    val characters: List<Characters> get() = anchor.requiredList(Slots.Episode.characters, ::Characters)

                    override fun field(key: String): Any? = when (key) {
                        "id" -> id
                        "name" -> name
                        "air_date" -> air_date
                        "episode" -> episode
                        "created" -> created
                        "characters" -> characters
                        else -> unknown(key)
                    }

                    class Characters(anchor: Anchor) : TestLens(anchor) {
                        val id: String? get() = anchor.string(Slots.Character.id)
                        val name: String? get() = anchor.string(Slots.Character.name)
                        val image: String? get() = anchor.string(Slots.Character.image)

                        override fun field(key: String): Any? = when (key) {
                            "id" -> id
                            "name" -> name
                            "image" -> image
                            else -> unknown(key)
                        }
                    }
                }
            }
        }
    }
}

/** `fragment TestNotes_character`: a connection with its state. */
internal class TestNotes_character(anchor: Anchor) : TestLens(anchor) {
    val name: String? get() = anchor.string(Slots.Character.name)
    val notes: Notes get() = Notes(anchor.requiredLinked(Slots.Character.__TestNotes_notes_connection, Types.NoteConnection))
    val id: String? get() = anchor.string(Slots.Character.id)

    override fun field(key: String): Any? = when (key) {
        "name" -> name
        "notes" -> notes
        "id" -> id
        else -> unknown(key)
    }

    class Notes(anchor: Anchor) : TestLens(anchor) {
        val totalCount: Int get() = anchor.requiredInt(Slots.NoteConnection.totalCount)
        val edges: List<Edges>? get() = anchor.list(Slots.NoteConnection.edges, ::Edges)
        val pageInfo: PageInfo get() = PageInfo(anchor.requiredLinked(Slots.NoteConnection.pageInfo, Types.PageInfo))
        val nodes: List<Edges.Node> get() = anchor.nodes(connection, Edges::Node)
        val hasNext: Boolean get() = anchor.hasNext(connection)
        val hasPrevious: Boolean get() = anchor.hasPrevious(connection)
        val isLoadingNext: Boolean get() = anchor.isLoadingNext(connection)
        val isLoadingPrevious: Boolean get() = anchor.isLoadingPrevious(connection)
        val connectionID: String get() = anchor.record.key

        override fun field(key: String): Any? = when (key) {
            "totalCount" -> totalCount
            "edges" -> edges
            "pageInfo" -> pageInfo
            else -> unknown(key)
        }

        companion object {
            val connection = ConnectionSlots(connection = Types.NoteConnection, edge = Types.NoteEdge, pageInfo = Types.PageInfo)
        }

        class Edges(anchor: Anchor) : TestLens(anchor) {
            val node: Node? get() = anchor.linked(Slots.NoteEdge.node)?.let(::Node)
            val cursor: String get() = anchor.requiredString(Slots.NoteEdge.cursor)

            override fun field(key: String): Any? = when (key) {
                "node" -> node
                "cursor" -> cursor
                else -> unknown(key)
            }

            class Node(anchor: Anchor) : TestLens(anchor) {
                val id: String? get() = anchor.string(Slots.Note.id)
                val text: String? get() = anchor.string(Slots.Note.text)

                override fun field(key: String): Any? = when (key) {
                    "id" -> id
                    "text" -> text
                    else -> unknown(key)
                }
            }
        }

        class PageInfo(anchor: Anchor) : TestLens(anchor) {
            val endCursor: String? get() = anchor.string(Slots.PageInfo.endCursor)
            val hasNextPage: Boolean get() = anchor.requiredBool(Slots.PageInfo.hasNextPage)

            override fun field(key: String): Any? = when (key) {
                "endCursor" -> endCursor
                "hasNextPage" -> hasNextPage
                else -> unknown(key)
            }
        }
    }
}

internal object TestNotesQuery {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val character: Character? get() = anchor.linked(anchor.owner.slot(Slots.Query.character_bca4f9))?.let(::Character)

        override fun field(key: String): Any? = when (key) {
            "character" -> character
            else -> unknown(key)
        }

        class Character(anchor: Anchor) : TestLens(anchor) {
            val testNotes: TestNotes_character
                get() {
                    val bound = anchor.binding(Sites.TestNotesQuery_testNotes) { mapOf("count" to Variable.Int(2), "cursor" to Variable.Null) }
                    return TestNotes_character(bound.entering())
                }

            override fun field(key: String): Any? = testNotes.field(key)
        }
    }
}

/** `fragment TestAppearances_character`, spread under `@defer`. */
internal class TestAppearances_character(anchor: Anchor) : TestLens(anchor) {
    val episode: List<Episode> get() = anchor.requiredList(Slots.Character.episode, ::Episode)

    override fun field(key: String): Any? = when (key) {
        "episode" -> episode
        else -> unknown(key)
    }

    class Episode(anchor: Anchor) : TestLens(anchor) {
        val name: String? get() = anchor.string(Slots.Episode.name)
        val air_date: String? get() = anchor.string(Slots.Episode.air_date)

        override fun field(key: String): Any? = when (key) {
            "name" -> name
            "air_date" -> air_date
            else -> unknown(key)
        }
    }

    companion object {
        fun isPresent(anchor: Anchor): Boolean = anchor.present(Slots.Character.episode)
    }
}

/** `fragment TestProfile_character`: `@required` with NONE and LOG, `@catch` on a scalar and a link. */
internal class TestProfile_character(anchor: Anchor) : TestLens(anchor) {
    val name: String? get() = anchor.string(Slots.Character.name)
    val origin: Origin get() = Origin(anchor.requiredLinked(Slots.Character.origin, Types.Location))
    val status: String get() = anchor.requiredString(Slots.Character.status)
    val image: Result<String?> get() = anchor.caught(Slots.Character.image) { it.string(Slots.Character.image) }
    val location: Result<Location?> get() = anchor.caught(Slots.Character.location, Location::fieldErrors) { it.linked(Slots.Character.location)?.let(::Location) }
    val gender: String? get() = anchor.string(Slots.Character.gender)

    override fun field(key: String): Any? = when (key) {
        "name" -> name
        "origin" -> origin
        "status" -> status
        "image" -> image
        "location" -> location
        "gender" -> gender
        else -> unknown(key)
    }

    companion object {
        fun satisfied(anchor: Anchor): Boolean {
            if (!anchor.hasValue(Slots.Character.origin, "origin", log = false)) return false
            if (!anchor.hasValue(Slots.Character.status, "status", log = true)) return false
            return true
        }
    }

    class Origin(anchor: Anchor) : TestLens(anchor) {
        val name: String? get() = anchor.string(Slots.Location.name)

        override fun field(key: String): Any? = when (key) {
            "name" -> name
            else -> unknown(key)
        }
    }

    class Location(anchor: Anchor) : TestLens(anchor) {
        val name: String? get() = anchor.string(Slots.Location.name)
        val dimension: String? get() = anchor.string(Slots.Location.dimension)

        override fun field(key: String): Any? = when (key) {
            "name" -> name
            "dimension" -> dimension
            else -> unknown(key)
        }

        companion object {
            fun fieldErrors(anchor: Anchor): List<FieldError> {
                val errors = ArrayList<FieldError>()
                anchor.collectError(Slots.Location.name, errors)
                anchor.collectError(Slots.Location.dimension, errors)
                return errors
            }
        }
    }
}

/** `fragment TestStrict_character @throwOnFieldError`, with a `@required(action: THROW)` field. */
internal class TestStrict_character(anchor: Anchor) : TestLens(anchor) {
    val species: String get() = anchor.requiredString(Slots.Character.species)
    val type: String get() = anchor.throwing(Slots.Character.type, "type") { it.string(Slots.Character.type) }

    override fun field(key: String): Any? = when (key) {
        "species" -> species
        "type" -> type
        else -> unknown(key)
    }

    companion object {
        fun fieldErrors(anchor: Anchor): List<FieldError> {
            val errors = ArrayList<FieldError>()
            anchor.collectError(Slots.Character.species, errors)
            anchor.collectError(Slots.Character.type, errors)
            anchor.collectRequired(Slots.Character.type, "type", errors)
            return errors
        }

        fun caught(anchor: Anchor): Result<TestStrict_character> {
            val errors = fieldErrors(anchor)
            return if (errors.isEmpty()) Result.success(TestStrict_character(anchor)) else Result.failure(FieldErrors(errors))
        }

        fun throwing(anchor: Anchor): TestStrict_character = caught(anchor).getOrThrow()
    }
}

internal object TestProfileQuery {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val character: Character? get() = anchor.linked(anchor.owner.slot(Slots.Query.character_bca4f9))?.let(::Character)

        override fun field(key: String): Any? = when (key) {
            "character" -> character
            else -> unknown(key)
        }

        class Character(anchor: Anchor) : TestLens(anchor) {
            val testProfile: TestProfile_character?
                get() {
                    if (!TestProfile_character.satisfied(anchor)) return null
                    return TestProfile_character(anchor.entering())
                }
            val strict: TestStrict_character get() = TestStrict_character.throwing(anchor.entering())
            val testAppearances: TestAppearances_character?
                get() {
                    if (!TestAppearances_character.isPresent(anchor)) return null
                    return TestAppearances_character(anchor.entering())
                }

            override fun field(key: String): Any? = when (key) {
                "name", "origin", "status", "image", "location", "gender" -> testProfile?.field(key)
                "species", "type" -> strict.field(key)
                "episode" -> testAppearances?.field(key)
                else -> unknown(key)
            }
        }
    }
}

/** `query TestStrictQuery @throwOnFieldError`. */
internal object TestStrictQuery {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val character: Character? get() = anchor.linked(anchor.owner.slot(Slots.Query.character_bca4f9))?.let(::Character)

        override fun field(key: String): Any? = when (key) {
            "character" -> character
            else -> unknown(key)
        }

        companion object {
            fun fieldErrors(anchor: Anchor): List<FieldError> {
                val errors = ArrayList<FieldError>()
                anchor.collectErrors(anchor.owner.slot(Slots.Query.character_bca4f9), Character::fieldErrors, errors)
                return errors
            }

            fun caught(anchor: Anchor): Result<Data> {
                val errors = fieldErrors(anchor)
                return if (errors.isEmpty()) Result.success(Data(anchor)) else Result.failure(FieldErrors(errors))
            }
        }

        class Character(anchor: Anchor) : TestLens(anchor) {
            val name: String? get() = anchor.string(Slots.Character.name)
            val species: String get() = anchor.requiredString(Slots.Character.species)

            override fun field(key: String): Any? = when (key) {
                "name" -> name
                "species" -> species
                else -> unknown(key)
            }

            companion object {
                fun fieldErrors(anchor: Anchor): List<FieldError> {
                    val errors = ArrayList<FieldError>()
                    anchor.collectError(Slots.Character.name, errors)
                    anchor.collectError(Slots.Character.species, errors)
                    return errors
                }
            }
        }
    }
}

/** `query TestConditions`: fields under `@include` and `@skip`. */
internal object TestConditions {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val character: Character? get() = anchor.linked(anchor.owner.slot(Slots.Query.character_bca4f9))?.let(::Character)

        override fun field(key: String): Any? = when (key) {
            "character" -> character
            else -> unknown(key)
        }

        class Character(anchor: Anchor) : TestLens(anchor) {
            val name: String? get() = anchor.string(Slots.Character.name)
            val origin: Origin? get() = anchor.linked(Slots.Character.origin)?.let(::Origin)
            val species: String? get() = if (anchor.owner.selects(Guards.withOrigin_true)) anchor.string(Slots.Character.species) else null
            val status: String? get() = if (anchor.owner.selects(Guards.hideStatus_false)) anchor.string(Slots.Character.status) else null

            override fun field(key: String): Any? = when (key) {
                "name" -> name
                "origin" -> origin
                "species" -> species
                "status" -> status
                else -> unknown(key)
            }

            class Origin(anchor: Anchor) : TestLens(anchor) {
                val id: String? get() = anchor.string(Slots.Location.id)
                val name: String? get() = if (anchor.owner.selects(Guards.withOrigin_true)) anchor.string(Slots.Location.name) else null
                val dimension: String? get() = if (anchor.owner.selects(Guards.withOrigin_true)) anchor.string(Slots.Location.dimension) else null

                override fun field(key: String): Any? = when (key) {
                    "id" -> id
                    "name" -> name
                    "dimension" -> dimension
                    else -> unknown(key)
                }
            }
        }
    }
}

/** `query TestUnion`: a union's variants by concrete type and an interface's by membership. */
internal object TestUnion {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val search: List<Search>? get() = anchor.list(anchor.owner.slot(Slots.Query.search_954c44), ::Search)

        override fun field(key: String): Any? = when (key) {
            "search" -> search
            else -> unknown(key)
        }

        class Search(anchor: Anchor) : TestLens(anchor) {
            val asCharacter: AsCharacter? get() = if (anchor.record.type == Types.Character) AsCharacter(anchor) else null
            val asLocation: AsLocation? get() = if (anchor.record.type == Types.Location) AsLocation(anchor) else null
            val asEpisode: AsEpisode? get() = if (anchor.record.type == Types.Episode) AsEpisode(anchor) else null
            val asNamed: AsNamed? get() = if (Types.Named_possible.includes(anchor.record.type)) AsNamed(anchor) else null

            override fun field(key: String): Any? = when (key) {
                "label" -> asCharacter?.label ?: asLocation?.label
                "status" -> asCharacter?.status
                "type" -> asLocation?.type
                "air_date" -> asEpisode?.air_date
                "name" -> asNamed?.name
                else -> unknown(key)
            }

            class AsCharacter(anchor: Anchor) : TestLens(anchor) {
                val label: String? get() = anchor.string(Slots.Character.name)
                val status: String? get() = anchor.string(Slots.Character.status)
                val name: String? get() = anchor.string(Slots.Character.name)

                override fun field(key: String): Any? = unknown(key)
            }

            class AsLocation(anchor: Anchor) : TestLens(anchor) {
                val label: String? get() = anchor.string(Slots.Location.dimension)
                val type: String? get() = anchor.string(Slots.Location.type)
                val name: String? get() = anchor.string(Slots.Location.name)

                override fun field(key: String): Any? = unknown(key)
            }

            class AsEpisode(anchor: Anchor) : TestLens(anchor) {
                val air_date: String? get() = anchor.string(Slots.Episode.air_date)

                override fun field(key: String): Any? = unknown(key)
            }

            /** Swift reads `name` through an abstract slot; the Kotlin runtime has none yet, so the concrete type's slot stands in. */
            class AsNamed(anchor: Anchor) : TestLens(anchor) {
                val name: String? get() = anchor.string(Registry.slot(anchor.record.type, "name"))

                override fun field(key: String): Any? = unknown(key)
            }
        }
    }
}

/** `query TestAssetQuery`: an entity keyed by a configured identity field. */
internal object TestAssetQuery {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val asset: Asset? get() = anchor.linked(anchor.owner.slot(Slots.Query.asset_9e39ed))?.let(::Asset)

        override fun field(key: String): Any? = when (key) {
            "asset" -> asset
            else -> unknown(key)
        }

        class Asset(anchor: Anchor) : TestLens(anchor) {
            val owner: Owner? get() = anchor.linked(Slots.Asset.owner)?.let(::Owner)
            val uuid: String get() = anchor.requiredString(Slots.Asset.uuid)
            val name: String? get() = anchor.string(Slots.Asset.name)

            override fun field(key: String): Any? = when (key) {
                "owner" -> owner
                "uuid" -> uuid
                "name" -> name
                else -> unknown(key)
            }

            class Owner(anchor: Anchor) : TestLens(anchor) {
                val name: String? get() = anchor.string(Slots.Character.name)

                override fun field(key: String): Any? = when (key) {
                    "name" -> name
                    else -> unknown(key)
                }
            }
        }
    }
}

/** `query TestQuoteQuery`: an entity keyed by two identity fields. */
internal object TestQuoteQuery {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val quote: Quote? get() = anchor.linked(anchor.owner.slot(Slots.Query.quote_bd29fc))?.let(::Quote)

        override fun field(key: String): Any? = when (key) {
            "quote" -> quote
            else -> unknown(key)
        }

        class Quote(anchor: Anchor) : TestLens(anchor) {
            val base: String get() = anchor.requiredString(Slots.Quote.base)
            val quote: String get() = anchor.requiredString(Slots.Quote.quote)
            val rate: Double? get() = anchor.double(Slots.Quote.rate)

            override fun field(key: String): Any? = when (key) {
                "base" -> base
                "quote" -> quote
                "rate" -> rate
                else -> unknown(key)
            }
        }
    }
}

/** `query TestAssetPricesQuery`: mapped scalars through converters, and a list of them. */
internal object TestAssetPricesQuery {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val assets: List<Assets>? get() = anchor.list(Slots.Query.assets, ::Assets)

        override fun field(key: String): Any? = when (key) {
            "assets" -> assets
            else -> unknown(key)
        }

        class Assets(anchor: Anchor) : TestLens(anchor) {
            val uuid: String get() = anchor.requiredString(Slots.Asset.uuid)
            val price: BigDecimal? get() = anchor.mapped(Slots.Asset.price, DecimalConverter)
            val listedAt: Instant? get() = anchor.mapped(Slots.Asset.listedAt, InstantConverter)
            val page: URI? get() = anchor.mapped(Slots.Asset.page, UriConverter)
            val prices: List<BigDecimal?>? get() = anchor.nullableMappedList(Slots.Asset.prices, DecimalConverter)

            override fun field(key: String): Any? = when (key) {
                "uuid" -> uuid
                "price" -> price
                "listedAt" -> listedAt
                "page" -> page
                "prices" -> prices
                else -> unknown(key)
            }
        }
    }
}

/** `mutation TestSetStatuses`: a list of a nullable enum. */
internal object TestSetStatuses {
    class Data(anchor: Anchor) : TestLens(anchor) {
        val setLists: SetLists? get() = anchor.linked(Slots.Mutation.setLists)?.let(::SetLists)

        override fun field(key: String): Any? = when (key) {
            "setLists" -> setLists
            else -> unknown(key)
        }

        class SetLists(anchor: Anchor) : TestLens(anchor) {
            val statuses: List<Status?>? get() = anchor.nullableEnumValues(Slots.ListsPayload.statuses, Status::of)

            override fun field(key: String): Any? = when (key) {
                "statuses" -> statuses
                else -> unknown(key)
            }
        }
    }
}

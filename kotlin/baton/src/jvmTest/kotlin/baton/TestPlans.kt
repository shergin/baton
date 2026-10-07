// Transcribed from the plan literals of compiler/src/tests/goldens/*.baton.swift
// until the Kotlin emitter prints them, by kotlin/scripts/transcribe-plans.py;
// run it again rather than edit.
@file:Suppress("ObjectPropertyName", "PropertyName", "unused")

package baton

internal object Types {
    val AddNotePayload = Registry.type("AddNotePayload")
    val Any_ = Registry.type("Any")
    val Asset = Registry.type("Asset")
    val Baton_ = Registry.type("Baton")
    val Character = Registry.type("Character")
    val Characters = Registry.type("Characters")
    val Draft = Registry.type("Draft")
    val Episode = Registry.type("Episode")
    val FavoritePayload = Registry.type("FavoritePayload")
    val Info = Registry.type("Info")
    val ListsPayload = Registry.type("ListsPayload")
    val Location = Registry.type("Location")
    val Mutation = Registry.type("Mutation")
    val Named = Registry.type("Named")
    val Node = Registry.type("Node")
    val Note = Registry.type("Note")
    val NoteAddedPayload = Registry.type("NoteAddedPayload")
    val NoteConnection = Registry.type("NoteConnection")
    val NoteEdge = Registry.type("NoteEdge")
    val PageInfo = Registry.type("PageInfo")
    val Protocol_ = Registry.type("Protocol")
    val Query = Registry.type("Query")
    val Quote = Registry.type("Quote")
    val RemoveNotePayload = Registry.type("RemoveNotePayload")
    val SearchResult = Registry.type("SearchResult")
    val Secret = Registry.type("Secret", transient = true)
    val Set = Registry.type("Set")
    val Spelled = Registry.type("Spelled")
    val Spelling = Registry.type("Spelling")
    val Subscription = Registry.type("Subscription")
    val Tokenizer = Registry.type("Tokenizer")
    val Type_ = Registry.type("Type")
    val Types = Registry.type("Types")
    val transient = Transient(types = listOf(Secret), fields = listOf(Query to "secrets"))
    val Named_possible = Members(Named, listOf(Character, Location))
    val Spelled_possible = Members(Spelled, listOf(Any_, Baton_, Protocol_, Set, Type_))
    val Node_keyed = Members(Node, listOf(Character, Episode, Location, Note))
}

internal object Slots {
    object AddNotePayload {
        val note = Registry.slot(Types.AddNotePayload, "note")
        val noteEdge = Registry.slot(Types.AddNotePayload, "noteEdge")
    }
    object Any_ {
        val id = Registry.slot(Types.Any_, "id")
        val label = Registry.slot(Types.Any_, "label")
    }
    object Asset {
        val id = Registry.slot(Types.Asset, "id")
        val listedAt = Registry.slot(Types.Asset, "listedAt")
        val name = Registry.slot(Types.Asset, "name")
        val owner = Registry.slot(Types.Asset, "owner")
        val page = Registry.slot(Types.Asset, "page")
        val price = Registry.slot(Types.Asset, "price")
        val prices = Registry.slot(Types.Asset, "prices")
        val size = Registry.slot(Types.Asset, "size")
        val uuid = Registry.slot(Types.Asset, "uuid")
    }
    object Baton_ {
        val id = Registry.slot(Types.Baton_, "id")
        val label = Registry.slot(Types.Baton_, "label")
    }
    object Character {
        val __HostileConnectionNodes_notes_connection = Registry.slot(Types.Character, "__HostileConnectionNodes_notes_connection")
        val __HostileConnection_notes_connection = Registry.slot(Types.Character, "__HostileConnection_notes_connection")
        val __TestAuthorNotes_notes_connection = Registry.slot(Types.Character, "__TestAuthorNotes_notes_connection")
        val __TestDeferredNotes_notes_connection = Registry.slot(Types.Character, "__TestDeferredNotes_notes_connection")
        val __TestEdgesNames_notes_connection = Registry.slot(Types.Character, "__TestEdgesNames_notes_connection")
        val __TestHiddenNotes_notes_connection = Registry.slot(Types.Character, "__TestHiddenNotes_notes_connection")
        val __TestHiddenRecentNotes_notes_connection = Registry.slot(Types.Character, "__TestHiddenRecentNotes_notes_connection")
        val __TestNotes_notes_connection = Registry.slot(Types.Character, "__TestNotes_notes_connection")
        val __TestRecentNotes_notes_connection = Registry.slot(Types.Character, "__TestRecentNotes_notes_connection")
        val __TestTwoPages_notes_connection = Registry.slot(Types.Character, "__TestTwoPages_notes_connection")
        val __typename = Registry.slot(Types.Character, "__typename")
        val created = Registry.slot(Types.Character, "created")
        val episode = Registry.slot(Types.Character, "episode")
        val favorite = Registry.slot(Types.Character, "favorite")
        val gender = Registry.slot(Types.Character, "gender")
        val id = Registry.slot(Types.Character, "id")
        val image = Registry.slot(Types.Character, "image")
        val isPinned = Registry.clientSlot(Types.Character, "isPinned")
        val location = Registry.slot(Types.Character, "location")
        val name = Registry.slot(Types.Character, "name")
        val note = Registry.clientSlot(Types.Character, "note")
        val notes_8d6d15 = Registry.slot(Types.Character, "notes(after:\"c2\",first:2)")
        val notes_a9400e = DynamicKey(Types.Character, "notes", listOf(KeyArgument("after", listOf(KeyPart.Variable("cursor"))), KeyArgument("first", listOf(KeyPart.Variable("count")))))
        val notes_d859b7 = DynamicKey(Types.Character, "notes", listOf(KeyArgument("before", listOf(KeyPart.Variable("cursor"))), KeyArgument("last", listOf(KeyPart.Variable("count")))))
        val notes_041c11 = DynamicKey(Types.Character, "notes", listOf(KeyArgument("first", listOf(KeyPart.Variable("count")))))
        val notes_73b9e5 = DynamicKey(Types.Character, "notes", listOf(KeyArgument("first", listOf(KeyPart.Variable("size")))))
        val notes_f89852 = Registry.slot(Types.Character, "notes(first:1)")
        val notes_29a6d8 = Registry.slot(Types.Character, "notes(first:2)")
        val notes_993b52 = Registry.slot(Types.Character, "notes(first:3)")
        val notes_8f8f78 = Registry.slot(Types.Character, "notes(first:97)")
        val notes_01e6d2 = Registry.slot(Types.Character, "notes(last:2)")
        val origin = Registry.slot(Types.Character, "origin")
        val secret = Registry.slot(Types.Character, "secret")
        val species = Registry.slot(Types.Character, "species")
        val status = Registry.slot(Types.Character, "status")
        val type = Registry.slot(Types.Character, "type")
    }
    object Characters {
        val info = Registry.slot(Types.Characters, "info")
        val results = Registry.slot(Types.Characters, "results")
    }
    object Draft {
        val about = Registry.clientSlot(Types.Draft, "about")
        val id = Registry.clientSlot(Types.Draft, "id")
        val text = Registry.clientSlot(Types.Draft, "text")
    }
    object Episode {
        val __typename = Registry.slot(Types.Episode, "__typename")
        val air_date = Registry.slot(Types.Episode, "air_date")
        val characters = Registry.slot(Types.Episode, "characters")
        val created = Registry.slot(Types.Episode, "created")
        val episode = Registry.slot(Types.Episode, "episode")
        val id = Registry.slot(Types.Episode, "id")
        val name = Registry.slot(Types.Episode, "name")
    }
    object FavoritePayload {
        val character = Registry.slot(Types.FavoritePayload, "character")
    }
    object Info {
        val count = Registry.slot(Types.Info, "count")
        val next = Registry.slot(Types.Info, "next")
        val pages = Registry.slot(Types.Info, "pages")
        val prev = Registry.slot(Types.Info, "prev")
    }
    object ListsPayload {
        val counts = Registry.slot(Types.ListsPayload, "counts")
        val flags = Registry.slot(Types.ListsPayload, "flags")
        val ids = Registry.slot(Types.ListsPayload, "ids")
        val jsons = Registry.slot(Types.ListsPayload, "jsons")
        val ratios = Registry.slot(Types.ListsPayload, "ratios")
        val statuses = Registry.slot(Types.ListsPayload, "statuses")
        val strings = Registry.slot(Types.ListsPayload, "strings")
    }
    object Location {
        val __typename = Registry.slot(Types.Location, "__typename")
        val created = Registry.slot(Types.Location, "created")
        val dimension = Registry.slot(Types.Location, "dimension")
        val id = Registry.slot(Types.Location, "id")
        val name = Registry.slot(Types.Location, "name")
        val type = Registry.slot(Types.Location, "type")
    }
    object Mutation {
        val addNote = Registry.slot(Types.Mutation, "addNote")
        val removeNote = Registry.slot(Types.Mutation, "removeNote")
        val rename = Registry.slot(Types.Mutation, "rename")
        val setFavorite = Registry.slot(Types.Mutation, "setFavorite")
        val setFavorite_e62d42 = Registry.slot(Types.Mutation, "setFavorite(as:\"self\")")
        val setFavorite_a93f6b = Registry.slot(Types.Mutation, "setFavorite(as:\"sendable\")")
        val setFavorite_937be0 = Registry.slot(Types.Mutation, "setFavorite(as:\"string\")")
        val setFavorite_10eb38 = Registry.slot(Types.Mutation, "setFavorite(as:\"type\")")
        val setLists = Registry.slot(Types.Mutation, "setLists")
    }
    object Named {
        val __typename = Registry.slot(Types.Named, "__typename")
        val id = Registry.slot(Types.Named, "id")
        val name = Registry.slot(Types.Named, "name")
    }
    object Node {
        val __typename = Registry.slot(Types.Node, "__typename")
        val id = Registry.slot(Types.Node, "id")
        val name = Registry.slot(Types.Node, "name")
    }
    object Note {
        val __typename = Registry.slot(Types.Note, "__typename")
        val author = Registry.slot(Types.Note, "author")
        val id = Registry.slot(Types.Note, "id")
        val text = Registry.slot(Types.Note, "text")
    }
    object NoteAddedPayload {
        val noteEdge = Registry.slot(Types.NoteAddedPayload, "noteEdge")
    }
    object NoteConnection {
        val edges = Registry.slot(Types.NoteConnection, "edges")
        val pageInfo = Registry.slot(Types.NoteConnection, "pageInfo")
        val totalCount = Registry.slot(Types.NoteConnection, "totalCount")
    }
    object NoteEdge {
        val cursor = Registry.slot(Types.NoteEdge, "cursor")
        val node = Registry.slot(Types.NoteEdge, "node")
    }
    object PageInfo {
        val endCursor = Registry.slot(Types.PageInfo, "endCursor")
        val hasNextPage = Registry.slot(Types.PageInfo, "hasNextPage")
        val hasPreviousPage = Registry.slot(Types.PageInfo, "hasPreviousPage")
        val startCursor = Registry.slot(Types.PageInfo, "startCursor")
    }
    object Protocol_ {
        val id = Registry.slot(Types.Protocol_, "id")
        val label = Registry.slot(Types.Protocol_, "label")
    }
    object Query {
        val __TestRootNotes_notes_connection = Registry.slot(Types.Query, "__TestRootNotes_notes_connection")
        val asset_9e39ed = DynamicKey(Types.Query, "asset", listOf(KeyArgument("uuid", listOf(KeyPart.Variable("uuid")))))
        val assets = Registry.slot(Types.Query, "assets")
        val assetsPricedAbove_914469 = DynamicKey(Types.Query, "assetsPricedAbove", listOf(KeyArgument("among", listOf(KeyPart.Variable("among"))), KeyArgument("price", listOf(KeyPart.Variable("price")))))
        val character_9e6829 = Registry.slot(Types.Query, "character(id:\"1\")")
        val character_4a2dfc = Registry.slot(Types.Query, "character(id:\"a,b\")")
        val character_800bca = DynamicKey(Types.Query, "character", listOf(KeyArgument("id", listOf(KeyPart.Variable("a")))))
        val character_ac9202 = DynamicKey(Types.Query, "character", listOf(KeyArgument("id", listOf(KeyPart.Variable("b")))))
        val character_662906 = DynamicKey(Types.Query, "character", listOf(KeyArgument("id", listOf(KeyPart.Variable("hasher")))))
        val character_bca4f9 = DynamicKey(Types.Query, "character", listOf(KeyArgument("id", listOf(KeyPart.Variable("id")))))
        val character_8fc9fb = DynamicKey(Types.Query, "character", listOf(KeyArgument("id", listOf(KeyPart.Variable("where")))))
        val character_c74a1e = Registry.slot(Types.Query, "character(id:1)")
        val characters_2b5ffd = DynamicKey(Types.Query, "characters", listOf(KeyArgument("filter", listOf(KeyPart.Variable("filter")))))
        val characters_498461 = DynamicKey(Types.Query, "characters", listOf(KeyArgument("filter", listOf(KeyPart.Literal("{\"name\":"), KeyPart.Variable("name"), KeyPart.Literal(",\"status\":\"Alive\"}")))))
        val characters_192531 = DynamicKey(Types.Query, "characters", listOf(KeyArgument("filter", listOf(KeyPart.Literal("{\"name\":"), KeyPart.Variable("name"), KeyPart.Literal("}")))))
        val characters_5517f9 = DynamicKey(Types.Query, "characters", listOf(KeyArgument("page", listOf(KeyPart.Variable("page")))))
        val charactersByIds_59a627 = DynamicKey(Types.Query, "charactersByIds", listOf(KeyArgument("ids", listOf(KeyPart.Variable("ids")))))
        val charactersByIds_306c08 = DynamicKey(Types.Query, "charactersByIds", listOf(KeyArgument("ids", listOf(KeyPart.Literal("["), KeyPart.Variable("Type"), KeyPart.Literal(","), KeyPart.Variable("Protocol"), KeyPart.Literal(","), KeyPart.Variable("Any"), KeyPart.Literal(","), KeyPart.Variable("self"), KeyPart.Literal(","), KeyPart.Variable("init"), KeyPart.Literal(","), KeyPart.Variable("deinit"), KeyPart.Literal(","), KeyPart.Variable("subscript"), KeyPart.Literal(","), KeyPart.Variable("class"), KeyPart.Literal(","), KeyPart.Variable("struct"), KeyPart.Literal(","), KeyPart.Variable("enum"), KeyPart.Literal(","), KeyPart.Variable("func"), KeyPart.Literal(","), KeyPart.Variable("var"), KeyPart.Literal(","), KeyPart.Variable("let"), KeyPart.Literal(","), KeyPart.Variable("import"), KeyPart.Literal(","), KeyPart.Variable("extension"), KeyPart.Literal(","), KeyPart.Variable("operator"), KeyPart.Literal(","), KeyPart.Variable("static"), KeyPart.Literal(","), KeyPart.Variable("default"), KeyPart.Literal(","), KeyPart.Variable("case"), KeyPart.Literal(","), KeyPart.Variable("switch"), KeyPart.Literal(","), KeyPart.Variable("if"), KeyPart.Literal(","), KeyPart.Variable("else"), KeyPart.Literal(","), KeyPart.Variable("for"), KeyPart.Literal(","), KeyPart.Variable("in"), KeyPart.Literal(","), KeyPart.Variable("while"), KeyPart.Literal(","), KeyPart.Variable("repeat"), KeyPart.Literal(","), KeyPart.Variable("return"), KeyPart.Literal(","), KeyPart.Variable("break"), KeyPart.Literal(","), KeyPart.Variable("continue"), KeyPart.Literal(","), KeyPart.Variable("where"), KeyPart.Literal(","), KeyPart.Variable("is"), KeyPart.Literal(","), KeyPart.Variable("as"), KeyPart.Literal(","), KeyPart.Variable("try"), KeyPart.Literal(","), KeyPart.Variable("throw"), KeyPart.Literal(","), KeyPart.Variable("throws"), KeyPart.Literal(","), KeyPart.Variable("guard"), KeyPart.Literal(","), KeyPart.Variable("defer"), KeyPart.Literal(","), KeyPart.Variable("do"), KeyPart.Literal(","), KeyPart.Variable("catch"), KeyPart.Literal(","), KeyPart.Variable("true"), KeyPart.Literal(","), KeyPart.Variable("false"), KeyPart.Literal(","), KeyPart.Variable("nil"), KeyPart.Literal(","), KeyPart.Variable("super"), KeyPart.Literal(","), KeyPart.Variable("internal"), KeyPart.Literal(","), KeyPart.Variable("private"), KeyPart.Literal(","), KeyPart.Variable("public"), KeyPart.Literal(","), KeyPart.Variable("fileprivate"), KeyPart.Literal(","), KeyPart.Variable("open"), KeyPart.Literal(","), KeyPart.Variable("inout"), KeyPart.Literal(","), KeyPart.Variable("typealias"), KeyPart.Literal(","), KeyPart.Variable("associatedtype"), KeyPart.Literal(","), KeyPart.Variable("protocol"), KeyPart.Literal(","), KeyPart.Variable("some"), KeyPart.Literal(","), KeyPart.Variable("any"), KeyPart.Literal(","), KeyPart.Variable("rethrows"), KeyPart.Literal(","), KeyPart.Variable("fallthrough"), KeyPart.Literal(","), KeyPart.Variable("precedencegroup"), KeyPart.Literal(","), KeyPart.Variable("_"), KeyPart.Literal(","), KeyPart.Variable("Self"), KeyPart.Literal(","), KeyPart.Variable("async"), KeyPart.Literal(","), KeyPart.Variable("borrowing"), KeyPart.Literal(","), KeyPart.Variable("consume"), KeyPart.Literal(","), KeyPart.Variable("consuming"), KeyPart.Literal(","), KeyPart.Variable("copy"), KeyPart.Literal(","), KeyPart.Variable("discard"), KeyPart.Literal(","), KeyPart.Variable("each"), KeyPart.Literal(","), KeyPart.Variable("isolated"), KeyPart.Literal(","), KeyPart.Variable("sending"), KeyPart.Literal(","), KeyPart.Variable("then"), KeyPart.Literal(","), KeyPart.Variable("unsafe"), KeyPart.Literal(","), KeyPart.Variable("await"), KeyPart.Literal(","), KeyPart.Variable("anchor"), KeyPart.Literal(","), KeyPart.Variable("recordID"), KeyPart.Literal(","), KeyPart.Variable("satisfied"), KeyPart.Literal(","), KeyPart.Variable("missingRequiredField"), KeyPart.Literal(","), KeyPart.Variable("fieldErrors"), KeyPart.Literal(","), KeyPart.Variable("isPresent"), KeyPart.Literal(","), KeyPart.Variable("throwing"), KeyPart.Literal(","), KeyPart.Variable("caught"), KeyPart.Literal(","), KeyPart.Variable("refetchable"), KeyPart.Literal(","), KeyPart.Variable("refetch"), KeyPart.Literal(","), KeyPart.Variable("connection"), KeyPart.Literal(","), KeyPart.Variable("nodes"), KeyPart.Literal(","), KeyPart.Variable("hasNext"), KeyPart.Literal(","), KeyPart.Variable("hasPrevious"), KeyPart.Literal(","), KeyPart.Variable("isLoadingNext"), KeyPart.Literal(","), KeyPart.Variable("isLoadingPrevious"), KeyPart.Literal(","), KeyPart.Variable("connectionID"), KeyPart.Literal(","), KeyPart.Variable("loadNext"), KeyPart.Literal(","), KeyPart.Variable("loadPrevious"), KeyPart.Literal(","), KeyPart.Variable("bound"), KeyPart.Literal(","), KeyPart.Variable("errors"), KeyPart.Literal(","), KeyPart.Variable("child"), KeyPart.Literal(","), KeyPart.Variable("missing"), KeyPart.Literal(","), KeyPart.Variable("count"), KeyPart.Literal(","), KeyPart.Variable("fields"), KeyPart.Literal(","), KeyPart.Variable("lhs"), KeyPart.Literal(","), KeyPart.Variable("rhs"), KeyPart.Literal(","), KeyPart.Variable("hasher"), KeyPart.Literal(","), KeyPart.Variable("selection0"), KeyPart.Literal(","), KeyPart.Variable("selection"), KeyPart.Literal(","), KeyPart.Variable("optimistic"), KeyPart.Literal(","), KeyPart.Variable("selfValue"), KeyPart.Literal(","), KeyPart.Variable("Fragment"), KeyPart.Literal(","), KeyPart.Variable("Spread"), KeyPart.Literal(","), KeyPart.Variable("Owner"), KeyPart.Literal(","), KeyPart.Variable("Query"), KeyPart.Literal(","), KeyPart.Variable("Operation"), KeyPart.Literal(","), KeyPart.Variable("RefetchQuery"), KeyPart.Literal(","), KeyPart.Variable("name"), KeyPart.Literal(","), KeyPart.Variable("document"), KeyPart.Literal(","), KeyPart.Variable("text"), KeyPart.Literal(","), KeyPart.Variable("plan"), KeyPart.Literal(","), KeyPart.Variable("errorBehavior"), KeyPart.Literal(","), KeyPart.Variable("throwsOnFieldError"), KeyPart.Literal(","), KeyPart.Variable("bubbles"), KeyPart.Literal(","), KeyPart.Variable("hasDeferred"), KeyPart.Literal(","), KeyPart.Variable("cacheExpiration"), KeyPart.Literal(","), KeyPart.Variable("Action"), KeyPart.Literal(","), KeyPart.Variable("OptimisticResponse"), KeyPart.Literal(","), KeyPart.Variable("hash"), KeyPart.Literal(","), KeyPart.Variable("commit"), KeyPart.Literal(","), KeyPart.Variable("callAsFunction"), KeyPart.Literal(","), KeyPart.Variable("Op"), KeyPart.Literal(","), KeyPart.Variable("variable"), KeyPart.Literal(","), KeyPart.Variable("payload"), KeyPart.Literal(","), KeyPart.Variable("retry"), KeyPart.Literal(","), KeyPart.Variable("subscription"), KeyPart.Literal(","), KeyPart.Variable("Sites"), KeyPart.Literal(","), KeyPart.Variable("Guards"), KeyPart.Literal(","), KeyPart.Variable("AbstractSlots"), KeyPart.Literal(","), KeyPart.Variable("schemaDigest"), KeyPart.Literal(","), KeyPart.Variable("format"), KeyPart.Literal(","), KeyPart.Variable("transient"), KeyPart.Literal(","), KeyPart.Variable("Swift"), KeyPart.Literal(","), KeyPart.Variable("Set"), KeyPart.Literal(","), KeyPart.Variable("Result"), KeyPart.Literal(","), KeyPart.Variable("Optional"), KeyPart.Literal(","), KeyPart.Variable("String"), KeyPart.Literal(","), KeyPart.Variable("Int"), KeyPart.Literal(","), KeyPart.Variable("Double"), KeyPart.Literal(","), KeyPart.Variable("Bool"), KeyPart.Literal(","), KeyPart.Variable("MainActor"), KeyPart.Literal(","), KeyPart.Variable("Hasher"), KeyPart.Literal(","), KeyPart.Variable("Sendable"), KeyPart.Literal("]")))))
        val charactersByIds_0b7f7b = DynamicKey(Types.Query, "charactersByIds", listOf(KeyArgument("ids", listOf(KeyPart.Literal("["), KeyPart.Variable("id"), KeyPart.Literal(",\"2\"]")))))
        val charactersMatching_ca82bd = DynamicKey(Types.Query, "charactersMatching", listOf(KeyArgument("filters", listOf(KeyPart.Variable("filters")))))
        val charactersWithStatus_deb51f = DynamicKey(Types.Query, "charactersWithStatus", listOf(KeyArgument("any", listOf(KeyPart.Variable("any"))), KeyArgument("status", listOf(KeyPart.Variable("status")))))
        val drafts = Registry.clientSlot(Types.Query, "drafts")
        val namesake_9b6471 = DynamicKey(Types.Query, "namesake", listOf(KeyArgument("name", listOf(KeyPart.Variable("name")))))
        val node_8f7d08 = DynamicKey(Types.Query, "node", listOf(KeyArgument("id", listOf(KeyPart.Variable("id")))))
        val node_c27cc2 = Registry.slot(Types.Query, "node(id:1)")
        val notes_a9400e = DynamicKey(Types.Query, "notes", listOf(KeyArgument("after", listOf(KeyPart.Variable("cursor"))), KeyArgument("first", listOf(KeyPart.Variable("count")))))
        val notes_29a6d8 = Registry.slot(Types.Query, "notes(first:2)")
        val quote_bd29fc = DynamicKey(Types.Query, "quote", listOf(KeyArgument("base", listOf(KeyPart.Variable("base"))), KeyArgument("quote", listOf(KeyPart.Variable("quote")))))
        val quotes = Registry.slot(Types.Query, "quotes")
        val search_6286a6 = Registry.slot(Types.Query, "search(name:\"\$0.00\")")
        val search_b80531 = Registry.slot(Types.Query, "search(name:\"\\\\\\\\#1\")")
        val search_823c67 = DynamicKey(Types.Query, "search", listOf(KeyArgument("name", listOf(KeyPart.Variable("in")))))
        val search_954c44 = DynamicKey(Types.Query, "search", listOf(KeyArgument("name", listOf(KeyPart.Variable("name")))))
        val secrets_df579e = DynamicKey(Types.Query, "secrets", listOf(KeyArgument("code", listOf(KeyPart.Variable("code")))))
        val spellings = Registry.slot(Types.Query, "spellings")
        val tokenizer = Registry.slot(Types.Query, "tokenizer")
        val types = Registry.slot(Types.Query, "types")
    }
    object Quote {
        val base = Registry.slot(Types.Quote, "base")
        val quote = Registry.slot(Types.Quote, "quote")
        val rate = Registry.slot(Types.Quote, "rate")
    }
    object RemoveNotePayload {
        val removedNoteId = Registry.slot(Types.RemoveNotePayload, "removedNoteId")
    }
    object SearchResult {
        val __typename = Registry.slot(Types.SearchResult, "__typename")
        val id = Registry.slot(Types.SearchResult, "id")
        val name = Registry.slot(Types.SearchResult, "name")
    }
    object Secret {
        val body = Registry.slot(Types.Secret, "body")
        val id = Registry.slot(Types.Secret, "id")
    }
    object Set {
        val id = Registry.slot(Types.Set, "id")
        val label = Registry.slot(Types.Set, "label")
    }
    object Spelling {
        val __typename = Registry.slot(Types.Spelling, "__typename")
        val id = Registry.slot(Types.Spelling, "id")
        val label = Registry.slot(Types.Spelling, "label")
    }
    object Subscription {
        val noteAdded_cab094 = Registry.slot(Types.Subscription, "noteAdded(characterId:\"1\")")
        val noteAdded_5f458b = DynamicKey(Types.Subscription, "noteAdded", listOf(KeyArgument("characterId", listOf(KeyPart.Variable("characterId")))))
    }
    object Tokenizer {
        val count = Registry.slot(Types.Tokenizer, "count")
        val counts = Registry.slot(Types.Tokenizer, "counts")
        val flag = Registry.slot(Types.Tokenizer, "flag")
        val flags = Registry.slot(Types.Tokenizer, "flags")
        val id = Registry.slot(Types.Tokenizer, "id")
        val json = Registry.slot(Types.Tokenizer, "json")
        val jsons = Registry.slot(Types.Tokenizer, "jsons")
        val ratio = Registry.slot(Types.Tokenizer, "ratio")
        val ratios = Registry.slot(Types.Tokenizer, "ratios")
        val strings = Registry.slot(Types.Tokenizer, "strings")
        val text = Registry.slot(Types.Tokenizer, "text")
    }
    object Type_ {
        val id = Registry.slot(Types.Type_, "id")
        val label = Registry.slot(Types.Type_, "label")
    }
    object Types_ {
        val Any_ = Registry.slot(Types.Types, "Any")
        val Baton_ = Registry.slot(Types.Types, "Baton")
        val Protocol_ = Registry.slot(Types.Types, "Protocol")
        val Type_ = Registry.slot(Types.Types, "Type")
    }
}

internal object Guards {
    @JvmField val AbstractSlots_true = Guard("AbstractSlots", passing = true)
    @JvmField val Action_true = Guard("Action", passing = true)
    @JvmField val Any_true = Guard("Any", passing = true)
    @JvmField val Bool_true = Guard("Bool", passing = true)
    @JvmField val Double_true = Guard("Double", passing = true)
    @JvmField val Fragment_true = Guard("Fragment", passing = true)
    @JvmField val Hasher_true = Guard("Hasher", passing = true)
    @JvmField val Int_true = Guard("Int", passing = true)
    @JvmField val MainActor_true = Guard("MainActor", passing = true)
    @JvmField val Op_true = Guard("Op", passing = true)
    @JvmField val Operation_true = Guard("Operation", passing = true)
    @JvmField val OptimisticResponse_true = Guard("OptimisticResponse", passing = true)
    @JvmField val Optional_true = Guard("Optional", passing = true)
    @JvmField val Owner_true = Guard("Owner", passing = true)
    @JvmField val Protocol_true = Guard("Protocol", passing = true)
    @JvmField val Query_true = Guard("Query", passing = true)
    @JvmField val RefetchQuery_true = Guard("RefetchQuery", passing = true)
    @JvmField val Result_true = Guard("Result", passing = true)
    @JvmField val Self_true = Guard("Self", passing = true)
    @JvmField val Sendable_true = Guard("Sendable", passing = true)
    @JvmField val Set_true = Guard("Set", passing = true)
    @JvmField val Sites_true = Guard("Sites", passing = true)
    @JvmField val Spread_true = Guard("Spread", passing = true)
    @JvmField val String_true = Guard("String", passing = true)
    @JvmField val Swift_true = Guard("Swift", passing = true)
    @JvmField val Type_true = Guard("Type", passing = true)
    @JvmField val __true = Guard("_", passing = true)
    @JvmField val again_true = Guard("again", passing = true)
    @JvmField val anchor_true = Guard("anchor", passing = true)
    @JvmField val any_true = Guard("any", passing = true)
    @JvmField val as_true = Guard("as", passing = true)
    @JvmField val associatedtype_true = Guard("associatedtype", passing = true)
    @JvmField val async_true = Guard("async", passing = true)
    @JvmField val await_true = Guard("await", passing = true)
    @JvmField val borrowing_true = Guard("borrowing", passing = true)
    @JvmField val bound_true = Guard("bound", passing = true)
    @JvmField val break_true = Guard("break", passing = true)
    @JvmField val bubbles_true = Guard("bubbles", passing = true)
    @JvmField val cacheExpiration_true = Guard("cacheExpiration", passing = true)
    @JvmField val callAsFunction_true = Guard("callAsFunction", passing = true)
    @JvmField val case_true = Guard("case", passing = true)
    @JvmField val catch_true = Guard("catch", passing = true)
    @JvmField val caught_true = Guard("caught", passing = true)
    @JvmField val child_true = Guard("child", passing = true)
    @JvmField val class_true = Guard("class", passing = true)
    @JvmField val commit_true = Guard("commit", passing = true)
    @JvmField val connection_true = Guard("connection", passing = true)
    @JvmField val connectionID_true = Guard("connectionID", passing = true)
    @JvmField val consume_true = Guard("consume", passing = true)
    @JvmField val consuming_true = Guard("consuming", passing = true)
    @JvmField val continue_true = Guard("continue", passing = true)
    @JvmField val copy_true = Guard("copy", passing = true)
    @JvmField val count_true = Guard("count", passing = true)
    @JvmField val default_true = Guard("default", passing = true)
    @JvmField val defer_true = Guard("defer", passing = true)
    @JvmField val deinit_true = Guard("deinit", passing = true)
    @JvmField val discard_true = Guard("discard", passing = true)
    @JvmField val do_true = Guard("do", passing = true)
    @JvmField val document_true = Guard("document", passing = true)
    @JvmField val each_true = Guard("each", passing = true)
    @JvmField val else_true = Guard("else", passing = true)
    @JvmField val enum_true = Guard("enum", passing = true)
    @JvmField val errorBehavior_true = Guard("errorBehavior", passing = true)
    @JvmField val errors_true = Guard("errors", passing = true)
    @JvmField val extension_true = Guard("extension", passing = true)
    @JvmField val fallthrough_true = Guard("fallthrough", passing = true)
    @JvmField val false_true = Guard("false", passing = true)
    @JvmField val fieldErrors_true = Guard("fieldErrors", passing = true)
    @JvmField val fields_true = Guard("fields", passing = true)
    @JvmField val fileprivate_true = Guard("fileprivate", passing = true)
    @JvmField val flag_true = Guard("flag", passing = true)
    @JvmField val for_true = Guard("for", passing = true)
    @JvmField val format_true = Guard("format", passing = true)
    @JvmField val func_true = Guard("func", passing = true)
    @JvmField val guard_true = Guard("guard", passing = true)
    @JvmField val hasDeferred_true = Guard("hasDeferred", passing = true)
    @JvmField val hasNext_true = Guard("hasNext", passing = true)
    @JvmField val hasPrevious_true = Guard("hasPrevious", passing = true)
    @JvmField val hash_true = Guard("hash", passing = true)
    @JvmField val hasher_true = Guard("hasher", passing = true)
    @JvmField val hideStatus_false = Guard("hideStatus", passing = false)
    @JvmField val if_true = Guard("if", passing = true)
    @JvmField val import_true = Guard("import", passing = true)
    @JvmField val in_true = Guard("in", passing = true)
    @JvmField val init_true = Guard("init", passing = true)
    @JvmField val inout_true = Guard("inout", passing = true)
    @JvmField val internal_true = Guard("internal", passing = true)
    @JvmField val is_true = Guard("is", passing = true)
    @JvmField val isLoadingNext_true = Guard("isLoadingNext", passing = true)
    @JvmField val isLoadingPrevious_true = Guard("isLoadingPrevious", passing = true)
    @JvmField val isPresent_true = Guard("isPresent", passing = true)
    @JvmField val isRefreshing_true = Guard("isRefreshing", passing = true)
    @JvmField val isStale_true = Guard("isStale", passing = true)
    @JvmField val isolated_true = Guard("isolated", passing = true)
    @JvmField val let_true = Guard("let", passing = true)
    @JvmField val lhs_true = Guard("lhs", passing = true)
    @JvmField val loadNext_true = Guard("loadNext", passing = true)
    @JvmField val loadPrevious_true = Guard("loadPrevious", passing = true)
    @JvmField val missing_true = Guard("missing", passing = true)
    @JvmField val missingRequiredField_true = Guard("missingRequiredField", passing = true)
    @JvmField val name_true = Guard("name", passing = true)
    @JvmField val nil_true = Guard("nil", passing = true)
    @JvmField val nodes_true = Guard("nodes", passing = true)
    @JvmField val open_true = Guard("open", passing = true)
    @JvmField val operator_true = Guard("operator", passing = true)
    @JvmField val optimistic_true = Guard("optimistic", passing = true)
    @JvmField val payload_true = Guard("payload", passing = true)
    @JvmField val phase_true = Guard("phase", passing = true)
    @JvmField val plan_true = Guard("plan", passing = true)
    @JvmField val precedencegroup_true = Guard("precedencegroup", passing = true)
    @JvmField val private_true = Guard("private", passing = true)
    @JvmField val protocol_true = Guard("protocol", passing = true)
    @JvmField val public_true = Guard("public", passing = true)
    @JvmField val recordID_true = Guard("recordID", passing = true)
    @JvmField val refetch_true = Guard("refetch", passing = true)
    @JvmField val refetchable_true = Guard("refetchable", passing = true)
    @JvmField val repeat_true = Guard("repeat", passing = true)
    @JvmField val resolution_true = Guard("resolution", passing = true)
    @JvmField val rethrows_true = Guard("rethrows", passing = true)
    @JvmField val retry_true = Guard("retry", passing = true)
    @JvmField val return_true = Guard("return", passing = true)
    @JvmField val rhs_true = Guard("rhs", passing = true)
    @JvmField val satisfied_true = Guard("satisfied", passing = true)
    @JvmField val schemaDigest_true = Guard("schemaDigest", passing = true)
    @JvmField val selection_true = Guard("selection", passing = true)
    @JvmField val selection0_true = Guard("selection0", passing = true)
    @JvmField val self_true = Guard("self", passing = true)
    @JvmField val selfValue_true = Guard("selfValue", passing = true)
    @JvmField val sending_true = Guard("sending", passing = true)
    @JvmField val some_true = Guard("some", passing = true)
    @JvmField val static_true = Guard("static", passing = true)
    @JvmField val struct_true = Guard("struct", passing = true)
    @JvmField val subscript_true = Guard("subscript", passing = true)
    @JvmField val subscription_true = Guard("subscription", passing = true)
    @JvmField val super_true = Guard("super", passing = true)
    @JvmField val switch_true = Guard("switch", passing = true)
    @JvmField val text_true = Guard("text", passing = true)
    @JvmField val then_true = Guard("then", passing = true)
    @JvmField val throw_true = Guard("throw", passing = true)
    @JvmField val throwing_true = Guard("throwing", passing = true)
    @JvmField val throws_true = Guard("throws", passing = true)
    @JvmField val throwsOnFieldError_true = Guard("throwsOnFieldError", passing = true)
    @JvmField val transient_true = Guard("transient", passing = true)
    @JvmField val true_true = Guard("true", passing = true)
    @JvmField val try_true = Guard("try", passing = true)
    @JvmField val typealias_true = Guard("typealias", passing = true)
    @JvmField val unsafe_true = Guard("unsafe", passing = true)
    @JvmField val var_true = Guard("var", passing = true)
    @JvmField val variable_true = Guard("variable", passing = true)
    @JvmField val where_true = Guard("where", passing = true)
    @JvmField val while_true = Guard("while", passing = true)
    @JvmField val withName_true = Guard("withName", passing = true)
    @JvmField val withNotes_true = Guard("withNotes", passing = true)
    @JvmField val withOrigin_true = Guard("withOrigin", passing = true)
    @JvmField val withStatus_true = Guard("withStatus", passing = true)
}

/** The plans of the operations the manifest names, by operation name. */
internal object TestPlans {
    val byOperation: Map<String, () -> Plan> = mapOf(
        "Fixture" to { FixturePlan.plan },
        "TestAddNote" to { TestAddNotePlan.plan },
        "TestAddNoteFirst" to { TestAddNoteFirstPlan.plan },
        "TestAddNoteNode" to { TestAddNoteNodePlan.plan },
        "TestAddNoteNodeFirst" to { TestAddNoteNodeFirstPlan.plan },
        "TestAssetPricesQuery" to { TestAssetPricesQueryPlan.plan },
        "TestAssetQuery" to { TestAssetQueryPlan.plan },
        "TestAssetsQuery" to { TestAssetsQueryPlan.plan },
        "TestAuthorNotesQuery" to { TestAuthorNotesQueryPlan.plan },
        "TestCharacterSecret" to { TestCharacterSecretPlan.plan },
        "TestConditions" to { TestConditionsPlan.plan },
        "TestDeleteNote" to { TestDeleteNotePlan.plan },
        "TestDrafts" to { TestDraftsPlan.plan },
        "TestEpisodesQuery" to { TestEpisodesQueryPlan.plan },
        "TestHeaderQuery" to { TestHeaderQueryPlan.plan },
        "TestKeys" to { TestKeysPlan.plan },
        "TestList" to { TestListPlan.plan },
        "TestNodeDeferred" to { TestNodeDeferredPlan.plan },
        "TestNodeFields" to { TestNodeFieldsPlan.plan },
        "TestNoteAdded" to { TestNoteAddedPlan.plan },
        "TestNotesPaginationQuery" to { TestNotesPaginationQueryPlan.plan },
        "TestNotesQuery" to { TestNotesQueryPlan.plan },
        "TestPinnedCharacter" to { TestPinnedCharacterPlan.plan },
        "TestProfileQuery" to { TestProfileQueryPlan.plan },
        "TestQuoteQuery" to { TestQuoteQueryPlan.plan },
        "TestQuotesQuery" to { TestQuotesQueryPlan.plan },
        "TestRecentNotesPaginationQuery" to { TestRecentNotesPaginationQueryPlan.plan },
        "TestRecentNotesQuery" to { TestRecentNotesQueryPlan.plan },
        "TestRemoveNote" to { TestRemoveNotePlan.plan },
        "TestRename" to { TestRenamePlan.plan },
        "TestRootNotesQuery" to { TestRootNotesQueryPlan.plan },
        "TestSearch" to { TestSearchPlan.plan },
        "TestSearchOrigins" to { TestSearchOriginsPlan.plan },
        "TestSecrets" to { TestSecretsPlan.plan },
        "TestSetFavorite" to { TestSetFavoritePlan.plan },
        "TestSetStatuses" to { TestSetStatusesPlan.plan },
        "TestStrictQuery" to { TestStrictQueryPlan.plan },
        "TestTokenizerQuery" to { TestTokenizerQueryPlan.plan },
        "TestTwoSpreads" to { TestTwoSpreadsPlan.plan },
        "TestUnion" to { TestUnionPlan.plan },
    )
}

private object FixturePlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("characters", key = StorageKey.Dynamic(Slots.Query.characters_5517f9), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Characters, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("info", key = StorageKey.Fixed(Slots.Characters.info), plural = false, selection = selection6),
            PlanField.linked("results", key = StorageKey.Fixed(Slots.Characters.results), plural = true, selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("status", key = StorageKey.Fixed(Slots.Character.status), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("species", key = StorageKey.Fixed(Slots.Character.species), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("type", key = StorageKey.Fixed(Slots.Character.type), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("gender", key = StorageKey.Fixed(Slots.Character.gender), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("image", key = StorageKey.Fixed(Slots.Character.image), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("created", key = StorageKey.Fixed(Slots.Character.created), kind = ScalarKind.STRING, list = false),
            PlanField.linked("origin", key = StorageKey.Fixed(Slots.Character.origin), plural = false, selection = selection5),
            PlanField.linked("location", key = StorageKey.Fixed(Slots.Character.location), plural = false, selection = selection5),
            PlanField.linked("episode", key = StorageKey.Fixed(Slots.Character.episode), plural = true, selection = selection3)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.Episode, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Episode.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Episode.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("air_date", key = StorageKey.Fixed(Slots.Episode.air_date), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("episode", key = StorageKey.Fixed(Slots.Episode.episode), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("created", key = StorageKey.Fixed(Slots.Episode.created), kind = ScalarKind.STRING, list = false),
            PlanField.linked("characters", key = StorageKey.Fixed(Slots.Episode.characters), plural = true, selection = selection4)
        ))
    }
    private val selection4: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("image", key = StorageKey.Fixed(Slots.Character.image), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection5: Selection by lazy {
        Selection(type = Types.Location, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Location.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Location.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("type", key = StorageKey.Fixed(Slots.Location.type), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("dimension", key = StorageKey.Fixed(Slots.Location.dimension), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("created", key = StorageKey.Fixed(Slots.Location.created), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection6: Selection by lazy {
        Selection(type = Types.Info, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("count", key = StorageKey.Fixed(Slots.Info.count), kind = ScalarKind.INT, list = false),
            PlanField.scalar("pages", key = StorageKey.Fixed(Slots.Info.pages), kind = ScalarKind.INT, list = false),
            PlanField.scalar("next", key = StorageKey.Fixed(Slots.Info.next), kind = ScalarKind.INT, list = false),
            PlanField.scalar("prev", key = StorageKey.Fixed(Slots.Info.prev), kind = ScalarKind.INT, list = false)
        ))
    }
}

private object TestAddNotePlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Mutation, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("addNote", key = StorageKey.Fixed(Slots.Mutation.addNote), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.AddNotePayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("noteEdge", key = StorageKey.Fixed(Slots.AddNotePayload.noteEdge), plural = false, edit = Edit(kind = Edit.Kind.APPEND_EDGE, connections = Edit.Connections.Variable("connections")), selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.NoteEdge, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("cursor", key = StorageKey.Fixed(Slots.NoteEdge.cursor), kind = ScalarKind.STRING, list = false),
            PlanField.linked("node", key = StorageKey.Fixed(Slots.NoteEdge.node), plural = false, selection = selection3)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestAddNoteFirstPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Mutation, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("addNote", key = StorageKey.Fixed(Slots.Mutation.addNote), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.AddNotePayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("noteEdge", key = StorageKey.Fixed(Slots.AddNotePayload.noteEdge), plural = false, edit = Edit(kind = Edit.Kind.PREPEND_EDGE, connections = Edit.Connections.Variable("connections")), selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.NoteEdge, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("cursor", key = StorageKey.Fixed(Slots.NoteEdge.cursor), kind = ScalarKind.STRING, list = false),
            PlanField.linked("node", key = StorageKey.Fixed(Slots.NoteEdge.node), plural = false, selection = selection3)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestAddNoteNodePlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Mutation, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("addNote", key = StorageKey.Fixed(Slots.Mutation.addNote), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.AddNotePayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("note", key = StorageKey.Fixed(Slots.AddNotePayload.note), plural = false, edit = Edit(kind = Edit.Kind.APPEND_NODE, connections = Edit.Connections.Variable("connections"), edgeType = Types.NoteEdge), selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestAddNoteNodeFirstPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Mutation, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("addNote", key = StorageKey.Fixed(Slots.Mutation.addNote), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.AddNotePayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("note", key = StorageKey.Fixed(Slots.AddNotePayload.note), plural = false, edit = Edit(kind = Edit.Kind.PREPEND_NODE, connections = Edit.Connections.Variable("connections"), edgeType = Types.NoteEdge), selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestAssetPricesQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("assets", key = StorageKey.Fixed(Slots.Query.assets), plural = true, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Asset, key = listOf("uuid"), isAbstract = false, fields = listOf(
            PlanField.scalar("uuid", key = StorageKey.Fixed(Slots.Asset.uuid), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("price", key = StorageKey.Fixed(Slots.Asset.price), kind = ScalarKind.CUSTOM, list = false),
            PlanField.scalar("listedAt", key = StorageKey.Fixed(Slots.Asset.listedAt), kind = ScalarKind.CUSTOM, list = false),
            PlanField.scalar("page", key = StorageKey.Fixed(Slots.Asset.page), kind = ScalarKind.CUSTOM, list = false),
            PlanField.scalar("prices", key = StorageKey.Fixed(Slots.Asset.prices), kind = ScalarKind.CUSTOM, list = true),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Asset.id), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestAssetQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("asset", key = StorageKey.Dynamic(Slots.Query.asset_9e39ed), plural = false, lookup = Lookup(type = Types.Asset, key = listOf(Lookup.Key.Variable("uuid"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Asset, key = listOf("uuid"), isAbstract = false, fields = listOf(
            PlanField.linked("owner", key = StorageKey.Fixed(Slots.Asset.owner), plural = false, selection = selection2),
            PlanField.scalar("uuid", key = StorageKey.Fixed(Slots.Asset.uuid), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Asset.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Asset.id), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestAssetsQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("assets", key = StorageKey.Fixed(Slots.Query.assets), plural = true, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Asset, key = listOf("uuid"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Asset.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("size", key = StorageKey.Fixed(Slots.Asset.size), kind = ScalarKind.INT, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Asset.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("uuid", key = StorageKey.Fixed(Slots.Asset.uuid), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestAuthorNotesQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Dynamic(Slots.Query.node_8f7d08), plural = false, lookup = Lookup(type = null, possibleTypes = Types.Node_keyed, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Node, key = listOf("id"), isAbstract = true, variants = listOf(
            Selection.Variant(types = listOf(Types.Note), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Note.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
                PlanField.linked("author", key = StorageKey.Fixed(Slots.Note.author), plural = false, selection = selection2)
            )),
            Selection.Variant(types = null, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Node.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Node.id), kind = ScalarKind.STRING, list = false)
            ))
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.linked("notes", key = StorageKey.Fixed(Slots.Character.notes_29a6d8), plural = false, connection = ConnectionPlan(key = StorageKey.Fixed(Slots.Character.__TestAuthorNotes_notes_connection), slots = ConnectionSlots(connection = Types.NoteConnection, edge = Types.NoteEdge, pageInfo = Types.PageInfo)), selection = selection3)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.NoteConnection, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("edges", key = StorageKey.Fixed(Slots.NoteConnection.edges), plural = true, selection = selection5),
            PlanField.linked("pageInfo", key = StorageKey.Fixed(Slots.NoteConnection.pageInfo), plural = false, selection = selection4)
        ))
    }
    private val selection4: Selection by lazy {
        Selection(type = Types.PageInfo, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("endCursor", key = StorageKey.Fixed(Slots.PageInfo.endCursor), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("hasNextPage", key = StorageKey.Fixed(Slots.PageInfo.hasNextPage), kind = ScalarKind.BOOL, list = false)
        ))
    }
    private val selection5: Selection by lazy {
        Selection(type = Types.NoteEdge, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Fixed(Slots.NoteEdge.node), plural = false, selection = selection6),
            PlanField.scalar("cursor", key = StorageKey.Fixed(Slots.NoteEdge.cursor), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection6: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Note.__typename), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestCharacterSecretPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Fixed(Slots.Query.character_9e6829), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Literal("1"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.linked("secret", key = StorageKey.Fixed(Slots.Character.secret), plural = false, selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Secret, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Secret.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("body", key = StorageKey.Fixed(Slots.Secret.body), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestConditionsPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Dynamic(Slots.Query.character_bca4f9), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.linked("origin", key = StorageKey.Fixed(Slots.Character.origin), plural = false, selection = selection2),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("species", key = StorageKey.Fixed(Slots.Character.species), kind = ScalarKind.STRING, list = false, guards = listOf(listOf(Guards.withOrigin_true))),
            PlanField.scalar("status", key = StorageKey.Fixed(Slots.Character.status), kind = ScalarKind.STRING, list = false, guards = listOf(listOf(Guards.hideStatus_false)))
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Location, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Location.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Location.name), kind = ScalarKind.STRING, list = false, guards = listOf(listOf(Guards.withOrigin_true))),
            PlanField.scalar("dimension", key = StorageKey.Fixed(Slots.Location.dimension), kind = ScalarKind.STRING, list = false, guards = listOf(listOf(Guards.withOrigin_true)))
        ))
    }
}

private object TestDeleteNotePlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Mutation, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("removeNote", key = StorageKey.Fixed(Slots.Mutation.removeNote), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.RemoveNotePayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("removedNoteId", key = StorageKey.Fixed(Slots.RemoveNotePayload.removedNoteId), kind = ScalarKind.STRING, list = false, edit = Edit(kind = Edit.Kind.DELETE_RECORD))
        ))
    }
}

private object TestDraftsPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Fixed(Slots.Query.character_9e6829), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Literal("1"))), selection = selection3),
            PlanField.linked("drafts", key = StorageKey.Fixed(Slots.Query.drafts), plural = true, client = true, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Draft, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Draft.id), kind = ScalarKind.STRING, list = false, client = true),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Draft.text), kind = ScalarKind.STRING, list = false, client = true),
            PlanField.linked("about", key = StorageKey.Fixed(Slots.Draft.about), plural = false, client = true, selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false, client = true),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false, client = true)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestEpisodesQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Dynamic(Slots.Query.character_bca4f9), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.linked("episode", key = StorageKey.Fixed(Slots.Character.episode), plural = true, selection = selection2),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Episode, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Episode.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Episode.name), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestHeaderQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Dynamic(Slots.Query.character_bca4f9), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("status", key = StorageKey.Fixed(Slots.Character.status), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("species", key = StorageKey.Fixed(Slots.Character.species), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("image", key = StorageKey.Fixed(Slots.Character.image), kind = ScalarKind.STRING, list = false),
            PlanField.linked("origin", key = StorageKey.Fixed(Slots.Character.origin), plural = false, selection = selection2),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Location, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Location.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Location.id), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestKeysPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("search", key = StorageKey.Fixed(Slots.Query.search_6286a6), plural = true, selection = selection4),
            PlanField.linked("character", key = StorageKey.Fixed(Slots.Query.character_4a2dfc), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Literal("a,b"))), selection = selection3),
            PlanField.linked("charactersByIds", key = StorageKey.Dynamic(Slots.Query.charactersByIds_0b7f7b), plural = true, selection = selection3),
            PlanField.linked("characters", key = StorageKey.Dynamic(Slots.Query.characters_498461), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Characters, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("info", key = StorageKey.Fixed(Slots.Characters.info), plural = false, selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Info, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("count", key = StorageKey.Fixed(Slots.Info.count), kind = ScalarKind.INT, list = false)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection4: Selection by lazy {
        Selection(type = Types.SearchResult, key = listOf("id"), isAbstract = true, memberships = listOf(Selection.MembershipAnswer("__isNode", Types.Node)), variants = listOf(
            Selection.Variant(types = listOf(Types.Character, Types.Episode, Types.Location), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.SearchResult.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, condition = Types.Node, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.SearchResult.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false)
            ))
        ))
    }
}

private object TestListPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("characters", key = StorageKey.Dynamic(Slots.Query.characters_5517f9), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Characters, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("results", key = StorageKey.Fixed(Slots.Characters.results), plural = true, selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("status", key = StorageKey.Fixed(Slots.Character.status), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("image", key = StorageKey.Fixed(Slots.Character.image), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("species", key = StorageKey.Fixed(Slots.Character.species), kind = ScalarKind.STRING, list = false),
            PlanField.linked("origin", key = StorageKey.Fixed(Slots.Character.origin), plural = false, selection = selection3),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.Location, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Location.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Location.id), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestNodeDeferredPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Dynamic(Slots.Query.node_8f7d08), plural = false, lookup = Lookup(type = null, possibleTypes = Types.Node_keyed, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Node, key = listOf("id"), isAbstract = true, variants = listOf(
            Selection.Variant(types = listOf(Types.Character), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Character.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
                PlanField.linked("episode", key = StorageKey.Fixed(Slots.Character.episode), plural = true, deferred = "TestNodeDeferred\$defer\$TestAppearances_character", selection = selection2)
            )),
            Selection.Variant(types = null, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Node.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Node.id), kind = ScalarKind.STRING, list = false)
            ))
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Episode, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Episode.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("air_date", key = StorageKey.Fixed(Slots.Episode.air_date), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Episode.id), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestNodeFieldsPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Dynamic(Slots.Query.node_8f7d08), plural = false, lookup = Lookup(type = null, possibleTypes = Types.Node_keyed, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Node, key = listOf("id"), isAbstract = true, variants = listOf(
            Selection.Variant(types = listOf(Types.Character), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Character.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Node.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Node.id), kind = ScalarKind.STRING, list = false)
            ))
        ))
    }
}

private object TestNoteAddedPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Subscription, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("noteAdded", key = StorageKey.Dynamic(Slots.Subscription.noteAdded_5f458b), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.NoteAddedPayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("noteEdge", key = StorageKey.Fixed(Slots.NoteAddedPayload.noteEdge), plural = false, edit = Edit(kind = Edit.Kind.APPEND_EDGE, connections = Edit.Connections.Variable("connections")), selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.NoteEdge, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("cursor", key = StorageKey.Fixed(Slots.NoteEdge.cursor), kind = ScalarKind.STRING, list = false),
            PlanField.linked("node", key = StorageKey.Fixed(Slots.NoteEdge.node), plural = false, selection = selection3)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestNotesPaginationQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Dynamic(Slots.Query.node_8f7d08), plural = false, lookup = Lookup(type = null, possibleTypes = Types.Node_keyed, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Node, key = listOf("id"), isAbstract = true, variants = listOf(
            Selection.Variant(types = listOf(Types.Character), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Character.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
                PlanField.linked("notes", key = StorageKey.Dynamic(Slots.Character.notes_a9400e), plural = false, connection = ConnectionPlan(key = StorageKey.Fixed(Slots.Character.__TestNotes_notes_connection), slots = ConnectionSlots(connection = Types.NoteConnection, edge = Types.NoteEdge, pageInfo = Types.PageInfo), after = ConnectionCursor.Variable("cursor")), selection = selection2)
            )),
            Selection.Variant(types = null, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Node.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Node.id), kind = ScalarKind.STRING, list = false)
            ))
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.NoteConnection, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("totalCount", key = StorageKey.Fixed(Slots.NoteConnection.totalCount), kind = ScalarKind.INT, list = false),
            PlanField.linked("edges", key = StorageKey.Fixed(Slots.NoteConnection.edges), plural = true, selection = selection4),
            PlanField.linked("pageInfo", key = StorageKey.Fixed(Slots.NoteConnection.pageInfo), plural = false, selection = selection3)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.PageInfo, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("endCursor", key = StorageKey.Fixed(Slots.PageInfo.endCursor), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("hasNextPage", key = StorageKey.Fixed(Slots.PageInfo.hasNextPage), kind = ScalarKind.BOOL, list = false)
        ))
    }
    private val selection4: Selection by lazy {
        Selection(type = Types.NoteEdge, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Fixed(Slots.NoteEdge.node), plural = false, selection = selection5),
            PlanField.scalar("cursor", key = StorageKey.Fixed(Slots.NoteEdge.cursor), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection5: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Note.__typename), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestNotesQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Dynamic(Slots.Query.character_bca4f9), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.linked("notes", key = StorageKey.Fixed(Slots.Character.notes_29a6d8), plural = false, connection = ConnectionPlan(key = StorageKey.Fixed(Slots.Character.__TestNotes_notes_connection), slots = ConnectionSlots(connection = Types.NoteConnection, edge = Types.NoteEdge, pageInfo = Types.PageInfo)), selection = selection2),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.NoteConnection, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("totalCount", key = StorageKey.Fixed(Slots.NoteConnection.totalCount), kind = ScalarKind.INT, list = false),
            PlanField.linked("edges", key = StorageKey.Fixed(Slots.NoteConnection.edges), plural = true, selection = selection4),
            PlanField.linked("pageInfo", key = StorageKey.Fixed(Slots.NoteConnection.pageInfo), plural = false, selection = selection3)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.PageInfo, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("endCursor", key = StorageKey.Fixed(Slots.PageInfo.endCursor), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("hasNextPage", key = StorageKey.Fixed(Slots.PageInfo.hasNextPage), kind = ScalarKind.BOOL, list = false)
        ))
    }
    private val selection4: Selection by lazy {
        Selection(type = Types.NoteEdge, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Fixed(Slots.NoteEdge.node), plural = false, selection = selection5),
            PlanField.scalar("cursor", key = StorageKey.Fixed(Slots.NoteEdge.cursor), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection5: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Note.__typename), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestPinnedCharacterPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Dynamic(Slots.Query.character_bca4f9), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("status", key = StorageKey.Fixed(Slots.Character.status), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("isPinned", key = StorageKey.Fixed(Slots.Character.isPinned), kind = ScalarKind.BOOL, list = false, client = true),
            PlanField.scalar("note", key = StorageKey.Fixed(Slots.Character.note), kind = ScalarKind.STRING, list = false, client = true)
        ))
    }
}

private object TestProfileQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Dynamic(Slots.Query.character_bca4f9), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.linked("origin", key = StorageKey.Fixed(Slots.Character.origin), plural = false, selection = selection4),
            PlanField.scalar("status", key = StorageKey.Fixed(Slots.Character.status), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("image", key = StorageKey.Fixed(Slots.Character.image), kind = ScalarKind.STRING, list = false, caught = true),
            PlanField.linked("location", key = StorageKey.Fixed(Slots.Character.location), plural = false, caught = true, selection = selection3),
            PlanField.scalar("gender", key = StorageKey.Fixed(Slots.Character.gender), kind = ScalarKind.STRING, list = false, caught = true),
            PlanField.scalar("species", key = StorageKey.Fixed(Slots.Character.species), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("type", key = StorageKey.Fixed(Slots.Character.type), kind = ScalarKind.STRING, list = false),
            PlanField.linked("episode", key = StorageKey.Fixed(Slots.Character.episode), plural = true, deferred = "TestProfileQuery\$defer\$TestAppearances_character", selection = selection2),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Episode, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Episode.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("air_date", key = StorageKey.Fixed(Slots.Episode.air_date), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Episode.id), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.Location, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Location.name), kind = ScalarKind.STRING, list = false, caught = true),
            PlanField.scalar("dimension", key = StorageKey.Fixed(Slots.Location.dimension), kind = ScalarKind.STRING, list = false, caught = true),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Location.id), kind = ScalarKind.STRING, list = false, caught = true)
        ))
    }
    private val selection4: Selection by lazy {
        Selection(type = Types.Location, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Location.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Location.id), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestQuoteQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("quote", key = StorageKey.Dynamic(Slots.Query.quote_bd29fc), plural = false, lookup = Lookup(type = Types.Quote, key = listOf(Lookup.Key.Variable("base"), Lookup.Key.Variable("quote"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Quote, key = listOf("base", "quote"), isAbstract = false, fields = listOf(
            PlanField.scalar("base", key = StorageKey.Fixed(Slots.Quote.base), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("quote", key = StorageKey.Fixed(Slots.Quote.quote), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("rate", key = StorageKey.Fixed(Slots.Quote.rate), kind = ScalarKind.DOUBLE, list = false)
        ))
    }
}

private object TestQuotesQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("quotes", key = StorageKey.Fixed(Slots.Query.quotes), plural = true, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Quote, key = listOf("base", "quote"), isAbstract = false, fields = listOf(
            PlanField.scalar("rate", key = StorageKey.Fixed(Slots.Quote.rate), kind = ScalarKind.DOUBLE, list = false),
            PlanField.scalar("base", key = StorageKey.Fixed(Slots.Quote.base), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("quote", key = StorageKey.Fixed(Slots.Quote.quote), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestRecentNotesPaginationQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Dynamic(Slots.Query.node_8f7d08), plural = false, lookup = Lookup(type = null, possibleTypes = Types.Node_keyed, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Node, key = listOf("id"), isAbstract = true, variants = listOf(
            Selection.Variant(types = listOf(Types.Character), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Character.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
                PlanField.linked("notes", key = StorageKey.Dynamic(Slots.Character.notes_d859b7), plural = false, connection = ConnectionPlan(key = StorageKey.Fixed(Slots.Character.__TestRecentNotes_notes_connection), slots = ConnectionSlots(connection = Types.NoteConnection, edge = Types.NoteEdge, pageInfo = Types.PageInfo), before = ConnectionCursor.Variable("cursor")), selection = selection2)
            )),
            Selection.Variant(types = null, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Node.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Node.id), kind = ScalarKind.STRING, list = false)
            ))
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.NoteConnection, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("edges", key = StorageKey.Fixed(Slots.NoteConnection.edges), plural = true, selection = selection4),
            PlanField.linked("pageInfo", key = StorageKey.Fixed(Slots.NoteConnection.pageInfo), plural = false, selection = selection3)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.PageInfo, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("hasPreviousPage", key = StorageKey.Fixed(Slots.PageInfo.hasPreviousPage), kind = ScalarKind.BOOL, list = false),
            PlanField.scalar("startCursor", key = StorageKey.Fixed(Slots.PageInfo.startCursor), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection4: Selection by lazy {
        Selection(type = Types.NoteEdge, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Fixed(Slots.NoteEdge.node), plural = false, selection = selection5),
            PlanField.scalar("cursor", key = StorageKey.Fixed(Slots.NoteEdge.cursor), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection5: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Note.__typename), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestRecentNotesQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Dynamic(Slots.Query.character_bca4f9), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.linked("notes", key = StorageKey.Fixed(Slots.Character.notes_01e6d2), plural = false, connection = ConnectionPlan(key = StorageKey.Fixed(Slots.Character.__TestRecentNotes_notes_connection), slots = ConnectionSlots(connection = Types.NoteConnection, edge = Types.NoteEdge, pageInfo = Types.PageInfo)), selection = selection2),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.NoteConnection, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("edges", key = StorageKey.Fixed(Slots.NoteConnection.edges), plural = true, selection = selection4),
            PlanField.linked("pageInfo", key = StorageKey.Fixed(Slots.NoteConnection.pageInfo), plural = false, selection = selection3)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.PageInfo, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("hasPreviousPage", key = StorageKey.Fixed(Slots.PageInfo.hasPreviousPage), kind = ScalarKind.BOOL, list = false),
            PlanField.scalar("startCursor", key = StorageKey.Fixed(Slots.PageInfo.startCursor), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection4: Selection by lazy {
        Selection(type = Types.NoteEdge, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Fixed(Slots.NoteEdge.node), plural = false, selection = selection5),
            PlanField.scalar("cursor", key = StorageKey.Fixed(Slots.NoteEdge.cursor), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection5: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Note.__typename), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestRemoveNotePlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Mutation, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("removeNote", key = StorageKey.Fixed(Slots.Mutation.removeNote), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.RemoveNotePayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("removedNoteId", key = StorageKey.Fixed(Slots.RemoveNotePayload.removedNoteId), kind = ScalarKind.STRING, list = false, edit = Edit(kind = Edit.Kind.DELETE_EDGE, connections = Edit.Connections.Variable("connections"))),
            PlanField.scalar("deleted", key = StorageKey.Fixed(Slots.RemoveNotePayload.removedNoteId), kind = ScalarKind.STRING, list = false, edit = Edit(kind = Edit.Kind.DELETE_RECORD))
        ))
    }
}

private object TestRenamePlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Mutation, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("rename", key = StorageKey.Fixed(Slots.Mutation.rename), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.FavoritePayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Fixed(Slots.FavoritePayload.character), plural = false, selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestRootNotesQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("notes", key = StorageKey.Fixed(Slots.Query.notes_29a6d8), plural = false, connection = ConnectionPlan(key = StorageKey.Fixed(Slots.Query.__TestRootNotes_notes_connection), slots = ConnectionSlots(connection = Types.NoteConnection, edge = Types.NoteEdge, pageInfo = Types.PageInfo)), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.NoteConnection, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("totalCount", key = StorageKey.Fixed(Slots.NoteConnection.totalCount), kind = ScalarKind.INT, list = false),
            PlanField.linked("edges", key = StorageKey.Fixed(Slots.NoteConnection.edges), plural = true, selection = selection3),
            PlanField.linked("pageInfo", key = StorageKey.Fixed(Slots.NoteConnection.pageInfo), plural = false, selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.PageInfo, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("endCursor", key = StorageKey.Fixed(Slots.PageInfo.endCursor), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("hasNextPage", key = StorageKey.Fixed(Slots.PageInfo.hasNextPage), kind = ScalarKind.BOOL, list = false)
        ))
    }
    private val selection3: Selection by lazy {
        Selection(type = Types.NoteEdge, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("node", key = StorageKey.Fixed(Slots.NoteEdge.node), plural = false, selection = selection4),
            PlanField.scalar("cursor", key = StorageKey.Fixed(Slots.NoteEdge.cursor), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection4: Selection by lazy {
        Selection(type = Types.Note, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Note.__typename), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Note.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Note.text), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestSearchPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("search", key = StorageKey.Dynamic(Slots.Query.search_954c44), plural = true, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.SearchResult, key = listOf("id"), isAbstract = true, memberships = listOf(Selection.MembershipAnswer("__isNode", Types.Node)), variants = listOf(
            Selection.Variant(types = listOf(Types.Character), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Character.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = listOf(Types.Episode), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Episode.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Episode.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = listOf(Types.Location), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Location.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Location.id), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("name", key = StorageKey.Fixed(Slots.Location.name), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("dimension", key = StorageKey.Fixed(Slots.Location.dimension), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, condition = Types.Node, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.SearchResult.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false)
            ))
        ))
    }
}

private object TestSearchOriginsPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("search", key = StorageKey.Dynamic(Slots.Query.search_954c44), plural = true, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.SearchResult, key = listOf("id"), isAbstract = true, memberships = listOf(Selection.MembershipAnswer("__isNode", Types.Node)), variants = listOf(
            Selection.Variant(types = listOf(Types.Character), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Character.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.linked("origin", key = StorageKey.Fixed(Slots.Character.origin), plural = false, selection = selection2),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = listOf(Types.Episode, Types.Location), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.SearchResult.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, condition = Types.Node, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.SearchResult.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false)
            ))
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Location, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Location.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Location.id), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestSecretsPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("secrets", key = StorageKey.Dynamic(Slots.Query.secrets_df579e), plural = true, transient = true, selection = selection2),
            PlanField.linked("character", key = StorageKey.Fixed(Slots.Query.character_9e6829), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Literal("1"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Secret, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Secret.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("body", key = StorageKey.Fixed(Slots.Secret.body), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestSetFavoritePlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Mutation, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("setFavorite", key = StorageKey.Fixed(Slots.Mutation.setFavorite), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.FavoritePayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Fixed(Slots.FavoritePayload.character), plural = false, selection = selection2)
        ))
    }
    private val selection2: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("favorite", key = StorageKey.Fixed(Slots.Character.favorite), kind = ScalarKind.BOOL, list = false)
        ))
    }
}

private object TestSetStatusesPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Mutation, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("setLists", key = StorageKey.Fixed(Slots.Mutation.setLists), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.ListsPayload, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.scalar("statuses", key = StorageKey.Fixed(Slots.ListsPayload.statuses), kind = ScalarKind.STRING, list = true)
        ))
    }
}

private object TestStrictQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Dynamic(Slots.Query.character_bca4f9), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("species", key = StorageKey.Fixed(Slots.Character.species), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestTokenizerQueryPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("tokenizer", key = StorageKey.Fixed(Slots.Query.tokenizer), plural = false, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Tokenizer, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Tokenizer.id), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("text", key = StorageKey.Fixed(Slots.Tokenizer.text), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("strings", key = StorageKey.Fixed(Slots.Tokenizer.strings), kind = ScalarKind.STRING, list = true),
            PlanField.scalar("count", key = StorageKey.Fixed(Slots.Tokenizer.count), kind = ScalarKind.INT, list = false),
            PlanField.scalar("counts", key = StorageKey.Fixed(Slots.Tokenizer.counts), kind = ScalarKind.INT, list = true),
            PlanField.scalar("ratio", key = StorageKey.Fixed(Slots.Tokenizer.ratio), kind = ScalarKind.DOUBLE, list = false),
            PlanField.scalar("ratios", key = StorageKey.Fixed(Slots.Tokenizer.ratios), kind = ScalarKind.DOUBLE, list = true),
            PlanField.scalar("flag", key = StorageKey.Fixed(Slots.Tokenizer.flag), kind = ScalarKind.BOOL, list = false),
            PlanField.scalar("flags", key = StorageKey.Fixed(Slots.Tokenizer.flags), kind = ScalarKind.BOOL, list = true),
            PlanField.scalar("json", key = StorageKey.Fixed(Slots.Tokenizer.json), kind = ScalarKind.CUSTOM, list = false),
            PlanField.scalar("jsons", key = StorageKey.Fixed(Slots.Tokenizer.jsons), kind = ScalarKind.CUSTOM, list = true)
        ))
    }
}

private object TestTwoSpreadsPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("character", key = StorageKey.Dynamic(Slots.Query.character_bca4f9), plural = false, lookup = Lookup(type = Types.Character, key = listOf(Lookup.Key.Variable("id"))), selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.Character, key = listOf("id"), isAbstract = false, fields = listOf(
            PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("status", key = StorageKey.Fixed(Slots.Character.status), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("image", key = StorageKey.Fixed(Slots.Character.image), kind = ScalarKind.STRING, list = false),
            PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
        ))
    }
}

private object TestUnionPlan {
    val plan: Plan by lazy { Plan(root = selection0, transient = Types.transient) }
    private val selection0: Selection by lazy {
        Selection(type = Types.Query, key = listOf(), isAbstract = false, fields = listOf(
            PlanField.linked("search", key = StorageKey.Dynamic(Slots.Query.search_954c44), plural = true, selection = selection1)
        ))
    }
    private val selection1: Selection by lazy {
        Selection(type = Types.SearchResult, key = listOf("id"), isAbstract = true, memberships = listOf(Selection.MembershipAnswer("__isNamed", Types.Named), Selection.MembershipAnswer("__isNode", Types.Node)), variants = listOf(
            Selection.Variant(types = listOf(Types.Character), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Character.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("label", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("status", key = StorageKey.Fixed(Slots.Character.status), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("name", key = StorageKey.Fixed(Slots.Character.name), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Character.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = listOf(Types.Episode), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Episode.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("air_date", key = StorageKey.Fixed(Slots.Episode.air_date), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Episode.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = listOf(Types.Location), key = listOf("id"), fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.Location.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("label", key = StorageKey.Fixed(Slots.Location.dimension), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("type", key = StorageKey.Fixed(Slots.Location.type), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("name", key = StorageKey.Fixed(Slots.Location.name), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.Location.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, condition = Types.Named, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("name", key = StorageKey.Fixed(Slots.SearchResult.name), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, condition = Types.Node, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false),
                PlanField.scalar("id", key = StorageKey.Fixed(Slots.SearchResult.id), kind = ScalarKind.STRING, list = false)
            )),
            Selection.Variant(types = null, fields = listOf(
                PlanField.scalar("__typename", key = StorageKey.Fixed(Slots.SearchResult.__typename), kind = ScalarKind.STRING, list = false)
            ))
        ))
    }
}

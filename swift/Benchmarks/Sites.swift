@_spi(Generated) import Baton
import Foundation
import Observation

/// A character row of twenty fields as a configurable screen reads it,
/// three ways over the same records: every field under a constant key; ten
/// of them dynamic sites, seven fields under a condition on a variable of
/// their own and three keys with variables; and all twenty dynamic, fourteen
/// conditions and six keys with variables. An owner settles each site by a
/// scan of the sites it has met, so what the three cost apart is the cost
/// of the sites.
@MainActor
struct SiteDocuments {
    @Query("""
        query BenchSitesNone {
          characters(page: 1) {
            results {
              id name status species type gender image created favorite
              origin { name type dimension }
              location { name type dimension }
              notes(first: 5) { totalCount }
              recentNotes: notes(last: 3) { totalCount }
              pagedNotes: notes(first: 10, after: "n10") { totalCount }
              friends(page: 1, perPage: 12) { pageInfo { currentPage } }
              nextFriends: friends(page: 2, perPage: 12) { pageInfo { currentPage } }
              favoriteFriends: friends(page: 1, perPage: 4) { pageInfo { currentPage } }
            }
          }
        }
        """)
    var none: BenchSitesNone

    @Query("""
        query BenchSitesTen(
          $notesFirst: Int, $recentLast: Int, $pageSize: Int, $after: String,
          $withName: Boolean!, $withStatus: Boolean!, $hideSpecies: Boolean!, $hideType: Boolean!,
          $withGender: Boolean!, $withImage: Boolean!, $hideCreated: Boolean!
        ) {
          characters(page: 1) {
            results {
              id
              name @include(if: $withName)
              status @include(if: $withStatus)
              species @skip(if: $hideSpecies)
              type @skip(if: $hideType)
              gender @include(if: $withGender)
              image @include(if: $withImage)
              created @skip(if: $hideCreated)
              favorite
              origin { name type dimension }
              location { name type dimension }
              notes(first: $notesFirst) { totalCount }
              recentNotes: notes(last: $recentLast) { totalCount }
              pagedNotes: notes(first: $pageSize, after: $after) { totalCount }
              friends(page: 1, perPage: 12) { pageInfo { currentPage } }
              nextFriends: friends(page: 2, perPage: 12) { pageInfo { currentPage } }
              favoriteFriends: friends(page: 1, perPage: 4) { pageInfo { currentPage } }
            }
          }
        }
        """)
    var ten: BenchSitesTen

    @Query("""
        query BenchSitesTwenty(
          $notesFirst: Int, $recentLast: Int, $pageSize: Int, $after: String,
          $friendsPage: Int, $nextPage: Int, $perPage: Int, $favoritesPerPage: Int,
          $withName: Boolean!, $withStatus: Boolean!, $hideSpecies: Boolean!, $hideType: Boolean!,
          $withGender: Boolean!, $withImage: Boolean!, $hideCreated: Boolean!, $withFavorite: Boolean!,
          $withOriginName: Boolean!, $withOriginType: Boolean!, $hideOriginDimension: Boolean!,
          $withLocationName: Boolean!, $withLocationType: Boolean!, $hideLocationDimension: Boolean!
        ) {
          characters(page: 1) {
            results {
              id
              name @include(if: $withName)
              status @include(if: $withStatus)
              species @skip(if: $hideSpecies)
              type @skip(if: $hideType)
              gender @include(if: $withGender)
              image @include(if: $withImage)
              created @skip(if: $hideCreated)
              favorite @include(if: $withFavorite)
              origin {
                name @include(if: $withOriginName)
                type @include(if: $withOriginType)
                dimension @skip(if: $hideOriginDimension)
              }
              location {
                name @include(if: $withLocationName)
                type @include(if: $withLocationType)
                dimension @skip(if: $hideLocationDimension)
              }
              notes(first: $notesFirst) { totalCount }
              recentNotes: notes(last: $recentLast) { totalCount }
              pagedNotes: notes(first: $pageSize, after: $after) { totalCount }
              friends(page: $friendsPage, perPage: $perPage) { pageInfo { currentPage } }
              nextFriends: friends(page: $nextPage, perPage: $perPage) { pageInfo { currentPage } }
              favoriteFriends: friends(page: $friendsPage, perPage: $favoritesPerPage) { pageInfo { currentPage } }
            }
          }
        }
        """)
    var twenty: BenchSitesTwenty
}

/// The twenty characters the three lenses read, committed by hand: every
/// field each lens selects, under the response keys they share.
func siteRows(_ count: Int) -> Data {
    let rows = (0..<count).map { index in
        #"{"id":"site\#(index)","name":"Character \#(index)","status":"Alive","species":"Human","type":"","gender":"Female","#
            + #""image":"https://rickandmortyapi.com/api/character/avatar/\#(index + 1).jpeg","created":"2017-11-04T18:48:46.250Z","favorite":true,"#
            + #""origin":{"name":"Earth (C-137)","type":"Planet","dimension":"Dimension C-137"},"#
            + #""location":{"name":"Citadel of Ricks","type":"Space station","dimension":"unknown"},"#
            + #""notes":{"totalCount":\#(index)},"recentNotes":{"totalCount":3},"pagedNotes":{"totalCount":\#(index)},"#
            + #""friends":{"pageInfo":{"currentPage":1}},"nextFriends":{"pageInfo":{"currentPage":2}},"favoriteFriends":{"pageInfo":{"currentPage":1}}}"#
    }
    return Data(#"{"data":{"characters":{"results":[\#(rows.joined(separator: ","))]}}}"#.utf8)
}

/// What a row's body reads: twenty fields, each once, folded into a number
/// so nothing is skipped. The three lenses' rows have the same accessors.
@MainActor
@inline(__always)
func readSites(name: String?, status: String?, species: String?, type: String?, gender: String?, image: String?, created: String?, favorite: Bool?) -> Int {
    var sink = name?.utf8.count ?? 0
    sink &+= status?.utf8.count ?? 0
    sink &+= species?.utf8.count ?? 0
    sink &+= type?.utf8.count ?? 0
    sink &+= gender?.utf8.count ?? 0
    sink &+= image?.utf8.count ?? 0
    sink &+= created?.utf8.count ?? 0
    sink &+= favorite == true ? 1 : 0
    return sink
}

@MainActor
func sitesBench() throws {
    let rowCount = 20
    let fields = 20
    let twenty = BenchSitesTwenty(
        notesFirst: 5, recentLast: 3, pageSize: 10, after: "n10",
        friendsPage: 1, nextPage: 2, perPage: 12, favoritesPerPage: 4,
        withName: true, withStatus: true, hideSpecies: false, hideType: false,
        withGender: true, withImage: true, hideCreated: false, withFavorite: true,
        withOriginName: true, withOriginType: true, hideOriginDimension: false,
        withLocationName: true, withLocationType: true, hideLocationDimension: false)
    let ten = BenchSitesTen(
        notesFirst: 5, recentLast: 3, pageSize: 10, after: "n10",
        withName: true, withStatus: true, hideSpecies: false, hideType: false,
        withGender: true, withImage: true, hideCreated: false)
    let none = BenchSitesNone()
    let store = Store()
    // Each lens's plan is resolved in the store, as its operation's fetch or
    // check would: the constants the plans name are then the store's before
    // the commit writes the renderings of the same keys.
    _ = BenchSitesNone.plan.resolve(none.variables, in: store.keys)
    _ = BenchSitesTen.plan.resolve(ten.variables, in: store.keys)
    store.commit(try Ingest.normalize(siteRows(rowCount), plan: BenchSitesTwenty.plan.resolve(twenty.variables, in: store.keys), rootKey: Store.rootKey))

    let noneRows = Array(try requireValue(try requireValue(BenchSitesNone.Data(anchor: Anchor(record: store.root, variables: none.variables, store: store)).characters).results))
    let tenRows = Array(try requireValue(try requireValue(BenchSitesTen.Data(anchor: Anchor(record: store.root, variables: ten.variables, store: store)).characters).results))
    let twentyRows = Array(try requireValue(try requireValue(BenchSitesTwenty.Data(anchor: Anchor(record: store.root, variables: twenty.variables, store: store)).characters).results))

    func readNone(_ row: BenchSitesNone.Data.Characters.Results) -> Int {
        var sink = readSites(name: row.name, status: row.status, species: row.species, type: row.type, gender: row.gender, image: row.image, created: row.created, favorite: row.favorite)
        let origin = row.origin
        sink &+= (origin?.name?.utf8.count ?? 0) &+ (origin?.type?.utf8.count ?? 0) &+ (origin?.dimension?.utf8.count ?? 0)
        let location = row.location
        sink &+= (location?.name?.utf8.count ?? 0) &+ (location?.type?.utf8.count ?? 0) &+ (location?.dimension?.utf8.count ?? 0)
        sink &+= row.notes.totalCount &+ row.recentNotes.totalCount &+ row.pagedNotes.totalCount
        sink &+= (row.friends?.pageInfo.currentPage ?? 0) &+ (row.nextFriends?.pageInfo.currentPage ?? 0) &+ (row.favoriteFriends?.pageInfo.currentPage ?? 0)
        return sink
    }
    func readTen(_ row: BenchSitesTen.Data.Characters.Results) -> Int {
        var sink = readSites(name: row.name, status: row.status, species: row.species, type: row.type, gender: row.gender, image: row.image, created: row.created, favorite: row.favorite)
        let origin = row.origin
        sink &+= (origin?.name?.utf8.count ?? 0) &+ (origin?.type?.utf8.count ?? 0) &+ (origin?.dimension?.utf8.count ?? 0)
        let location = row.location
        sink &+= (location?.name?.utf8.count ?? 0) &+ (location?.type?.utf8.count ?? 0) &+ (location?.dimension?.utf8.count ?? 0)
        sink &+= row.notes.totalCount &+ row.recentNotes.totalCount &+ row.pagedNotes.totalCount
        sink &+= (row.friends?.pageInfo.currentPage ?? 0) &+ (row.nextFriends?.pageInfo.currentPage ?? 0) &+ (row.favoriteFriends?.pageInfo.currentPage ?? 0)
        return sink
    }
    func readTwenty(_ row: BenchSitesTwenty.Data.Characters.Results) -> Int {
        var sink = readSites(name: row.name, status: row.status, species: row.species, type: row.type, gender: row.gender, image: row.image, created: row.created, favorite: row.favorite)
        let origin = row.origin
        sink &+= (origin?.name?.utf8.count ?? 0) &+ (origin?.type?.utf8.count ?? 0) &+ (origin?.dimension?.utf8.count ?? 0)
        let location = row.location
        sink &+= (location?.name?.utf8.count ?? 0) &+ (location?.type?.utf8.count ?? 0) &+ (location?.dimension?.utf8.count ?? 0)
        sink &+= row.notes.totalCount &+ row.recentNotes.totalCount &+ row.pagedNotes.totalCount
        sink &+= (row.friends?.pageInfo.currentPage ?? 0) &+ (row.nextFriends?.pageInfo.currentPage ?? 0) &+ (row.favoriteFriends?.pageInfo.currentPage ?? 0)
        return sink
    }

    // The three readings fold the same values, so a lens that read a field
    // as missing would show here rather than as a faster row.
    let expected = twentyRows.reduce(0) { $0 &+ readTwenty($1) }
    guard tenRows.reduce(0, { $0 &+ readTen($1) }) == expected, noneRows.reduce(0, { $0 &+ readNone($1) }) == expected else {
        throw MissingBenchData()
    }

    let reads = rowCount * fields
    measure("untracked, 20 fields under constant keys, per field", iterations: 50, ops: reads * 20) {
        var sink = 0
        for _ in 0..<20 { for row in noneRows { sink &+= readNone(row) } }
        if sink == 42 { print("") }
    }
    measure("untracked, 20 fields, 10 dynamic sites, per field", iterations: 50, ops: reads * 20) {
        var sink = 0
        for _ in 0..<20 { for row in tenRows { sink &+= readTen(row) } }
        if sink == 42 { print("") }
    }
    measure("untracked, 20 fields, 20 dynamic sites, per field", iterations: 50, ops: reads * 20) {
        var sink = 0
        for _ in 0..<20 { for row in twentyRows { sink &+= readTwenty(row) } }
        if sink == 42 { print("") }
    }
    measure("tracked row body, 20 fields under constant keys, per field", iterations: 50, ops: reads) {
        var sink = 0
        for row in noneRows { withObservationTracking { sink &+= readNone(row) } onChange: {} }
        if sink == 42 { print("") }
    }
    measure("tracked row body, 20 fields, 10 dynamic sites, per field", iterations: 50, ops: reads) {
        var sink = 0
        for row in tenRows { withObservationTracking { sink &+= readTen(row) } onChange: {} }
        if sink == 42 { print("") }
    }
    measure("tracked row body, 20 fields, 20 dynamic sites, per field", iterations: 50, ops: reads) {
        var sink = 0
        for row in twentyRows { withObservationTracking { sink &+= readTwenty(row) } onChange: {} }
        if sink == 42 { print("") }
    }
}

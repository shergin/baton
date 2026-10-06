import Baton

/// Documents over the types `baton.json` keys by fields other than `id`:
/// `Asset` by `uuid` and `Quote` by `base` and `quote`. Two of them leave
/// the key out, which the compiler selects; two reach the same records by
/// another path, one with the key after a link, so that a record is one
/// record however a response reached it.
@MainActor
struct IdentityDocuments {
    @Query("""
        query TestAssetsQuery { assets { name size } }
        """)
    var assets: TestAssetsQuery

    @Query("""
        query TestAssetQuery($uuid: String!) { asset(uuid: $uuid) { owner { name } uuid name } }
        """)
    var asset: TestAssetQuery

    @Query("""
        query TestQuotesQuery { quotes { rate } }
        """)
    var quotes: TestQuotesQuery

    @Query("""
        query TestQuoteQuery($base: String!, $quote: String!) { quote(base: $base, quote: $quote) { base quote rate } }
        """)
    var quote: TestQuoteQuery
}

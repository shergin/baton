import Baton

/// The documents of an app whose schema is two files under `schema/`, named
/// by `schemaDir`: the GraphQL server's and the feed's, a backend of another
/// protocol whose field the app's own transport answers. `QuoteTicks` asks
/// for the feed's field and for the builder its transport writes each event
/// with; `TradeTicks` is a subscription the server owns. `LiveQuotes` is
/// client-only, over the client list `client.graphql` declares: a service
/// commits every pending quote through it in one payload per interval, and
/// it is never sent.
@MainActor
public struct FeedDocuments {
    @Query("""
        query QuoteQuery($symbol: ID!) @raw_response_type {
          quote(symbol: $symbol) { id name price updatedAt }
        }
        """)
    var quote: QuoteQuery

    @Subscription("""
        subscription QuoteTicks($symbol: ID!) @raw_response_type {
          quoteChanged(symbol: $symbol) { id price updatedAt }
        }
        """)
    var quoteTicks: QuoteTicks

    @Subscription("""
        subscription TradeTicks($symbol: ID!) {
          tradeExecuted(symbol: $symbol) { id size quote { id price } }
        }
        """)
    var tradeTicks: TradeTicks

    @Query("""
        query LiveQuotes @raw_response_type {
          liveQuotes { id price updatedAt }
        }
        """)
    var liveQuotes: LiveQuotes

    @Mutation("""
        mutation SetAlert($symbol: ID!, $price: Float!) @raw_response_type {
          setAlert(symbol: $symbol, price: $price) { id alertPrice }
        }
        """)
    var setAlert: SetAlert.Action

    @Mutation("""
        mutation SetAlertPlain($symbol: ID!, $price: Float!) {
          setAlert(symbol: $symbol, price: $price) { id alertPrice }
        }
        """)
    var setAlertPlain: SetAlertPlain.Action
}

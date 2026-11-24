package baton.feed

import baton.Mutation
import baton.Query
import baton.Subscription

/**
 * The documents of an app whose schema is two files under `schema/`, named
 * by `schemaDir`: the GraphQL server's and the feed's, a backend of another
 * protocol whose field the app's own transport answers. `QuoteTicks` asks
 * for the feed's field and for the builder its transport writes each event
 * with; `TradeTicks` is a subscription the server owns. `LiveQuotes` is
 * client-only, over the client list `client.graphql` declares: a service
 * commits every pending quote through it in one payload per interval, and it
 * is never sent. The same text as
 * `swift/Tests/FeedDocuments/FeedDocuments.swift`.
 */
@Query(
    $$"""
    query QuoteQuery($symbol: ID!) @raw_response_type {
      quote(symbol: $symbol) { id name price updatedAt }
    }
    """,
)
@Subscription(
    $$"""
    subscription QuoteTicks($symbol: ID!) @raw_response_type {
      quoteChanged(symbol: $symbol) { id price updatedAt }
    }
    """,
)
@Subscription(
    $$"""
    subscription TradeTicks($symbol: ID!) {
      tradeExecuted(symbol: $symbol) { id size quote { id price } }
    }
    """,
)
@Query(
    $$"""
    query LiveQuotes @raw_response_type {
      liveQuotes { id price updatedAt }
    }
    """,
)
@Mutation(
    $$"""
    mutation SetAlert($symbol: ID!, $price: Float!) @raw_response_type {
      setAlert(symbol: $symbol, price: $price) { id alertPrice }
    }
    """,
)
@Mutation(
    $$"""
    mutation SetAlertPlain($symbol: ID!, $price: Float!) {
      setAlert(symbol: $symbol, price: $price) { id alertPrice }
    }
    """,
)
object FeedDocuments

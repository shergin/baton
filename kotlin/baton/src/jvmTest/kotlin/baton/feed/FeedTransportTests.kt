package baton.feed

import androidx.compose.runtime.snapshots.Snapshot
import baton.Environment
import baton.Json
import baton.MutationAction
import baton.OperationKind
import baton.Payload
import baton.Phase
import baton.Request
import baton.Store
import baton.Stream
import baton.Transport
import baton.Variable
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * The app's client for the feed's own protocol, as test data: each
 * collection of [ticks] opens a stream the test drives, and the feed records
 * the symbol it was asked for and whether its reader ended the stream.
 */
class QuoteFeed {
    class Tick(val price: Double, val time: String)

    private val channels = ArrayList<Channel<Tick>>()
    private val terminated = ArrayList<Boolean>()

    /** The symbols it was asked for, in order. */
    val symbols = ArrayList<String>()

    /** How many times the feed's stream was opened. */
    val opens: Int get() = channels.size

    fun ticks(symbol: String): Flow<Tick> = flow {
        val channel = Channel<Tick>(Channel.UNLIMITED)
        val index = channels.size
        channels.add(channel)
        symbols.add(symbol)
        terminated.add(false)
        try {
            for (tick in channel) emit(tick)
        } finally {
            terminated[index] = true
        }
    }

    /** Whether the stream of the [index]th open has ended. */
    fun ended(index: Int): Boolean = terminated[index]

    /** Delivers a tick on the newest stream. */
    fun tick(price: Double, time: String) {
        channels.last().trySend(Tick(price, time))
    }

    /** Breaks the newest stream, as a dropped connection does. */
    fun drop() {
        channels.last().close(FeedDropped())
    }
}

/** The feed's connection dropped. */
class FeedDropped : Exception("the feed dropped")

/**
 * The transport an app writes for a backend of another protocol: the feed's
 * subscription is answered from the feed's ticks, each written with the
 * operation's raw response, and every other request goes to the server's
 * transport. The code `docs/recipes` quotes.
 */
class FeedTransport(private val server: Transport, private val feed: QuoteFeed) : Transport {
    override fun send(request: Request): Flow<ByteArray> {
        val symbol = (request.variables["symbol"] as? Variable.String)?.value
        if (request.operationName != QuoteTicks.name || symbol == null) return server.send(request)
        return feed.ticks(symbol).map { tick ->
            QuoteTicks.RawResponse(quoteChanged = QuoteTicks.RawResponse.QuoteChanged(id = symbol, price = tick.price, updatedAt = tick.time)).payload.bytes
        }
    }
}

/**
 * The transport of the app's own, end to end: the documents in
 * `FeedDocuments.kt`, over the schema directory beside them, as
 * `swift/Tests/BatonFeedTests/FeedTransportTests.swift` proves them.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedTransportTests {
    /** What the GraphQL server answers for the quote: the response a server writes, not a builder's. */
    private val serverQuote = """{"data":{"quote":{"id":"AAPL","name":"Apple","price":100.0,"updatedAt":"09:30"}}}""".encodeToByteArray()

    /** A trade the server streams itself. */
    private val serverTrade = """{"data":{"tradeExecuted":{"id":"T1","size":10,"quote":{"id":"AAPL","price":99.5}}}}""".encodeToByteArray()

    private fun TestScope.environment(transport: Transport, subscriptions: Transport? = null): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, subscriptions, Store(), dispatcher, dispatcher).also { it.log = null }
    }

    /** The quote as the query's handle reads it, once the server answered. */
    private suspend fun TestScope.readQuote(environment: Environment): Pair<QuoteQuery.Data, baton.Hold> {
        val handle = environment.handle(QuoteQuery(symbol = "AAPL"))
        val hold = handle.retain()
        runCurrent()
        handle.settle()
        return assertIs<Phase.Ready<QuoteQuery.Data>>(handle.phase, "the quote arrives").data to hold
    }

    /** The states [read] registers in a snapshot that observes its reads. */
    private fun statesRead(read: () -> Unit): Set<Any> {
        val states = HashSet<Any>()
        val snapshot = Snapshot.takeSnapshot { states.add(it) }
        try {
            snapshot.enter(read)
        } finally {
            snapshot.dispose()
        }
        return states
    }

    /** Whether the apply notifications sent while [writes] runs touch one of [states]: whether a body that read them is told. */
    private inline fun told(states: Set<Any>, writes: () -> Unit): Boolean {
        var told = false
        val observer = Snapshot.registerApplyObserver { changed, _ -> if (changed.any { it in states }) told = true }
        try {
            writes()
            Snapshot.sendApplyNotifications()
        } finally {
            observer.dispose()
        }
        return told
    }

    @Test
    fun `a subscription to the feed's field is answered by the app's transport from the feed's ticks, and each tick merges into the record the query reads, so the query's view sees it`() = runTest {
        val http = ScriptedTransport(mapOf(QuoteQuery.name to serverQuote))
        val socket = ScriptedTransport()
        val feed = QuoteFeed()
        val environment = environment(http, FeedTransport(socket, feed))
        val (quote, hold) = readQuote(environment)
        assertEquals(100.0, quote.quote?.price)

        val priceStates = statesRead { quote.quote?.price }
        val live = environment.subscriptionHandle(QuoteTicks(symbol = "AAPL"))
        val liveHold = live.retain()
        runCurrent()
        assertEquals(1, feed.opens)
        assertEquals(listOf("AAPL"), feed.symbols, "the transport read the symbol from the request's variables")

        val tickTold = told(priceStates) {
            feed.tick(price = 101.5, time = "09:31")
            runCurrent()
        }
        assertEquals(1, live.events)
        assertEquals(101.5, live.latest?.quoteChanged?.price)
        assertEquals("09:31", live.latest?.quoteChanged?.updatedAt)
        assertTrue(tickTold, "the tick tells the query's view of the price")
        assertEquals(101.5, quote.quote?.price)
        assertEquals("09:31", quote.quote?.updatedAt)
        assertEquals("Apple", quote.quote?.name, "a field the tick does not carry stays as the server wrote it")

        feed.tick(price = 102.0, time = "09:32")
        runCurrent()
        assertEquals(2, live.events)
        assertEquals(102.0, quote.quote?.price)
        assertTrue(socket.requests.isEmpty(), "the feed's subscription never reached the server's socket")
        assertEquals(listOf(QuoteQuery.name), http.requests.map { it.operationName })
        liveHold.release()
        hold.release()
        environment.end()
    }

    @Test
    fun `a query and a subscription the server owns pass through the app's transport to the server's, with the request as the environment wrote it`() = runTest {
        val http = ScriptedTransport(mapOf(QuoteQuery.name to serverQuote))
        val socket = ScriptedTransport()
        val feed = QuoteFeed()
        val environment = environment(FeedTransport(http, feed), FeedTransport(socket, feed))
        val (quote, hold) = readQuote(environment)
        assertEquals("Apple", quote.quote?.name)
        val query = http.requests.single()
        assertEquals(QuoteQuery.name, query.operationName)
        assertEquals(OperationKind.QUERY, query.kind)
        assertEquals(QuoteQuery.document, query.document)
        assertEquals(QuoteQuery(symbol = "AAPL").variables, query.variables)

        val trades = environment.subscriptionHandle(TradeTicks(symbol = "AAPL"))
        val tradesHold = trades.retain()
        runCurrent()
        val driven = socket.driven.single()
        assertEquals(TradeTicks.name, driven.request.operationName)
        assertEquals(OperationKind.SUBSCRIPTION, driven.request.kind)
        assertEquals(TradeTicks.document, driven.request.document)
        assertEquals(TradeTicks(symbol = "AAPL").variables, driven.request.variables)
        driven.send(serverTrade)
        runCurrent()
        assertEquals(1, trades.events)
        assertEquals(10, trades.latest?.tradeExecuted?.size)
        assertEquals(99.5, quote.quote?.price, "the server's own subscription merges into the same record")
        assertEquals(0, feed.opens, "no request but the feed's subscription reached the feed")
        tradesHold.release()
        hold.release()
        environment.end()
    }

    @Test
    fun `a raw response committed through the door writes the fields it gives and leaves a field of the record it does not give untouched`() = runTest {
        val environment = environment(ScriptedTransport(mapOf(QuoteQuery.name to serverQuote)))
        val (quote, hold) = readQuote(environment)
        val priceStates = statesRead { quote.quote?.price }

        val response = QuoteQuery.RawResponse(quote = QuoteQuery.RawResponse.Quote(id = "AAPL", price = 103.25, updatedAt = "09:33"))
        val commitTold = told(priceStates) {
            val commit = async { environment.commitPayload(QuoteQuery(symbol = "AAPL"), response.payload) }
            runCurrent()
            commit.await()
        }
        assertTrue(commitTold)
        assertEquals(103.25, quote.quote?.price)
        assertEquals("09:33", quote.quote?.updatedAt)
        assertEquals("Apple", quote.quote?.name, "the raw response left out the name, so the record keeps the server's")
        hold.release()
        environment.end()
    }

    @Test
    fun `a raw response renders the response body a server writes, the fields given under data and the fields left out absent`() {
        val response = QuoteTicks.RawResponse(quoteChanged = QuoteTicks.RawResponse.QuoteChanged(id = "AAPL", price = 101.5))
        @Suppress("UNCHECKED_CAST")
        val body = Json.parse(response.payload.bytes.decodeToString()) as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val quote = assertNotNull((body["data"] as Map<String, Any?>)["quoteChanged"] as Map<String, Any?>)
        assertEquals("AAPL", quote["id"])
        assertEquals(101.5, (quote["price"] as Number).toDouble())
        assertEquals(setOf("id", "price"), quote.keys, "updatedAt was not given, so the body leaves it out")
    }

    @Test
    fun `the directive is not sent, so the subscription's and the query's text carry their fields and no raw_response_type`() {
        val subscription = assertNotNull(QuoteTicks.text)
        assertTrue(subscription.contains("quoteChanged(symbol:\$symbol)"))
        assertFalse(subscription.contains("raw_response_type"))
        assertFalse(assertNotNull(QuoteQuery.text).contains("raw_response_type"))
    }

    @Test
    fun `a feed stream that fails is opened again by the handle after its backoff, as a built-in transport's is, and its ticks go on`() = runTest {
        val feed = QuoteFeed()
        val environment = environment(ScriptedTransport(), FeedTransport(ScriptedTransport(), feed))
        val live = environment.subscriptionHandle(QuoteTicks(symbol = "AAPL"))
        val hold = live.retain()
        runCurrent()
        assertEquals(1, feed.opens)
        feed.tick(price = 101.0, time = "09:31")
        runCurrent()
        assertEquals(1, live.events)

        feed.drop()
        runCurrent()
        assertIs<Stream.Waiting>(live.stream)
        assertIs<FeedDropped>(live.error, "the feed's own error is the handle's")
        assertTrue(feed.ended(0))
        advanceTimeBy(2.seconds)
        runCurrent()
        assertEquals(2, feed.opens, "the backoff opened the feed again")
        assertEquals(1, live.resumptions)
        assertEquals(listOf("AAPL", "AAPL"), feed.symbols)
        feed.tick(price = 104.0, time = "09:34")
        runCurrent()
        assertEquals(2, live.events)
        assertEquals(104.0, live.latest?.quoteChanged?.price)
        assertNull(live.error)
        hold.release()
        environment.end()
    }

    @Test
    fun `releasing the handle ends the feed's stream through the app's transport, and the feed is not opened again`() = runTest {
        val feed = QuoteFeed()
        val environment = environment(ScriptedTransport(), FeedTransport(ScriptedTransport(), feed))
        val live = environment.subscriptionHandle(QuoteTicks(symbol = "AAPL"))
        val hold = live.retain()
        runCurrent()
        feed.tick(price = 101.0, time = "09:31")
        runCurrent()
        assertEquals(1, live.events)
        assertFalse(feed.ended(0))

        hold.release()
        runCurrent()
        assertEquals(Stream.Idle, live.stream)
        assertTrue(feed.ended(0), "the release cancelled the collection, which ended the feed's stream")
        advanceTimeBy(60.seconds)
        runCurrent()
        assertEquals(1, feed.opens)
        environment.end()
    }

    @Test
    fun `a mutation carrying raw_response_type keeps its optimistic response and its action, the same as one without it`() = runTest {
        assertEquals(SetAlertPlain.text?.replace("SetAlertPlain", "SetAlert"), SetAlert.text)
        val optimistic = SetAlert.OptimisticResponse(setAlert = SetAlert.OptimisticResponse.SetAlert(id = "AAPL", alertPrice = 150.0))
        val plain = SetAlertPlain.OptimisticResponse(setAlert = SetAlertPlain.OptimisticResponse.SetAlert(id = "AAPL", alertPrice = 150.0))
        assertEquals<Payload>(plain.payload, optimistic.payload)

        val transport = ScriptedTransport(mapOf(QuoteQuery.name to serverQuote))
        val environment = environment(transport)
        val (quote, hold) = readQuote(environment)
        val action = MutationAction<SetAlert, SetAlert.Data>(environment)
        val mutation = async { action(symbol = "AAPL", price = 150.0, optimistic = optimistic) }
        runCurrent()
        assertTrue(action.isInFlight)
        assertEquals(1, environment.store.optimisticLayerCount)
        transport.held.single().respond("""{"data":{"setAlert":{"id":"AAPL","alertPrice":150.0}}}""".encodeToByteArray())
        runCurrent()
        val data = mutation.await()
        assertEquals(150.0, data.setAlert?.alertPrice)
        assertFalse(action.isInFlight)
        assertEquals(0, environment.store.optimisticLayerCount)
        assertEquals("Apple", quote.quote?.name)
        hold.release()
        environment.end()
    }
}

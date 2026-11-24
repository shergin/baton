package baton.feed

import baton.Anchor
import baton.Environment
import baton.FetchPolicy
import baton.LogEvent
import baton.Owner
import baton.Payload
import baton.Persistence
import baton.Phase
import baton.Store
import baton.TemporaryImage
import baton.Transport
import baton.imageDriver
import baton.testing.ScriptedTransport
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** One tick of the feed, decoded off the main thread: the symbol it names, its price and its time. */
class QuoteTick(val symbol: String, val price: Double, val time: String)

/** The newest tick of each symbol since the last drain. The code the docs quote. */
class QuotePacer {
    private val pending = HashMap<String, QuoteTick>()

    fun offer(tick: QuoteTick) = synchronized(pending) { pending[tick.symbol] = tick }

    fun drain(): List<QuoteTick> = synchronized(pending) { pending.values.toList().also { pending.clear() } }
}

/**
 * Commits what the pacer holds once per interval: every pending quote in one
 * payload, through the one client-only query, so a stream costs the main
 * thread one commit per interval whatever its rate. The code the docs quote.
 */
suspend fun commitPaced(pacer: QuotePacer, environment: Environment, interval: Duration) {
    while (true) {
        delay(interval)
        val pending = pacer.drain()
        if (pending.isEmpty()) continue
        val response = LiveQuotes.RawResponse(liveQuotes = pending.map { LiveQuotes.RawResponse.LiveQuotes(id = it.symbol, price = it.price, updatedAt = it.time) })
        environment.commitPayload(LiveQuotes(), response.payload)
    }
}

/**
 * The pacer that lists every known symbol in every commit, in the order each
 * first ticked: the list only grows, so no commit drops a link. The code the
 * docs quote.
 */
class ListingPacer {
    private val known = LinkedHashMap<String, QuoteTick?>()
    private var ticked = false

    fun offer(tick: QuoteTick) = synchronized(known) {
        known[tick.symbol] = tick
        ticked = true
    }

    fun drain(): List<Pair<String, QuoteTick?>> = synchronized(known) {
        if (!ticked) return emptyList()
        ticked = false
        known.entries.map { it.key to it.value }.also { known.replaceAll { _, _ -> null } }
    }
}

/**
 * The paced loop over the listing pacer: a symbol that did not tick is
 * written by its id alone, which leaves its fields as they are. The loop body
 * is the code the docs quote.
 */
suspend fun commitListing(pacer: ListingPacer, environment: Environment, interval: Duration) {
    while (true) {
        delay(interval)
        val listed = pacer.drain()
        if (listed.isEmpty()) continue
        val response = LiveQuotes.RawResponse(liveQuotes = listed.map { (symbol, tick) ->
            if (tick == null) LiveQuotes.RawResponse.LiveQuotes(id = symbol)
            else LiveQuotes.RawResponse.LiveQuotes(id = symbol, price = tick.price, updatedAt = tick.time)
        })
        environment.commitPayload(LiveQuotes(), response.payload)
    }
}

/** The app's own feed client, as test data: [ticks] yields what the test sends, as a client decoding each message off the main thread would. */
class LiveFeed {
    private val channel = Channel<QuoteTick>(Channel.UNLIMITED)

    fun ticks(): Flow<QuoteTick> = channel.consumeAsFlow()

    fun send(tick: QuoteTick) {
        channel.trySend(tick)
    }
}

/**
 * The paced shape of a service that commits a fast feed: ticks decoded off
 * the main thread, the newest per symbol kept, and once per interval one
 * payload through `LiveQuotes`, a client-only query whose one root field is a
 * client list of the server's own type, transient in `baton.json`. Mirrors
 * `swift/Tests/BatonFeedTests/PacedCommitTests.swift`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PacedCommitTests {
    private val image = TemporaryImage()

    @AfterTest
    fun deleteTheImage() {
        image.delete()
    }

    /** What the GraphQL server answers for the quote. */
    private val serverQuote = """{"data":{"quote":{"id":"AAPL","name":"Apple","price":100.0,"updatedAt":"09:30"}}}""".encodeToByteArray()

    private fun TestScope.environment(transport: Transport, subscriptions: Transport? = null, store: Store = Store()): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, subscriptions, store, dispatcher, dispatcher).also { it.log = null }
    }

    /** The quote as the query's handle reads it, once the server answered. */
    private suspend fun TestScope.readQuote(environment: Environment): Pair<QuoteQuery.Data, baton.Hold> {
        val handle = environment.handle(QuoteQuery(symbol = "AAPL"))
        val hold = handle.retain()
        runCurrent()
        handle.settle()
        return assertIs<Phase.Ready<QuoteQuery.Data>>(handle.phase, "the quote arrives").data to hold
    }

    /** The quote record of [symbol] through the server query's lens, for a symbol the server was never asked for, whose root cell is not written. */
    private fun recordQuote(environment: Environment, symbol: String): QuoteQuery.Data.Quote? {
        val record = environment.store.existing("Quote:$symbol") ?: return null
        return QuoteQuery.Data.Quote(Anchor(record, Owner(QuoteQuery(symbol = symbol).variables, environment.store)))
    }

    /** One payload of `LiveQuotes` carrying the ticks. */
    private fun payload(ticks: List<QuoteTick>): Payload =
        LiveQuotes.RawResponse(liveQuotes = ticks.map { LiveQuotes.RawResponse.LiveQuotes(id = it.symbol, price = it.price, updatedAt = it.time) }).payload

    /** The first column of the first row a query of the image returns, as an integer; null for no row or a null. */
    private fun integer(sql: String): Long? {
        val connection = imageDriver().open(image.path)
        try {
            return connection.prepare(sql).use { statement ->
                if (!statement.step() || statement.isNull(0)) null else statement.getLong(0)
            }
        } finally {
            connection.close()
        }
    }

    @Test
    fun `the list query over the client extension compiles as client-only beside the schema directory, and nothing is sent for it, not by an attach, a commit, an invalidation or a revalidation`() = runTest {
        assertTrue(LiveQuotes.isClientOnly)
        assertFalse(QuoteQuery.isClientOnly)
        val http = ScriptedTransport()
        val socket = ScriptedTransport()
        val environment = environment(http, socket)
        val handle = environment.handle(LiveQuotes(), FetchPolicy.NETWORK_ONLY)
        val hold = handle.retain()
        runCurrent()
        assertNull(assertIs<Phase.Ready<LiveQuotes.Data>>(handle.phase, "ready at once").data.liveQuotes, "no payload wrote the list yet")

        environment.commitPayload(LiveQuotes(), payload(listOf(QuoteTick("AAPL", 101.0, "09:31"))))
        environment.invalidate()
        runCurrent()
        environment.revalidate()
        runCurrent()
        val after = assertIs<Phase.Ready<LiveQuotes.Data>>(handle.phase).data
        assertEquals(listOf("AAPL"), after.liveQuotes?.map { it.id })
        assertTrue(http.requests.isEmpty(), "the server's transport was asked for nothing")
        assertTrue(socket.requests.isEmpty(), "the subscriptions' transport was asked for nothing")
        hold.release()
        environment.end()
    }

    @Test
    fun `one payload carrying several quotes merges each into the record its server query reads, and a field the payload does not give stays as the server wrote it`() = runTest {
        val environment = environment(ScriptedTransport(mapOf(QuoteQuery.name to serverQuote)))
        val (quote, hold) = readQuote(environment)
        assertEquals(100.0, quote.quote?.price)

        environment.commitPayload(
            LiveQuotes(),
            payload(listOf(QuoteTick("AAPL", 101.5, "09:31"), QuoteTick("MSFT", 410.0, "09:31"), QuoteTick("NVDA", 120.25, "09:31"))),
        )
        assertEquals(101.5, quote.quote?.price, "the server query's lens sees the list's write")
        assertEquals("09:31", quote.quote?.updatedAt)
        assertEquals("Apple", quote.quote?.name, "the payload left out the name, so the record keeps the server's")
        val msft = recordQuote(environment, "MSFT")
        assertEquals(410.0, msft?.price, "a quote the server never answered is a record of the server's type, which its query's lens reads")
        assertNull(msft?.name)
        hold.release()
        environment.end()
    }

    @Test
    fun `the pacer turns many ticks for few symbols into one commit per interval carrying only the newest tick of each, and commits nothing for an interval without ticks`() = runTest {
        val environment = environment(ScriptedTransport(mapOf(QuoteQuery.name to serverQuote)))
        val (quote, hold) = readQuote(environment)
        val live = environment.handle(LiveQuotes())
        val liveHold = live.retain()
        var commits = 0
        environment.log = { if (it is LogEvent.Committed && it.kind == LogEvent.CommitKind.SERVER) commits += 1 }
        val pacer = QuotePacer()
        val loop = backgroundScope.launch { commitPaced(pacer, environment, 100.milliseconds) }
        runCurrent()

        val symbols = listOf("AAPL", "MSFT", "NVDA")
        for (index in 0 until 30) pacer.offer(QuoteTick(symbols[index % 3], (200 + index).toDouble(), "09:31:$index"))
        runCurrent()
        assertEquals(0, commits, "a tick is not a commit")
        advanceTimeBy(100.milliseconds)
        runCurrent()
        assertEquals(1, commits)
        val committed = assertNotNull(assertIs<Phase.Ready<LiveQuotes.Data>>(live.phase).data.liveQuotes)
        assertEquals(symbols, committed.map { it.id }.sorted(), "one entry per symbol, not one per tick")
        assertEquals(227.0, committed.first { it.id == "AAPL" }.price, "the newest of AAPL's ten ticks")
        assertEquals(229.0, committed.first { it.id == "NVDA" }.price)
        assertEquals(227.0, quote.quote?.price)
        assertEquals("09:31:27", quote.quote?.updatedAt)
        assertEquals("Apple", quote.quote?.name)

        advanceTimeBy(100.milliseconds)
        runCurrent()
        assertEquals(1, commits, "an interval without ticks commits nothing")

        for (index in 0 until 5) pacer.offer(QuoteTick("MSFT", (400 + index).toDouble(), "09:32:$index"))
        advanceTimeBy(100.milliseconds)
        runCurrent()
        assertEquals(2, commits)
        val next = assertIs<Phase.Ready<LiveQuotes.Data>>(live.phase).data
        assertEquals(listOf("MSFT"), next.liveQuotes?.map { it.id }, "the list holds what the last interval drained")
        assertEquals(404.0, next.liveQuotes?.first()?.price)
        assertEquals(227.0, quote.quote?.price, "a quote the interval did not carry keeps its last price")
        loop.cancel()
        liveHold.release()
        hold.release()
        environment.end()
    }

    @Test
    fun `with the image attached, the transient list's cell is not written while the quotes' records are, so a second store over the image reads the new price through the server's query and finds nothing for the list`() = runTest {
        val first = environment(ScriptedTransport(mapOf(QuoteQuery.name to serverQuote)), store = Store(Persistence(image.path)))
        val (quote, hold) = readQuote(first)
        first.commitPayload(LiveQuotes(), payload(listOf(QuoteTick("AAPL", 105.0, "09:35"), QuoteTick("MSFT", 411.0, "09:35"))))
        assertEquals(105.0, quote.quote?.price)
        hold.release()
        first.end()

        assertEquals(0L, integer("SELECT count(*) FROM root WHERE field LIKE 'liveQuotes%'"), "the transient root field's cell is not written")
        assertEquals(0L, integer("SELECT count(*) FROM fetches WHERE operation LIKE 'LiveQuotes%'"))
        assertEquals(1L, integer("SELECT count(*) FROM records WHERE key = 'Quote:AAPL'"))
        assertEquals(1L, integer("SELECT count(*) FROM records WHERE key = 'Quote:MSFT'"), "a quote only the list linked is written too")
        assertEquals(1L, integer("SELECT count(*) FROM root WHERE field LIKE 'quote(%'"))

        val transport = ScriptedTransport()
        val second = environment(transport, store = Store(Persistence(image.path)))
        val stored = second.handle(QuoteQuery(symbol = "AAPL"), FetchPolicy.STORE_ONLY)
        val storedHold = stored.retain()
        val storedQuote = assertIs<Phase.Ready<QuoteQuery.Data>>(stored.phase, "the image answers the server's query").data.quote
        assertEquals(105.0, storedQuote?.price, "the server's query reads the price the list wrote")
        assertEquals("Apple", storedQuote?.name)
        val live = second.handle(LiveQuotes())
        val liveHold = live.retain()
        assertNull(assertIs<Phase.Ready<LiveQuotes.Data>>(live.phase).data.liveQuotes, "the list's cell did not reach the image")
        runCurrent()
        assertTrue(transport.requests.isEmpty())
        liveHold.release()
        storedHold.release()
        second.end()
    }

    @Test
    fun `committing many symbols through the list query parks one root and runs no collection, where the same ticks through the server's query of more than ten unheld symbols evict a root and run a collection per commit`() = runTest {
        val symbols = (0 until 20).map { "S$it" }
        val rounds = 5
        fun ticks(round: Int) = symbols.mapIndexed { index, symbol -> QuoteTick(symbol, (round * 100 + index).toDouble(), "09:${30 + round}") }

        val paced = environment(ScriptedTransport())
        val pacedRoots = paced.store.rootCount
        for (round in 0 until rounds) {
            paced.commitPayload(LiveQuotes(), payload(ticks(round)))
            runCurrent()
        }
        assertEquals(pacedRoots + 1, paced.store.rootCount, "one root, the list's, waits in the release buffer")
        assertEquals(0, paced.store.collections, "no root was pushed out, so no collection was scheduled")
        assertEquals(((rounds - 1) * 100 + 7).toDouble(), recordQuote(paced, "S7")?.price)
        paced.end()

        val perTick = environment(ScriptedTransport())
        for (round in 0 until rounds) {
            for (tick in ticks(round)) {
                val response = QuoteQuery.RawResponse(quote = QuoteQuery.RawResponse.Quote(id = tick.symbol, price = tick.price, updatedAt = tick.time))
                perTick.commitPayload(QuoteQuery(symbol = tick.symbol), response.payload)
                runCurrent()
            }
        }
        assertEquals(perTick.store.releaseBufferSize, perTick.store.rootCount, "a root per symbol, and the buffer keeps ten")
        val evictions = rounds * symbols.size - perTick.store.releaseBufferSize
        assertEquals(evictions, perTick.store.collections, "every commit past the buffer's ten pushed a root out, and each ran a collection")
        perTick.end()
    }

    @Test
    fun `a list that leaves out a symbol of the last one schedules a collection, and one that keeps every known symbol in order, an unchanged one by id alone, schedules none`() = runTest {
        val environment = environment(ScriptedTransport())
        val symbols = (0 until 5).map { "S$it" }
        environment.commitPayload(LiveQuotes(), payload(symbols.map { QuoteTick(it, 1.0, "09:30") }))
        runCurrent()
        val before = environment.store.collections

        environment.commitPayload(LiveQuotes(), payload(listOf(QuoteTick("S1", 2.0, "09:31"))))
        runCurrent()
        assertEquals(before + 1, environment.store.collections, "the list no longer links four of its quotes, which may have left them unreachable")

        environment.commitPayload(LiveQuotes(), payload(symbols.map { QuoteTick(it, 3.0, "09:32") }))
        runCurrent()
        val settled = environment.store.collections
        val listed = (symbols + "S5").map { symbol ->
            if (symbol == "S1" || symbol == "S5") LiveQuotes.RawResponse.LiveQuotes(id = symbol, price = 4.0, updatedAt = "09:33") else LiveQuotes.RawResponse.LiveQuotes(id = symbol)
        }
        environment.commitPayload(LiveQuotes(), LiveQuotes.RawResponse(liveQuotes = listed).payload)
        runCurrent()
        assertEquals(settled, environment.store.collections, "a list that only grew keeps every link it had")
        assertEquals(4.0, recordQuote(environment, "S1")?.price)
        assertEquals(4.0, recordQuote(environment, "S5")?.price)
        assertEquals(3.0, recordQuote(environment, "S3")?.price, "a quote given by its id alone keeps its price")
        assertEquals("09:32", recordQuote(environment, "S3")?.updatedAt)
        environment.end()
    }

    @Test
    fun `the listing pacer, across intervals in which different symbols tick, commits a list that only grows, so no collection is scheduled, each ticked symbol's price is written and an unticked one's fields stay`() = runTest {
        val environment = environment(ScriptedTransport())
        val live = environment.handle(LiveQuotes())
        val liveHold = live.retain()
        var commits = 0
        environment.log = { if (it is LogEvent.Committed && it.kind == LogEvent.CommitKind.SERVER) commits += 1 }
        val pacer = ListingPacer()
        val loop = backgroundScope.launch { commitListing(pacer, environment, 100.milliseconds) }
        runCurrent()

        fun interval(ticks: List<QuoteTick>) {
            for (tick in ticks) pacer.offer(tick)
            advanceTimeBy(100.milliseconds)
            runCurrent()
        }
        fun listed() = assertIs<Phase.Ready<LiveQuotes.Data>>(live.phase).data.liveQuotes?.map { it.id }

        interval(listOf("S0", "S1", "S2", "S3", "S4").map { QuoteTick(it, 1.0, "09:30") })
        assertEquals(1, commits)
        assertEquals(listOf("S0", "S1", "S2", "S3", "S4"), listed())
        interval(listOf(QuoteTick("S1", 2.0, "09:31"), QuoteTick("S3", 2.0, "09:31")))
        assertEquals(2, commits)
        assertEquals(listOf("S0", "S1", "S2", "S3", "S4"), listed(), "the symbols that did not tick are still listed")
        interval(listOf(QuoteTick("S5", 3.0, "09:32"), QuoteTick("S0", 3.0, "09:32")))
        assertEquals(3, commits)
        assertEquals(listOf("S0", "S1", "S2", "S3", "S4", "S5"), listed(), "a new symbol is appended")
        interval(emptyList())
        assertEquals(3, commits, "an interval without ticks commits nothing")

        assertEquals(0, environment.store.collections, "no commit dropped a link")
        assertEquals(3.0, recordQuote(environment, "S0")?.price)
        assertEquals(2.0, recordQuote(environment, "S1")?.price)
        assertEquals("09:31", recordQuote(environment, "S3")?.updatedAt)
        assertEquals(3.0, recordQuote(environment, "S5")?.price)
        assertEquals(1.0, recordQuote(environment, "S2")?.price, "a symbol listed by its id alone keeps its price")
        assertEquals("09:30", recordQuote(environment, "S4")?.updatedAt)
        loop.cancel()
        liveHold.release()
        environment.end()
    }

    @Test
    fun `the service's wiring runs, so ticks a feed yields off the main dispatcher reach the store through the pacing loop, and cancelling both jobs and releasing the list's hold ends it`() = runTest {
        val environment = environment(ScriptedTransport())
        val commits = AtomicInteger()
        environment.log = { if (it is LogEvent.Committed && it.kind == LogEvent.CommitKind.SERVER) commits.incrementAndGet() }
        val feed = LiveFeed()
        val scope = backgroundScope

        val pacer = QuotePacer()
        val hold = environment.handle(LiveQuotes()).retain()
        val feeding = scope.launch(Dispatchers.Default) { feed.ticks().collect { pacer.offer(it) } }
        val pacing = scope.launch(Dispatchers.Default) { commitPaced(pacer, environment, 33.milliseconds) }

        for (index in 0 until 10) feed.send(QuoteTick(if (index % 2 == 0) "AAPL" else "MSFT", (100 + index).toDouble(), "09:31:$index"))
        // The loop delays on the default dispatcher's real clock and hops to
        // the environment's dispatcher, the test's, to commit; the test waits
        // off it so the commit can run.
        withContext(Dispatchers.Default) {
            val deadline = System.nanoTime() + 10_000_000_000
            while (System.nanoTime() < deadline && commits.get() == 0) Thread.sleep(5)
            // Three intervals more, for a tick the first drain missed.
            Thread.sleep(100)
        }
        runCurrent()
        assertTrue(commits.get() in 1..10, "ticks were paced, not committed one by one: ${commits.get()}")
        assertEquals(108.0, recordQuote(environment, "AAPL")?.price)
        assertEquals(109.0, recordQuote(environment, "MSFT")?.price)

        feeding.cancel()
        pacing.cancel()
        feeding.join()
        pacing.join()
        hold.release()
        runCurrent()
        assertTrue(feeding.isCancelled && pacing.isCancelled)
        val ended = commits.get()
        pacer.offer(QuoteTick("AAPL", 200.0, "09:40"))
        withContext(Dispatchers.Default) { Thread.sleep(100) }
        runCurrent()
        assertEquals(ended, commits.get(), "no loop is left to commit")
        assertEquals(108.0, recordQuote(environment, "AAPL")?.price)
        environment.end()
    }

    @Test
    fun `commitPayload commits while the environment is inactive, and the service's refetch of its held server query fetches the baseline again`() = runTest {
        val transport = ScriptedTransport(mapOf(QuoteQuery.name to serverQuote))
        val environment = environment(transport)
        val handle = environment.handle(QuoteQuery(symbol = "AAPL"))
        val hold = handle.retain()
        runCurrent()
        handle.settle()
        val quote = assertIs<Phase.Ready<QuoteQuery.Data>>(handle.phase).data

        environment.isActive = false
        environment.commitPayload(LiveQuotes(), payload(listOf(QuoteTick("AAPL", 120.0, "09:50"))))
        assertEquals(120.0, quote.quote?.price, "the commit landed while inactive")
        assertEquals("09:50", quote.quote?.updatedAt)

        environment.isActive = true
        handle.refetch()
        runCurrent()
        assertEquals(listOf(QuoteQuery.name, QuoteQuery.name), transport.requests.map { it.operationName }, "the refetch sent the server's query again")
        assertEquals(100.0, quote.quote?.price, "the baseline is the server's again")
        hold.release()
        environment.end()
    }
}

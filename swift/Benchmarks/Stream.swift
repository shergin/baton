// The stream section: values that arrive over a protocol that is not
// GraphQL, a tick at a time, written into records the store already holds.
// A tick names a character of the fixture by id and changes two of its
// scalar fields, `status` standing for a price and `created` for its time,
// through either door an app has: `Environment.commitPayload`, called by a
// service once per tick, or a subscription whose events a transport of the
// app's own yields, as `docs/recipes` and `BatonFeedTests` show. Every row
// runs against a store holding the fixture, fetched through a handle the
// row retains, with 20 observation-tracked readers of the page's own
// characters and one of the written record. The paced rows measure the
// shape the docs recommend for a service: the newest tick per key kept off
// the main actor and, once per interval, one payload carrying every pending
// key through `BenchLive`, a client-only query over the client list
// `live.graphql` declares, transient in `baton.json`.
@_spi(Generated) import Baton
import BatonSpec
import Foundation
import Observation
import Synchronization

@MainActor
struct StreamDocuments {
    @Query("""
        query BenchTick($id: ID!) @raw_response_type {
          character(id: $id) { id status created }
        }
        """)
    var tick: BenchTick

    @Query("""
        query BenchTransientTick($id: ID!) @raw_response_type {
          characterBy(by: {id: $id}) { id status created }
        }
        """)
    var transientTick: BenchTransientTick

    @Query("""
        query BenchTicks($ids: [ID!]!) @raw_response_type {
          charactersByIds(ids: $ids) { id status created }
        }
        """)
    var ticks: BenchTicks

    @Query("""
        query BenchLive @raw_response_type {
          liveCharacters { id status created }
        }
        """)
    var live: BenchLive

    @Query("""
        query BenchLiveImaged @raw_response_type {
          liveCharactersImaged { id status created }
        }
        """)
    var liveImaged: BenchLiveImaged

    @Subscription("""
        subscription BenchTickEvents($characterId: ID!) @raw_response_type {
          noteAdded(characterId: $characterId) { character { id status created } }
        }
        """)
    var events: BenchTickEvents
}

/// One tick of the feed: the record it names, its new values, and its
/// number in the run, which makes every value new.
struct Tick: Sendable {
    let index: Int
    let id: String
    let status: String
    let created: String

    init(index: Int, id: String) {
        self.index = index
        self.id = id
        status = "\(100 + index % 900).\(index % 100)"
        created = "2026-11-23T09:30:00.\(index)Z"
    }

    /// The tick as the query's payload, written by the generated builder.
    var payload: Payload {
        BenchTick.RawResponse(character: .init(id: id, status: status, created: created)).payload
    }

    /// The same tick through the root field `baton.json` marks transient.
    var transientPayload: Payload {
        BenchTransientTick.RawResponse(characterBy: .init(id: id, status: status, created: created)).payload
    }

    /// The tick as the subscription's event.
    var event: Data {
        BenchTickEvents.RawResponse(noteAdded: .init(character: .init(id: id, status: status, created: created))).payload.bytes
    }

    /// The same bytes as the builder's, written as a string literal with
    /// interpolation: the builder writes an object's keys sorted. Right only
    /// for values that need no escaping.
    var literal: Payload {
        Payload(json: #"{"data":{"character":{"created":"\#(created)","id":"\#(id)","status":"\#(status)"}}}"#)
    }
}

/// The ids of the written records: characters the fixture holds through its
/// episodes' casts, with an id, a name and an image and no status, so a
/// key's first tick adds its two slots and every later one changes them.
/// None of them is among the page's 20, which the other readers read.
func tickIDs(_ count: Int, from first: Int = 21) -> [String] {
    (first..<(first + count)).map(String.init)
}

/// The store's log, as the stream rows read it: when each server batch
/// landed and how many slots it changed, and what the image's writer
/// wrote. A waiter is resumed by the commit that reaches its count.
final class CommitLog: Sendable {
    private struct State: Sendable {
        var times: [UInt64] = []
        var changed = 0
        var writes = 0
        var batches = 0
        var target = 0
        var generation = 0
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    func record(_ event: LogEvent) {
        switch event {
        case .committed(kind: .server, let changed):
            let now = DispatchTime.now().uptimeNanoseconds
            let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                state.times.append(now)
                state.changed += changed
                guard state.waiter != nil, state.times.count >= state.target else { return nil }
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: true)
        case .imageWritten(let batches):
            state.withLock {
                $0.writes += 1
                $0.batches += batches
            }
        default:
            break
        }
    }

    var commits: Int { state.withLock { $0.times.count } }
    var times: [UInt64] { state.withLock { $0.times } }
    var changed: Int { state.withLock { $0.changed } }
    var writes: Int { state.withLock { $0.writes } }
    var batches: Int { state.withLock { $0.batches } }

    func reset() {
        state.withLock { state in
            state.times.removeAll(keepingCapacity: true)
            state.changed = 0
            state.writes = 0
            state.batches = 0
        }
    }

    /// Waits until `count` server batches have landed since the last reset,
    /// or `timeout` passes; true when they landed.
    func wait(for count: Int, timeout: Duration = .seconds(60)) async -> Bool {
        await withCheckedContinuation { continuation in
            let generation = state.withLock { state -> Int? in
                if state.times.count >= count { return nil }
                state.generation += 1
                state.target = count
                state.waiter = continuation
                return state.generation
            }
            guard let generation else {
                continuation.resume(returning: true)
                return
            }
            Task.detached { [self] in
                try? await Task.sleep(for: timeout)
                let waiter = self.state.withLock { state -> CheckedContinuation<Bool, Never>? in
                    guard state.generation == generation, state.waiter != nil else { return nil }
                    defer { state.waiter = nil }
                    return state.waiter
                }
                waiter?.resume(returning: false)
            }
        }
    }
}

/// The feed's client, as test data: a stream of ticks per record id, which
/// the transport below opens once per subscription.
final class TickFeed: Sendable {
    private let streams = Mutex<[String: AsyncStream<Tick>.Continuation]>([:])
    private let opens = Atomic<Int>(0)

    func ticks(id: String) -> AsyncStream<Tick> {
        let (stream, continuation) = AsyncStream<Tick>.makeStream()
        streams.withLock { $0[id] = continuation }
        opens.add(1, ordering: .relaxed)
        return stream
    }

    /// How many streams the transport has opened.
    var opened: Int { opens.load(ordering: .relaxed) }

    func send(_ tick: Tick) {
        _ = streams.withLock { $0[tick.id] }?.yield(tick)
    }

    func finish() {
        for continuation in streams.withLock({ Array($0.values) }) { continuation.finish() }
    }
}

/// The transport an app writes for the feed, the shape of the recipe's: the
/// subscription's events are the feed's ticks, each written with the
/// operation's raw response, on the transport's own task.
struct TickTransport: Transport {
    let feed: TickFeed

    func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        guard request.operationName == BenchTickEvents.name, case .string(let id)? = request.variables["characterId"] else {
            return AsyncThrowingStream { $0.finish() }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await tick in feed.ticks(id: id) {
                    continuation.yield(tick.event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The server, which answers the fixture's query with the fixture and
/// nothing else.
struct FixtureTransport: Transport {
    let data: Data

    func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        let data = request.operationName == BenchFixture.name ? data : nil
        return AsyncThrowingStream { continuation in
            if let data { continuation.yield(data) }
            continuation.finish()
        }
    }
}

/// An environment holding the fixture, fetched through a handle it keeps
/// retained, and the readers of the page's 20 characters' status.
@MainActor
final class StreamStage {
    let environment: Environment
    let log = CommitLog()
    let feed = TickFeed()
    private let fixture: Retention
    /// Reads of the page's own 20 characters, none of them written.
    let others: [() -> Void]
    private var subscriptions: [Retention] = []

    init(data: Data, persistence: Persistence? = nil) async throws {
        let store = Store(persistence: persistence)
        environment = Environment(transport: FixtureTransport(data: data), subscriptions: TickTransport(feed: feed), store: store)
        environment.log = nil
        let handle = environment.handle(for: BenchFixture(page: 1))
        fixture = handle.retain()
        await handle.settle()
        guard case .ready(let page) = handle.phase, let rows = page.characters?.results, rows.count == 20 else { throw MissingBenchData() }
        others = rows.map { row in { _ = row.status } }
        let log = log
        environment.log = { log.record($0) }
    }

    var store: Store { environment.store }

    /// A read of the written record's two fields, through the tick query's
    /// lens over the record.
    func written(_ id: String) throws -> () -> Void {
        let record = try requireValue(store.existing("Character:\(id)"))
        let character = BenchTick.Data.Character(anchor: Anchor(record: record, variables: BenchTick(id: id).variables, store: store))
        return {
            _ = character.status
            _ = character.created
        }
    }

    /// Opens the subscription of every id and waits until the feed has a
    /// stream for each.
    func subscribe(_ ids: [String]) async throws {
        let before = feed.opened
        for id in ids {
            subscriptions.append(environment.subscriptionHandle(for: BenchTickEvents(characterId: id)).retain())
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while feed.opened < before + ids.count {
            guard ContinuousClock.now < deadline else { throw MissingBenchData() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Retains the tick query's root of every id through a handle, as a
    /// view of each record would, so no tick's root waits in the release
    /// buffer.
    func retainTickRoots(_ ids: [String]) {
        for id in ids {
            subscriptions.append(environment.handle(for: BenchTick(id: id), fetchPolicy: .storeOnly).retain())
        }
    }

    /// Gives every id its first tick, through the query's door, so the rows
    /// that follow measure later ticks.
    func prime(_ ids: [String], from index: Int) async throws {
        for (offset, id) in ids.enumerated() {
            try await environment.commitPayload(BenchTick(id: id), Tick(index: index + offset, id: id).payload)
        }
    }

    func end() {
        feed.finish()
        subscriptions.removeAll()
    }
}

/// A reader of the written record kept armed, as a view's body is: each
/// change is counted and the reader runs again on the main actor's next
/// turn.
@MainActor
final class LiveReader {
    private let read: () -> Void
    private(set) var fired = 0

    init(_ read: @escaping () -> Void) {
        self.read = read
        arm()
    }

    private func arm() {
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.fired += 1
                self.arm()
            }
        }
    }
}

enum Door: String {
    case commitPayload = "commitPayload"
    case subscription = "the subscription"
}

@MainActor
func streamBench(data: Data) async throws {
    var index = 1_000
    func next() -> Int {
        index += 1
        return index
    }
    try await perTickBench(data: data, next: next)
    try await builderBench()
    try await coalescingBench(data: data, next: next)
    try await burstBench(data: data, next: next)
    try await pacedBench(data: data, next: next)
    if options.countsOnly { return }
    try await sustainedBench(data: data, next: next)
    try await pacedSustainedBench(data: data, next: next)
}

/// One tick through each door, and its halves.
@MainActor
func perTickBench(data: Data, next: () -> Int) async throws {
    let stage = try await StreamStage(data: data)
    let store = stage.store
    if !options.countsOnly { print("  the store holds \(store.recordsByKey.count) records") }
    let written = try stage.written("21")
    let readers = stage.others + [written]
    let observer = Observer()
    try await stage.prime(["21"], from: next())

    // A later tick of one key, the whole call, from the main actor.
    // The payload is written in the setup: the builder's cost is a row of
    // its own, and an adapter pays it off the main actor.
    stage.log.reset()
    var payload = Tick(index: next(), id: "21").payload
    await measureAsync("a later tick through commitPayload, the whole call", iterations: 200, observer: observer, setup: {
        payload = Tick(index: next(), id: "21").payload
        observer.observe(readers) { $0() }
    }) {
        try? await stage.environment.commitPayload(BenchTick(id: "21"), payload)
    }
    let laterCommits = max(stage.log.commits, 1)
    count("notifications-per-later-tick", observer.fired / rounds(200), "    notifications per tick: \(observer.fired / rounds(200)) (the written record's reader); slots changed per tick: \(stage.log.changed / laterCommits)")
    if options.countsOnly { count("slots-changed-per-later-tick", stage.log.changed / laterCommits, "") }

    // A first tick for a key, a new key each sample, among the characters
    // the episodes' casts hold. Past ten keys each tick's root, which nobody
    // retains, pushes another out of the release buffer.
    var firstID = 120
    stage.log.reset()
    let firsts = Observer()
    await measureAsync("a first tick for a key through commitPayload, the whole call", iterations: 50, observer: firsts, setup: {
        firstID += 1
        payload = Tick(index: next(), id: String(firstID)).payload
        firsts.observe(stage.others) { $0() }
    }) {
        try? await stage.environment.commitPayload(BenchTick(id: String(firstID)), payload)
    }
    let firstCommits = max(stage.log.commits, 1)
    count("slots-changed-per-first-tick", stage.log.changed / firstCommits, "    slots changed per first tick: \(stage.log.changed / firstCommits); notifications to the 20 other readers: \(firsts.fired)")

    // The halves, measured apart: the ingest, which the door runs off the
    // main actor, and the commit, which it runs on it.
    let plan = BenchTick.plan.resolve(BenchTick(id: "21").variables, in: store.keys)
    let bytes = Tick(index: next(), id: "21").payload.bytes
    measure("a later tick's ingest alone, off the main actor in the door", iterations: 200, gate: "tick-ingest") {
        _ = try! Ingest.normalize(bytes, plan: plan, rootKey: Store.rootKey)
    }
    var changes = try Ingest.normalize(bytes, plan: plan, rootKey: Store.rootKey)
    var changed = 0
    let halves = Observer()
    measure("a later tick's commit alone, on the main actor", iterations: 200, observer: halves, gate: "tick-commit", setup: {
        changes = try! Ingest.normalize(Tick(index: next(), id: "21").payload.bytes, plan: plan, rootKey: Store.rootKey)
        halves.observe(readers) { $0() }
    }) {
        changed = store.commit(changes)
    }
    count("slots-changed-by-a-later-tick-commit", changed, "    slots changed by the commit: \(changed); notifications per commit: \(halves.fired / rounds(200))")
    measure("a first tick's commit alone, a new key each sample", iterations: 50, setup: {
        firstID += 1
        let id = String(firstID)
        changes = try! Ingest.normalize(Tick(index: next(), id: id).payload.bytes, plan: BenchTick.plan.resolve(BenchTick(id: id).variables, in: store.keys), rootKey: Store.rootKey)
    }) {
        changed = store.commit(changes)
    }
    count("slots-changed-by-a-first-tick-commit", changed, "    slots changed by a first tick's commit: \(changed)")

    // The same tick as a subscription's event: from the feed's yield, through
    // the app's transport, which writes the event with the builder, to the
    // commit.
    try await stage.subscribe(["21"])
    stage.feed.send(Tick(index: next(), id: "21"))
    _ = await stage.log.wait(for: stage.log.commits + 1)
    let events = Observer()
    await measureAsync("a subscription event, from the feed's yield to the commit", iterations: 200, observer: events, setup: {
        events.observe(readers) { $0() }
    }) {
        let target = stage.log.commits + 1
        stage.feed.send(Tick(index: next(), id: "21"))
        _ = await stage.log.wait(for: target)
    }
    count("notifications-per-subscription-event", events.fired / rounds(200), "    notifications per event: \(events.fired / rounds(200))")
    stage.end()

    // A later tick with the image attached: the commit hands the writer a
    // snapshot of the record and the root's cell.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("baton-bench-stream-\(UUID().uuidString).sqlite")
    defer { removeImage(url) }
    let persistence = Persistence(url: url)
    let imaged = try await StreamStage(data: data, persistence: persistence)
    await persistence.flush()
    try await imaged.prime(["21"], from: next())
    await persistence.flush()
    await measureAsync("a later tick through commitPayload, image attached, the whole call", iterations: 200, setup: {
        payload = Tick(index: next(), id: "21").payload
    }) {
        try? await imaged.environment.commitPayload(BenchTick(id: "21"), payload)
    }
    await persistence.flush()
    await persistence.close()
}

func removeImage(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
}

func imageSize(_ url: URL) -> Int {
    ["", "-wal"].reduce(0) { total, suffix in
        total + (((try? FileManager.default.attributesOfItem(atPath: url.path + suffix))?[.size] as? Int) ?? 0)
    }
}

/// The per-tick cost an adapter pays before the door: the generated raw
/// response's payload beside the same bytes as an interpolated literal.
@MainActor
func builderBench() async throws {
    let ticks = (0..<1_000).map { Tick(index: 5_000 + $0, id: String(21 + $0 % 100)) }
    let same = ticks.allSatisfy { $0.payload == $0.literal }
    if !options.countsOnly { print("  the builder's bytes equal the literal's: \(same)") }
    measure("a tick's payload by the generated RawResponse builder, per payload", iterations: 30, ops: ticks.count, gate: "tick-builder-1000") {
        var sink = 0
        for tick in ticks { sink &+= tick.payload.bytes.count }
        if sink == 42 { print("") }
    }
    measure("the same bytes as a string literal with interpolation, per payload", iterations: 30, ops: ticks.count, gate: "tick-literal-1000") {
        var sink = 0
        for tick in ticks { sink &+= tick.literal.bytes.count }
        if sink == 42 { print("") }
    }
}

/// The newest value of 100 keys in one payload of a plural operation,
/// against 100 payloads of one key each.
@MainActor
func coalescingBench(data: Data, next: () -> Int) async throws {
    let stage = try await StreamStage(data: data)
    let ids = tickIDs(100)
    try await stage.prime(ids, from: next())
    let written = try stage.written(ids[0])
    let readers = stage.others + [written]
    let operation = BenchTicks(ids: ids)
    let one = Observer()
    var payload = Payload(json: "{}")
    func coalesced() -> Payload {
        let base = next() * 100
        return BenchTicks.RawResponse(charactersByIds: ids.enumerated().map { offset, id in
            let tick = Tick(index: base + offset, id: id)
            return .init(id: tick.id, status: tick.status, created: tick.created)
        }).payload
    }
    stage.log.reset()
    await measureAsync("one payload carrying 100 keys through commitPayload", iterations: 50, observer: one, setup: {
        payload = coalesced()
        one.observe(readers) { $0() }
    }) {
        try? await stage.environment.commitPayload(operation, payload)
    }
    let oneCommits = max(stage.log.commits, 1)
    count("slots-changed-per-coalesced-payload", stage.log.changed / oneCommits, "    slots changed per payload: \(stage.log.changed / oneCommits); notifications: \(one.fired / rounds(50))")
    var payloads: [Payload] = []
    func singles() -> [Payload] {
        let base = next() * 100
        return ids.enumerated().map { offset, id in Tick(index: base + offset, id: id).payload }
    }
    // A hundred keys are more than the release buffer's ten: each tick's
    // root, which nobody retains, pushes another out, and the collection
    // that follows runs on the main actor.
    let many = Observer()
    stage.log.reset()
    await measureAsync("100 payloads of one key each through commitPayload, in sequence", iterations: 50, observer: many, setup: {
        payloads = singles()
        many.observe(readers) { $0() }
    }) {
        for (id, payload) in zip(ids, payloads) {
            try? await stage.environment.commitPayload(BenchTick(id: id), payload)
        }
    }
    count("commits-per-100-single-payloads", stage.log.commits / rounds(50), "    commits per sample: \(stage.log.commits / rounds(50)); slots changed per sample: \(stage.log.changed / rounds(50)); notifications: \(many.fired / rounds(50))")
    // The same, with every key's root retained by a handle of the tick's
    // query, as a view of each record would hold it: no root leaves.
    let retained = ids.map { stage.environment.handle(for: BenchTick(id: $0), fetchPolicy: .storeOnly).retain() }
    let held = Observer()
    stage.log.reset()
    await measureAsync("100 payloads of one key each, every key's root retained, in sequence", iterations: 50, observer: held, setup: {
        payloads = singles()
        held.observe(readers) { $0() }
    }) {
        for (id, payload) in zip(ids, payloads) {
            try? await stage.environment.commitPayload(BenchTick(id: id), payload)
        }
    }
    count("slots-changed-per-100-retained-single-payloads", stage.log.changed / rounds(50), "    slots changed per sample: \(stage.log.changed / rounds(50)); notifications: \(held.fired / rounds(50))")
    withExtendedLifetime(retained) {}
}

/// What one burst of ticks costs through a door: the wall time from the
/// handover to the last commit, the main thread's CPU time over it, and,
/// with the probe, the longest wait of a block on the main queue.
@MainActor
func burst(_ data: Data, door: Door, keys: Int, ticks count: Int, retained: Bool = false, probe: MainQueueProbe?, next: () -> Int) async throws -> (wall: UInt64, main: UInt64, longest: UInt64, commits: Int) {
    let stage = try await StreamStage(data: data)
    defer { stage.end() }
    let ids = tickIDs(keys)
    if retained { stage.retainTickRoots(ids) }
    try await stage.prime(ids, from: next())
    let reader = LiveReader(try stage.written(ids[0]))
    let others = Observer()
    others.observe(stage.others) { $0() }
    if door == .subscription { try await stage.subscribe(ids) }
    let base = next() * count
    let ticks = (0..<count).map { Tick(index: base + $0, id: ids[$0 % keys]) }
    let environment = stage.environment
    let feed = stage.feed
    stage.log.reset()
    probe?.start()
    let start = DispatchTime.now().uptimeNanoseconds
    let cpu = threadCPUTime()
    switch door {
    case .commitPayload:
        // The service's loop, off the main actor: each tick written with the
        // builder and handed to the door, one after another.
        Task.detached {
            for tick in ticks { try? await environment.commitPayload(BenchTick(id: tick.id), tick.payload) }
        }
    case .subscription:
        Task.detached {
            for tick in ticks { feed.send(tick) }
        }
    }
    let landed = await stage.log.wait(for: count)
    let main = threadCPUTime() - cpu
    let wall = (stage.log.times.last ?? start) - start
    let longest = probe?.stop() ?? 0
    if !landed { print("    \(door.rawValue), \(keys) keys: only \(stage.log.commits) of \(count) commits landed") }
    if others.pending != 0 { print("    \(others.pending) notifications reached the other readers") }
    withExtendedLifetime(reader) {}
    return (wall, main, longest, stage.log.commits)
}

@MainActor
func burstBench(data: Data, next: () -> Int) async throws {
    let ticks = 1_000
    let cases: [(door: Door, keys: Int, retained: Bool)] = [
        (.commitPayload, 1, false), (.commitPayload, 10, false), (.commitPayload, 100, false), (.commitPayload, 100, true),
        (.subscription, 1, false), (.subscription, 10, false), (.subscription, 100, false),
    ]
    for (door, keys, retained) in cases {
        var walls: [Double] = []
        var mains: [Double] = []
        var commits = 0
        for _ in 0..<rounds(10) {
            let result = try await burst(data, door: door, keys: keys, ticks: ticks, retained: retained, probe: nil, next: next)
            walls.append(Double(result.wall))
            mains.append(Double(result.main))
            commits = result.commits
        }
        let label = "a burst of 1,000 ticks over \(keys) key\(keys == 1 ? "" : "s") through \(door.rawValue)\(retained ? ", roots retained" : "")"
        let name = "\(door == .commitPayload ? "commit-payload" : "subscription")-\(keys)\(retained ? "-retained" : "")"
        report(label + ", handover to the last commit", walls, ops: 1)
        report(label + ", on the main thread", mains, ops: 1)
        count("commits-burst-\(name)", commits, "    commits: \(commits)")
        if options.countsOnly { continue }
        var longest: [UInt64] = []
        for _ in 0..<rounds(5) {
            longest.append(try await burst(data, door: door, keys: keys, ticks: ticks, retained: retained, probe: MainQueueProbe(), next: next).longest)
        }
        longest.sort()
        figure("burst-longest-wait-\(name)", Double(longest[longest.count / 2]), unit: "ns",
               "    longest wait of a main-queue probe: median \(format(Double(longest[longest.count / 2]))), worst \(format(Double(longest.last!))) over \(longest.count) runs")
    }
}

/// What a sustained run measured.
struct Sustained {
    var wall: UInt64 = 0
    var main: UInt64 = 0
    var ticks = 0
    var commits = 0
    var lagAtEnd: UInt64 = 0
    var behindAtLastSend = 0
    var flushAfterLastTick: UInt64 = 0
    var diskBytes: UInt64 = 0
    var fileGrowth = 0
    var writes = 0
    var batches = 0
    var fired = 0
    var landed = true
}

/// The send times of a producer's first and last tick.
final class Sends: Sendable {
    let first = Atomic<UInt64>(0)
    let last = Atomic<UInt64>(0)
}

/// Ticks at `rate` a second for `seconds`, over `keys` keys, through a door,
/// with an image attached: a producer thread sends each tick at its time,
/// the door commits, and the run ends when the last tick has committed.
@MainActor
func sustained(_ data: Data, door: Door, rate: Int, keys: Int, seconds: Double, transient: Bool = false, retained: Bool = false, empty: Bool = false, next: () -> Int) async throws -> Sustained {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("baton-bench-stream-\(UUID().uuidString).sqlite")
    defer { removeImage(url) }
    let persistence = Persistence(url: url)
    let stage = try await StreamStage(data: data, persistence: persistence)
    let ids = tickIDs(keys)
    if retained { stage.retainTickRoots(ids) }
    try await stage.prime(ids, from: next())
    if door == .subscription { try await stage.subscribe(ids) }
    await persistence.flush()
    let reader = LiveReader(try stage.written(ids[0]))
    let others = Observer()
    others.observe(stage.others) { $0() }

    let total = max(1, Int(Double(rate) * seconds))
    let base = next() * total
    let environment = stage.environment
    let feed = stage.feed
    let (stream, continuation) = AsyncStream<Tick>.makeStream()
    var service: Task<Void, Never>?
    if door == .commitPayload {
        // The service's loop, off the main actor, as a socket's reader is.
        service = Task.detached {
            for await tick in stream {
                if empty {
                    // The floor: the hop to the main actor alone, which
                    // notes a commit for the run's count and writes nothing.
                    await MainActor.run { environment.log?(.committed(kind: .server, changed: 0)) }
                } else if transient {
                    try? await environment.commitPayload(BenchTransientTick(id: tick.id), tick.transientPayload)
                } else {
                    try? await environment.commitPayload(BenchTick(id: tick.id), tick.payload)
                }
            }
        }
    }
    let throughService = door == .commitPayload
    let send: @Sendable (Tick) -> Void = { tick in
        if throughService {
            continuation.yield(tick)
        } else {
            feed.send(tick)
        }
    }
    stage.log.reset()
    let sizeBefore = imageSize(url)
    let diskBefore = diskBytesWritten()
    let cpu = threadCPUTime()
    let sends = Sends()
    let interval = 1e9 / Double(rate)
    let producer = Thread {
        let start = DispatchTime.now().uptimeNanoseconds + 1_000_000
        for offset in 0..<total {
            let due = start + UInt64(Double(offset) * interval)
            let now = DispatchTime.now().uptimeNanoseconds
            if due > now {
                var wait = timespec(tv_sec: Int((due - now) / 1_000_000_000), tv_nsec: Int((due - now) % 1_000_000_000))
                nanosleep(&wait, nil)
            }
            let sent = DispatchTime.now().uptimeNanoseconds
            if offset == 0 { sends.first.store(sent, ordering: .relaxed) }
            send(Tick(index: base + offset, id: ids[offset % keys]))
            if offset == total - 1 { sends.last.store(sent, ordering: .relaxed) }
        }
    }
    producer.qualityOfService = .userInitiated
    producer.start()
    var result = Sustained()
    result.ticks = total
    result.landed = await stage.log.wait(for: total, timeout: .seconds(seconds * 10 + 60))
    result.main = threadCPUTime() - cpu
    let times = stage.log.times
    let first = sends.first.load(ordering: .relaxed)
    let last = sends.last.load(ordering: .relaxed)
    let lastCommit = times.last ?? last
    // The run's wall time: the ticks' schedule, or longer when the last
    // commit landed after it.
    result.wall = max(lastCommit - first, UInt64(Double(total) * interval))
    result.commits = times.count
    result.lagAtEnd = lastCommit > last ? lastCommit - last : 0
    result.behindAtLastSend = max(0, total - 1 - times.filter { $0 <= last }.count)
    await persistence.flush()
    let flushed = DispatchTime.now().uptimeNanoseconds
    result.flushAfterLastTick = flushed - last
    result.diskBytes = diskBytesWritten() - diskBefore
    result.fileGrowth = imageSize(url) - sizeBefore
    result.writes = stage.log.writes
    result.batches = stage.log.batches
    result.fired = reader.fired
    if others.pending != 0 { print("    \(others.pending) notifications reached the other readers") }
    continuation.finish()
    await service?.value
    stage.end()
    await persistence.close()
    return result
}

@MainActor
func sustainedBench(data: Data, next: () -> Int) async throws {
    let seconds = options.quick ? 0.5 : 10
    print("  sustained, \(Int(seconds)) s a run, image attached; per run: main-thread busy per second of wall, lag of the last tick, ticks behind at the last send, image bytes, flush after the last tick")
    func record(_ name: String, _ run: Sustained) {
        let busy = Double(run.main) / (Double(run.wall) / 1e9)
        let line = String(format: "  %-58@ busy %7.2f ms/s  lag %9@  behind %5d  written %9d B  file +%8d B  flush %9@  writes %4d (%5d batches)  commits %5d/%5d  fired %5d%@",
                          name as NSString, busy / 1e6, format(Double(run.lagAtEnd)) as NSString, run.behindAtLastSend, run.diskBytes, run.fileGrowth,
                          format(Double(run.flushAfterLastTick)) as NSString, run.writes, run.batches, run.commits, run.ticks, run.fired, run.landed ? "" : "  (did not land)")
        figure("\(name) busy", busy, unit: "ns/s", line)
        figure("\(name) lag", Double(run.lagAtEnd), unit: "ns")
        figure("\(name) behind", Double(run.behindAtLastSend), unit: "ticks")
        figure("\(name) disk", Double(run.diskBytes), unit: "B")
        figure("\(name) file", Double(run.fileGrowth), unit: "B")
        figure("\(name) flush", Double(run.flushAfterLastTick), unit: "ns")
    }
    for rate in [1, 10, 100, 1_000] {
        for keys in [1, 10, 100] {
            record("commitPayload, \(rate)/s over \(keys) keys", try await sustained(data, door: .commitPayload, rate: rate, keys: keys, seconds: seconds, next: next))
        }
    }
    for rate in [100, 1_000] {
        for keys in [1, 10, 100] {
            record("subscription, \(rate)/s over \(keys) keys", try await sustained(data, door: .subscription, rate: rate, keys: keys, seconds: seconds, next: next))
        }
    }
    for rate in [100, 1_000] {
        record("commitPayload, roots retained, \(rate)/s over 100 keys", try await sustained(data, door: .commitPayload, rate: rate, keys: 100, seconds: seconds, retained: true, next: next))
    }
    for rate in [100, 1_000] {
        record("floor: an empty hop to the main actor, \(rate)/s", try await sustained(data, door: .commitPayload, rate: rate, keys: 1, seconds: seconds, empty: true, next: next))
    }
    for keys in [1, 10, 100] {
        record("commitPayload, transient root, 100/s over \(keys) keys", try await sustained(data, door: .commitPayload, rate: 100, keys: keys, seconds: seconds, transient: true, next: next))
    }
}


/// The ticks as one payload of the paced shape: through `BenchLive`, whose
/// root field is transient, or its twin `BenchLiveImaged`, whose is not.
func livePayload(_ ticks: [Tick], imaged: Bool = false) -> Payload {
    if imaged {
        return BenchLiveImaged.RawResponse(liveCharactersImaged: ticks.map { .init(id: $0.id, status: $0.status, created: $0.created) }).payload
    }
    return BenchLive.RawResponse(liveCharacters: ticks.map { .init(id: $0.id, status: $0.status, created: $0.created) }).payload
}

/// Commits one payload of the paced shape.
func commitLive(_ environment: Environment, _ ticks: [Tick], imaged: Bool = false) async throws {
    if imaged {
        try await environment.commitPayload(BenchLiveImaged(), livePayload(ticks, imaged: true))
    } else {
        try await environment.commitPayload(BenchLive(), livePayload(ticks))
    }
}

/// The pacer of `BatonFeedTests`, as a producer thread drives it: the
/// newest tick of each key since the last drain, under a lock, with the
/// time that tick arrived.
final class TickPacer: Sendable {
    struct Pending: Sendable {
        let tick: Tick
        let arrival: UInt64
    }

    private let pending = Mutex<[String: Pending]>([:])

    func offer(_ tick: Tick, at arrival: UInt64) {
        pending.withLock { $0[tick.id] = Pending(tick: tick, arrival: arrival) }
    }

    func drain() -> [Pending] {
        pending.withLock { pending in
            defer { pending.removeAll(keepingCapacity: true) }
            return Array(pending.values)
        }
    }
}

/// One commit of the paced shape, back to back: 1, 10 and 100 keys in one
/// payload through the client-only list query, with one reader per written
/// record and the 20 readers of the page's own characters.
@MainActor
func pacedBench(data: Data, next: () -> Int) async throws {
    for keys in [1, 10, 100] {
        let stage = try await StreamStage(data: data)
        let store = stage.store
        let ids = tickIDs(keys)
        try await commitLive(stage.environment, ids.enumerated().map { Tick(index: next() + $0.offset, id: $0.element) })
        let written = try ids.map { try stage.written($0) }
        let readers = stage.others + written
        func ticks() -> [Tick] {
            let base = next() * 100
            return ids.enumerated().map { Tick(index: base + $0.offset, id: $0.element) }
        }
        let label = "paced commit, \(keys) key\(keys == 1 ? "" : "s") in one payload"
        let observer = Observer()
        var payload = livePayload(ticks())
        let collections = store.collections
        stage.log.reset()
        await measureAsync(label + ", the whole call", iterations: 200, observer: observer, setup: {
            payload = livePayload(ticks())
            observer.observe(readers) { $0() }
        }) {
            try? await stage.environment.commitPayload(BenchLive(), payload)
        }
        let commits = max(stage.log.commits, 1)
        count("slots-changed-per-paced-commit-\(keys)", stage.log.changed / commits, "    slots changed per commit: \(stage.log.changed / commits); notifications per commit: \(observer.fired / rounds(200)) (\(keys) written record\(keys == 1 ? "" : "s")' readers of \(readers.count))")
        count("notifications-per-paced-commit-\(keys)", observer.fired / rounds(200), "")
        count("collections-over-paced-commits-\(keys)", store.collections - collections, "    collections over the samples: \(store.collections - collections)")

        // The halves, measured apart: the ingest, which the door runs off
        // the main actor, and the commit, which it runs on it.
        let plan = BenchLive.plan.resolve(BenchLive().variables, in: store.keys)
        let bytes = livePayload(ticks()).bytes
        measure(label + ", its ingest alone", iterations: 200, gate: "paced-ingest-\(keys)") {
            _ = try! Ingest.normalize(bytes, plan: plan, rootKey: Store.rootKey)
        }
        var changes = try Ingest.normalize(bytes, plan: plan, rootKey: Store.rootKey)
        let halves = Observer()
        measure(label + ", its commit alone, on the main actor", iterations: 200, observer: halves, gate: "paced-commit-\(keys)", setup: {
            changes = try! Ingest.normalize(livePayload(ticks()).bytes, plan: plan, rootKey: Store.rootKey)
            halves.observe(readers) { $0() }
        }) {
            _ = store.commit(changes)
        }
        stage.end()
    }
}

/// What a paced sustained run measured.
struct PacedRun {
    var wall: UInt64 = 0
    var main: UInt64 = 0
    var ticks = 0
    var commits = 0
    var values = 0
    var lagMedian: UInt64 = 0
    var lagWorst: UInt64 = 0
    var diskBytes: UInt64 = 0
    var fileGrowth = 0
    var flushAfterLastTick: UInt64 = 0
    var writes = 0
    var batches = 0
    var fired = 0
    var landed = true
    var collections = 0
}

/// Ticks at `rate` a second for `seconds`, over `keys` keys, with an image
/// attached: a producer thread offers each tick to the pacer at its time,
/// and a service's loop off the main actor drains the pacer `perSecond`
/// times a second and commits what it drained in one payload through the
/// client-only list query. The lag is each committed value's, from its
/// tick's arrival to the commit that carried it; a tick a newer one of its
/// key replaced before the drain is never committed. A drain carries the
/// keys that ticked since the last one, so the list's links change and,
/// when a key of the last list is not in this one, the commit schedules a
/// collection; `listing` lists every known key instead, in the order each
/// first ticked, a key that did not tick by its id alone, so the list only
/// grows and drops no link.
@MainActor
func pacedSustained(_ data: Data, rate: Int, keys: Int, perSecond: Int, seconds: Double, imaged: Bool = false, listing: Bool = false, next: () -> Int) async throws -> PacedRun {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("baton-bench-stream-\(UUID().uuidString).sqlite")
    defer { removeImage(url) }
    let persistence = Persistence(url: url)
    let stage = try await StreamStage(data: data, persistence: persistence)
    let ids = tickIDs(keys)
    try await commitLive(stage.environment, ids.enumerated().map { Tick(index: next() + $0.offset, id: $0.element) }, imaged: imaged)
    await persistence.flush()
    let reader = LiveReader(try stage.written(ids[0]))
    let others = Observer()
    others.observe(stage.others) { $0() }

    let total = max(1, Int(Double(rate) * seconds))
    let base = next() * total
    let environment = stage.environment
    let pacer = TickPacer()
    let done = Atomic<Bool>(false)
    let interval = Duration.nanoseconds(1_000_000_000 / perSecond)
    stage.log.reset()
    let sizeBefore = imageSize(url)
    let diskBefore = diskBytesWritten()
    let collections = stage.store.collections
    let cpu = threadCPUTime()
    let sends = Sends()
    // The service's loop, off the main actor: once per interval, on a
    // schedule that does not drift, everything pending in one payload.
    let service = Task.detached { () -> [[UInt64]] in
        var arrivals: [[UInt64]] = []
        let known = ids
        let clock = ContinuousClock()
        var due = clock.now + interval
        while true {
            try? await Task.sleep(until: due, clock: clock)
            due += interval
            let finished = done.load(ordering: .acquiring)
            let pending = pacer.drain()
            if !pending.isEmpty {
                arrivals.append(pending.map(\.arrival))
                if listing {
                    let ticked = Dictionary(uniqueKeysWithValues: pending.map { ($0.tick.id, $0.tick) })
                    let listed = known.map { id in ticked[id].map { BenchLive.RawResponse.LiveCharacters(id: id, status: $0.status, created: $0.created) } ?? .init(id: id) }
                    try? await environment.commitPayload(BenchLive(), BenchLive.RawResponse(liveCharacters: listed).payload)
                } else {
                    try? await commitLive(environment, pending.map(\.tick), imaged: imaged)
                }
            }
            if finished { return arrivals }
        }
    }
    let spacing = 1e9 / Double(rate)
    let producer = Thread {
        let start = DispatchTime.now().uptimeNanoseconds + 1_000_000
        for offset in 0..<total {
            let target = start + UInt64(Double(offset) * spacing)
            let now = DispatchTime.now().uptimeNanoseconds
            if target > now {
                var wait = timespec(tv_sec: Int((target - now) / 1_000_000_000), tv_nsec: Int((target - now) % 1_000_000_000))
                nanosleep(&wait, nil)
            }
            let sent = DispatchTime.now().uptimeNanoseconds
            if offset == 0 { sends.first.store(sent, ordering: .relaxed) }
            pacer.offer(Tick(index: base + offset, id: ids[offset % keys]), at: sent)
            if offset == total - 1 { sends.last.store(sent, ordering: .relaxed) }
        }
        done.store(true, ordering: .releasing)
    }
    producer.qualityOfService = .userInitiated
    producer.start()
    let arrivals = await service.value
    var run = PacedRun()
    run.ticks = total
    run.landed = await stage.log.wait(for: arrivals.count, timeout: .seconds(10))
    run.main = threadCPUTime() - cpu
    let times = stage.log.times
    let first = sends.first.load(ordering: .relaxed)
    let last = sends.last.load(ordering: .relaxed)
    run.wall = max((times.last ?? last) - first, UInt64(Double(total) * spacing))
    run.commits = times.count
    var lags: [UInt64] = []
    for (commit, drained) in zip(times, arrivals) {
        for arrival in drained { lags.append(commit > arrival ? commit - arrival : 0) }
    }
    lags.sort()
    run.values = lags.count
    run.lagMedian = lags.isEmpty ? 0 : lags[lags.count / 2]
    run.lagWorst = lags.last ?? 0
    await persistence.flush()
    run.flushAfterLastTick = DispatchTime.now().uptimeNanoseconds - last
    run.diskBytes = diskBytesWritten() - diskBefore
    run.fileGrowth = imageSize(url) - sizeBefore
    run.writes = stage.log.writes
    run.batches = stage.log.batches
    run.fired = reader.fired
    run.collections = stage.store.collections - collections
    if others.pending != 0 { print("    \(others.pending) notifications reached the other readers") }
    stage.end()
    await persistence.close()
    return run
}

@MainActor
func pacedSustainedBench(data: Data, next: () -> Int) async throws {
    let seconds = options.quick ? 0.5 : 10
    print("  paced, \(Int(seconds)) s a run, image attached; per run: main-thread busy per second of wall, lag of the committed values (median, worst), image bytes a second, flush after the last tick")
    func record(_ name: String, _ run: PacedRun) {
        let wall = Double(run.wall) / 1e9
        let busy = Double(run.main) / wall
        let line = String(format: "  %-66@ busy %7.2f ms/s  lag %9@ (worst %9@)  written %9d B (%8.0f B/s)  file +%8d B  flush %9@  writes %4d (%5d batches)  commits %4d (%5.1f/s)  collections %4d  values %6d of %6d ticks  fired %4d%@",
                          name as NSString, busy / 1e6, format(Double(run.lagMedian)) as NSString, format(Double(run.lagWorst)) as NSString,
                          run.diskBytes, Double(run.diskBytes) / wall, run.fileGrowth, format(Double(run.flushAfterLastTick)) as NSString,
                          run.writes, run.batches, run.commits, Double(run.commits) / wall, run.collections, run.values, run.ticks, run.fired, run.landed ? "" : "  (did not land)")
        figure("\(name) busy", busy, unit: "ns/s", line)
        figure("\(name) lag", Double(run.lagMedian), unit: "ns")
        figure("\(name) worst lag", Double(run.lagWorst), unit: "ns")
        figure("\(name) disk", Double(run.diskBytes) / wall, unit: "B/s")
        figure("\(name) flush", Double(run.flushAfterLastTick), unit: "ns")
    }
    for (rate, keys) in [(1_000, 100), (100, 10)] {
        for perSecond in [10, 30, 60] {
            record("paced, \(rate)/s over \(keys) keys, \(perSecond) commits/s", try await pacedSustained(data, rate: rate, keys: keys, perSecond: perSecond, seconds: seconds, next: next))
        }
    }
    record("paced, root not transient, 1000/s over 100 keys, 30 commits/s", try await pacedSustained(data, rate: 1_000, keys: 100, perSecond: 30, seconds: seconds, imaged: true, next: next))
    for (rate, keys) in [(1_000, 100), (100, 10)] {
        for perSecond in [30, 60] {
            record("paced, every key listed, \(rate)/s over \(keys) keys, \(perSecond) commits/s", try await pacedSustained(data, rate: rate, keys: keys, perSecond: perSecond, seconds: seconds, listing: true, next: next))
        }
    }
}

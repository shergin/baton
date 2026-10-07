@_spi(Generated) import Baton
import BatonSpec
import BatonTesting
import Foundation
import Observation
import Synchronization
import Testing

/// A script of `spec/manifest.json`, by the path of its file.
struct ScriptCase: Sendable, CustomTestStringConvertible {
    let path: String

    var testDescription: String { path }

    static let all = Spec.manifest.scripts.map(ScriptCase.init(path:))
}

@MainActor
@Suite("The scripts", .timeLimit(.minutes(1)))
struct ScriptTests {
    @Test("a script's steps leave the store, the handles and the log as the script says after each step", arguments: ScriptCase.all)
    func theRuntimeFollowsTheScript(_ entry: ScriptCase) async throws {
        let script = try Manifest.Script.load(entry.path)
        #expect(entry.path == "scripts/\(script.name).json", "a script is named for its file")
        let run = ScriptRun(script)
        await run.run()
    }
}

/// One run of a script: the environment it runs in, the transport the steps
/// answer through, and what the steps named.
@MainActor
final class ScriptRun {
    let script: Manifest.Script
    /// Holds every query and mutation until a step answers it, and lets the
    /// steps drive every subscription and every deferred response.
    let transport = ScriptedTransport()
    let image: TemporaryImage?
    let heard = HeardEvents()
    var environment: Environment
    var handles: [String: LiveHandle] = [:]
    var layers: [String: Layer] = [:]
    /// The last check's answer.
    var answer: Store.Answer?
    /// Where the run is, for the messages.
    var context = ""

    var store: Store { environment.store }

    /// A mutation in flight under its optimistic layer.
    struct Layer {
        let operation: OracleOperation
        let task: Task<Void, any Error>
    }

    init(_ script: Manifest.Script) {
        self.script = script
        let image = script.image ? TemporaryImage() : nil
        self.image = image
        environment = Self.environment(script, image: image, transport: transport, heard: heard, clockOffset: .zero)
    }

    static func environment(_ script: Manifest.Script, image: TemporaryImage?, transport: ScriptedTransport, heard: HeardEvents, clockOffset: Duration) -> Environment {
        let store = Store(persistence: image.map { Persistence(url: $0.url) }, cacheExpiration: script.expiration.map { .seconds($0) }, releaseBufferSize: script.buffer)
        store.clockOffset = clockOffset
        let environment = Environment(transport: transport, subscriptions: transport, store: store)
        environment.log = heard.log
        return environment
    }

    func fail(_ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        Issue.record("\(context)\(message)", sourceLocation: sourceLocation)
    }

    func run() async {
        for (index, step) in script.steps.enumerated() {
            context = "\(script.name), step \(index) (\(step.action.kind)): "
            heard.clear()
            let notified = step.notified == nil ? nil : observeEverySlot()
            let thrown = await perform(step.action)
            // A pass a step scheduled runs on a later turn of the main actor.
            // A stream that failed is compared at once, before a backoff,
            // which another suite may have shortened, could open it again.
            if case .event(_, .failure) = step.action {} else {
                for _ in 0..<10 { await Task.yield() }
            }
            check(step, thrown: thrown, notified: notified)
        }
        await environment.end()
    }

    // MARK: The steps

    func bind(_ operation: Manifest.Operation) -> OracleOperation? {
        do {
            let bound = try OracleOperation.bind(operation.name, StepVariables(name: context, variables: operation.variables))
            if bound.hasDeferred { transport.drive(bound.name) } else { transport.hold(bound.name) }
            return bound
        } catch {
            fail("\(error)")
            return nil
        }
    }

    func handle(_ name: String) -> LiveHandle? {
        guard let handle = handles[name] else {
            fail("no handle is named \(name)")
            return nil
        }
        return handle
    }

    /// Runs a step; returns what it threw.
    func perform(_ action: Manifest.Action) async -> (any Error)? {
        switch action {
        case .commit(let reference, let responses):
            guard let operation = bind(reference) else { return nil }
            let sent = requests(of: operation)
            let finished = Flag()
            let task: Task<Void, any Error>
            switch operation.kind {
            case .query:
                guard let fetch = operation.fetch else { return nil }
                let environment = environment
                task = Task { defer { finished.isSet = true }; try await fetch(environment) }
            case .mutation:
                task = mutation(operation, optimistic: nil, finished: finished)
            case .subscription:
                fail("a subscription's events are committed by an event step")
                return nil
            }
            await deliver(.parts(responses.map(Spec.data)), to: operation, newerThan: sent, finished: finished)
            return await task.result.failure

        case .payload(let reference, let response):
            guard let operation = bind(reference) else { return nil }
            do {
                try await Self.commitPayload(operation.value, Spec.data(response), in: environment)
                return nil
            } catch {
                return error
            }

        case .optimistic(let reference, let response, let name):
            guard let operation = bind(reference), let optimistic = optimisticVariable(response) else { return nil }
            let sent = requests(of: operation)
            let finished = Flag()
            let task = mutation(operation, optimistic: optimistic, finished: finished)
            await until { self.requests(of: operation) > sent || finished.isSet }
            layers[name] = Layer(operation: operation, task: task)
            return nil

        case .resolve(let name, let response):
            guard let layer = layers[name] else {
                fail("no layer is named \(name)")
                return nil
            }
            await deliver(.parts([Spec.data(response)]), to: layer.operation, newerThan: nil, finished: Flag())
            return await layer.task.result.failure

        case .revert(let name):
            guard let layer = layers[name] else {
                fail("no layer is named \(name)")
                return nil
            }
            await deliver(.failure(.transport), to: layer.operation, newerThan: nil, finished: Flag())
            return await layer.task.result.failure

        case .attach(let reference, let policy, let name, let reply):
            guard let operation = bind(reference) else { return nil }
            let live: LiveHandle
            if let query = operation.value as? any Query {
                live = LiveHandle.query(query, operation: operation, policy: policy, in: environment)
            } else if let subscription = operation.value as? any Subscription {
                live = LiveHandle.subscription(subscription, operation: operation, in: environment)
            } else {
                fail("\(operation.name) is a mutation, which has no handle")
                return nil
            }
            handles[name] = live
            guard let reply else { return nil }
            guard live.inFlight() else {
                fail("the attach made no fetch for the step's reply to answer")
                return nil
            }
            await deliver(Answering(reply), to: operation, newerThan: nil, finished: Flag())
            await live.settle()
            return nil

        case .answer(let name, let reply):
            guard let live = handle(name) else { return nil }
            guard live.inFlight() else {
                fail("\(name) has no fetch in flight to answer")
                return nil
            }
            await deliver(Answering(reply), to: live.operation, newerThan: nil, finished: Flag())
            await live.settle()
            return nil

        case .refetch(let name, let reply):
            guard let live = handle(name) else { return nil }
            let sent = requests(of: live.operation)
            let finished = Flag()
            let task = Task { defer { finished.isSet = true }; try await live.refetch() }
            await deliver(Answering(reply), to: live.operation, newerThan: sent, finished: finished)
            return await task.result.failure

        case .retry(let name, let reply):
            guard let live = handle(name) else { return nil }
            let sent = requests(of: live.operation)
            live.retry()
            guard let reply else { return nil }
            await deliver(Answering(reply), to: live.operation, newerThan: sent, finished: Flag())
            await live.settle()
            return nil

        case .release(let name):
            handle(name)?.retention = nil
            return nil

        case .collect:
            store.collect()
            return nil

        case .advance(let seconds):
            store.clockOffset += .seconds(seconds)
            return nil

        case .invalidate:
            environment.invalidate()
            return nil

        case .revalidate:
            environment.revalidate()
            return nil

        case .check(let reference):
            guard let operation = bind(reference) else { return nil }
            answer = store.check(operation.plan.resolve(operation.variables, in: store.keys))
            return nil

        case .relaunch:
            let offset = store.clockOffset
            await environment.end()
            environment = Self.environment(script, image: image, transport: transport, heard: heard, clockOffset: offset)
            return nil

        case .event(let name, let delivery):
            guard let live = handle(name) else { return nil }
            guard live.isSubscription else {
                fail("\(name) is not a subscription's handle")
                return nil
            }
            // The stream the handle holds now: one opened per connection,
            // the first and each resumption.
            await until { self.requests(of: live.operation) > live.resumptions() }
            guard let stream = transport.driven.last(where: { live.operation.sent($0.request) }) else {
                fail("\(name) holds no open stream to deliver to")
                return nil
            }
            let before = live.signature()
            switch delivery {
            case .response(let response): stream.send(Spec.data(response))
            case .failure(.transport): stream.fail(Self.transportFailure)
            case .failure(.request): stream.fail(GraphQLErrors(messages: ["the script refuses the subscription"]))
            case .failure(.malformed): stream.send(Self.malformedResponse)
            case .complete: stream.complete()
            }
            await until { live.signature() != before }
            return nil

        case .active(let value):
            environment.isActive = value
            return nil

        case .end:
            await environment.end()
            return nil
        }
    }

    /// A mutation sent in a task of its own, as an action sends it.
    func mutation(_ operation: OracleOperation, optimistic: Variable?, finished: Flag) -> Task<Void, any Error> {
        guard let mutation = operation.value as? any Mutation else {
            fail("\(operation.name) is not a mutation")
            return Task {}
        }
        let environment = environment
        return Task {
            defer { finished.isSet = true }
            try await Self.mutate(mutation, optimistic: optimistic, in: environment)
        }
    }

    static func mutate<Op: Mutation>(_ operation: Op, optimistic: Variable?, in environment: Environment) async throws {
        _ = try await environment.mutate(operation, optimistic: optimistic)
    }

    static func commitPayload<Op: Baton.Operation>(_ operation: Op, _ payload: Data, in environment: Environment) async throws {
        try await environment.commitPayload(operation, payload)
    }

    /// The `data` of a response, as the variable an optimistic response is
    /// given as.
    func optimisticVariable(_ response: String) -> Variable? {
        guard let value = try? JSONDecoder().decode(Manifest.Value.self, from: Spec.data(response)),
            case .object(let members) = value, let data = members["data"]
        else {
            fail("\(response) has no data to apply")
            return nil
        }
        return Variable(data)
    }

    // MARK: The transport

    /// How a step answers a request: with the parts of a response, or a
    /// failure.
    enum Answering {
        case parts([Data])
        case failure(Manifest.FailureKind)

        init(_ reply: Manifest.Reply) {
            switch reply {
            case .response(let path): self = .parts([Spec.data(path)])
            case .failure(let kind): self = .failure(kind)
            }
        }
    }

    static let transportFailure = TransportError(statusCode: 503, body: "the script fails the request")
    /// Errors and no data: the server refused the request.
    static let requestFailure = Data(#"{"data":null,"errors":[{"message":"the script refuses the request"}]}"#.utf8)
    /// No data and no errors: a response no plan can read.
    static let malformedResponse = Data("{}".utf8)

    /// How many requests of the operation the transport was sent.
    func requests(of operation: OracleOperation) -> Int {
        transport.requests.count(where: operation.sent)
    }

    /// Answers the newest request of the operation: one sent after the
    /// first `newerThan` of its kind, or one already held. Stops waiting when
    /// the work that would send it has finished without sending.
    func deliver(_ answering: Answering, to operation: OracleOperation, newerThan sent: Int?, finished: Flag) async {
        if let sent {
            await until { self.requests(of: operation) > sent || finished.isSet }
        } else {
            await until { self.transport.held.contains { operation.sent($0.request) } || self.transport.driven.contains { operation.sent($0.request) } || finished.isSet }
        }
        if let stream = transport.driven.last(where: { operation.sent($0.request) }) {
            switch answering {
            case .parts(let parts):
                for part in parts { stream.send(part) }
                stream.complete()
            case .failure(.transport): stream.fail(Self.transportFailure)
            case .failure(.request):
                stream.send(Self.requestFailure)
                stream.complete()
            case .failure(.malformed):
                stream.send(Self.malformedResponse)
                stream.complete()
            }
            return
        }
        guard let held = transport.held.last(where: { operation.sent($0.request) }) else {
            if !finished.isSet { fail("no request of \(operation.name) waits for an answer") }
            return
        }
        switch answering {
        case .parts(let parts):
            if parts.count != 1 { fail("\(operation.name) takes one response, not \(parts.count) parts") }
            held.respond(parts.first ?? Self.malformedResponse)
        case .failure(.transport): held.refuse(Self.transportFailure)
        case .failure(.request): held.respond(Self.requestFailure)
        case .failure(.malformed): held.respond(Self.malformedResponse)
        }
    }

    // MARK: The expectations

    /// Observes every stored slot of every record, each on its own, so the
    /// notifications of a step are known slot by slot.
    func observeEverySlot() -> Notified {
        let notified = Notified()
        for (key, record) in store.recordsByKey {
            for entry in record.storedSlots {
                let field = store.storageKey(of: entry.slot)
                let slot = entry.slot
                withObservationTracking {
                    _ = record.read(slot)
                } onChange: {
                    notified.insert(Manifest.Notification(record: key, field: field))
                }
            }
        }
        return notified
    }

    func check(_ step: Manifest.Step, thrown: (any Error)?, notified: Notified?) {
        if let expected = step.error {
            if let thrown {
                let kind = Self.kind(of: thrown)
                if kind != expected { fail("the step threw \(kind) (\(thrown)) where the script has \(expected)") }
            } else {
                fail("the step threw nothing where the script has \(expected)")
            }
        } else if let thrown, step.action.kind != "revert" {
            fail("the step threw \(Self.kind(of: thrown)): \(thrown)")
        }

        if let notified, let expected = step.notified {
            let actual = notified.all
            let wanted = Set(expected)
            let extra = actual.subtracting(wanted).map(\.description).sorted()
            let missing = wanted.subtracting(actual).map(\.description).sorted()
            if !extra.isEmpty { fail("the step notified \(extra), which the script does not list") }
            if !missing.isEmpty { fail("the step did not notify \(missing)") }
        }

        if let records = step.records {
            let suffix = ".store.json"
            let name = records.hasSuffix(suffix) ? String(records.dropLast(suffix.count)) : records
            StoreDump.expectMatches(store, name, context: context)
        }

        if let expected = step.recordsHeld {
            let held = store.recordsByKey.keys.sorted()
            if held != expected.sorted() {
                let extra = Set(held).subtracting(expected).sorted()
                let missing = Set(expected).subtracting(held).sorted()
                fail("the store holds \(extra) beyond the script's records and lacks \(missing)")
            }
        }

        if let expected = step.answer {
            let actual = answer.map(Self.word) ?? "none"
            if actual != expected.rawValue { fail("the check answered \(actual) where the script has \(expected.rawValue)") }
        }

        for row in step.reads { read(row) }

        for expected in step.phases {
            guard let live = handle(expected.handle) else { continue }
            let phase = live.phase()
            if phase != expected.phase { fail("\(expected.handle) reads \(phase) where the script has \(expected.phase)") }
            if let refreshing = expected.isRefreshing, live.isRefreshing() != refreshing {
                fail("\(expected.handle) is\(refreshing ? " not" : "") refreshing where the script says it is\(refreshing ? "" : " not")")
            }
            if let stale = expected.isStale, live.isStale() != stale {
                fail("\(expected.handle) is\(stale ? " not" : "") stale where the script says it is\(stale ? "" : " not")")
            }
        }

        for expected in step.fetches {
            guard let live = handle(expected.handle) else { continue }
            let fetch = live.fetch()
            if fetch != expected.fetch { fail("\(expected.handle)'s fetch is \(fetch) where the script has \(expected.fetch)") }
        }

        for expected in step.streams {
            guard let live = handle(expected.handle) else { continue }
            let stream = live.stream()
            if stream != expected.stream { fail("\(expected.handle)'s stream is \(stream) where the script has \(expected.stream)") }
            if let events = expected.events, live.events() != events {
                fail("\(expected.handle) counted \(live.events()) events where the script has \(events)")
            }
            if let resumptions = expected.resumptions, live.resumptions() != resumptions {
                fail("\(expected.handle) counted \(live.resumptions()) resumptions where the script has \(resumptions)")
            }
        }

        if let expected = step.events {
            let actual = heard.all.compactMap(Self.event)
            let matches = actual.count == expected.count && zip(actual, expected).allSatisfy { actual, expected in
                actual.name == expected.name && expected.fields.allSatisfy { actual.fields[$0.key] == $0.value }
            }
            if !matches { fail("the log heard \(actual) where the script has \(expected)") }
        }
    }

    func read(_ row: Manifest.ScriptRead) {
        let operation: OracleOperation
        let anchor: Anchor
        if let name = row.handle {
            guard let live = handle(name) else { return }
            guard let data = live.anchor() else {
                fail("\(name) has no data to read \(row.path) from: it reads \(live.phase())")
                return
            }
            operation = live.operation
            anchor = data
        } else if let name = row.operation {
            guard let bound = bind(Manifest.Operation(name: name, variables: row.variables)) else { return }
            operation = bound
            let record: Record =
                switch bound.kind {
                case .query: store.root
                case .mutation: store.mutationRoot
                case .subscription: store.subscriptionRoot
                }
            anchor = Anchor(record: record, variables: bound.variables, store: store)
        } else {
            fail("the read of \(row.path) names neither a handle nor an operation")
            return
        }
        guard let reader = operation.readers[row.path] else {
            fail("no reader of \(operation.name) for \(row.path)")
            return
        }
        let value = reader(anchor)
        let expected = operation.spellings[row.path]?(row.value) ?? row.value
        if !value.isSameJSON(as: expected) {
            fail("the lens reads \(row.path) of \(operation.name) as \(value) where the script has \(row.value)")
        }
    }

    static func word(_ answer: Store.Answer) -> String {
        switch answer {
        case .memory: "memory"
        case .image: "image"
        case .miss: "miss"
        }
    }

    /// The kind of what a step threw or a phase failed with.
    static func kind(of error: any Error) -> String {
        switch error {
        case is FieldErrors: "fieldErrors"
        case is RequiredFieldError: "requiredField"
        case is MissingDataError: "missingData"
        case let error as EnvironmentError: error == .gone ? "gone" : "environment"
        case is GraphQLErrors: "request"
        case is IngestError: "malformed"
        case let failure as Failure: kind(of: failure)
        default: "transport"
        }
    }

    static func kind(of failure: Failure) -> String {
        switch failure {
        case .transport: "transport"
        case .request: "request"
        case .malformed: "malformed"
        case .environment: "environment"
        }
    }

    /// A log event as a script spells it; nil for the image's events, whose
    /// timing is the writer's.
    static func event(_ event: LogEvent) -> Manifest.Event? {
        switch event {
        case .fetchStarted(let operation):
            Manifest.Event(name: "fetchStarted", fields: ["operation": .string(operation)])
        case .fetchCompleted(let operation, _):
            Manifest.Event(name: "fetchCompleted", fields: ["operation": .string(operation)])
        case .fetchFailed(let operation, let kind):
            Manifest.Event(name: "fetchFailed", fields: ["operation": .string(operation), "kind": .string("\(kind)")])
        case .committed(let kind, let changed):
            Manifest.Event(name: "committed", fields: ["kind": .string("\(kind)"), "changed": .int(changed)])
        case .fieldError(let operation, let path):
            Manifest.Event(name: "fieldError", fields: ["operation": .string(operation), "path": .string(path)])
        case .missing(let type, let field):
            Manifest.Event(name: "missing", fields: ["type": .string(type), "field": .string(field)])
        case .unexpected(let type, let field):
            Manifest.Event(name: "unexpected", fields: ["type": .string(type), "field": .string(field)])
        case .ambiguousIdentity(let id, let types):
            Manifest.Event(name: "ambiguousIdentity", fields: ["id": .string(id), "types": .list(types.map(Manifest.Value.string))])
        case .requiredFieldMissing(let type, let path):
            Manifest.Event(name: "requiredFieldMissing", fields: ["type": .string(type), "path": .string(path)])
        case .partDropped(let path):
            Manifest.Event(name: "partDropped", fields: ["path": .string(path)])
        case .imageOpened, .imageUnavailable, .imageWritten, .imageWriteFailed:
            nil
        }
    }
}

/// A handle a script named, of a query or of a subscription, read through
/// what the script compares.
@MainActor
final class LiveHandle {
    let operation: OracleOperation
    let isSubscription: Bool
    /// The retention the attach made; a release ends it.
    var retention: Retention?
    let phase: () -> Manifest.State
    let fetch: () -> Manifest.State
    let isRefreshing: () -> Bool
    let isStale: () -> Bool
    let inFlight: () -> Bool
    /// The anchor of the data the phase shows, when it shows data.
    let anchor: () -> Anchor?
    let refetch: () async throws -> Void
    let retry: () -> Void
    let settle: () async -> Void
    let stream: () -> Manifest.State
    let events: () -> Int
    let resumptions: () -> Int
    /// What changes when a stream takes a delivery: its events, its state
    /// and whether its last event failed.
    let signature: () -> String

    private init(
        operation: OracleOperation, isSubscription: Bool, phase: @escaping () -> Manifest.State, fetch: @escaping () -> Manifest.State,
        isRefreshing: @escaping () -> Bool, isStale: @escaping () -> Bool, inFlight: @escaping () -> Bool, anchor: @escaping () -> Anchor?,
        refetch: @escaping () async throws -> Void, retry: @escaping () -> Void, settle: @escaping () async -> Void,
        stream: @escaping () -> Manifest.State, events: @escaping () -> Int, resumptions: @escaping () -> Int, signature: @escaping () -> String
    ) {
        self.operation = operation
        self.isSubscription = isSubscription
        self.phase = phase
        self.fetch = fetch
        self.isRefreshing = isRefreshing
        self.isStale = isStale
        self.inFlight = inFlight
        self.anchor = anchor
        self.refetch = refetch
        self.retry = retry
        self.settle = settle
        self.stream = stream
        self.events = events
        self.resumptions = resumptions
        self.signature = signature
    }

    static func query<Op: Query>(_ value: Op, operation: OracleOperation, policy: Manifest.Policy, in environment: Environment) -> LiveHandle {
        let fetchPolicy: FetchPolicy =
            switch policy {
            case .storeOrNetwork: .storeOrNetwork
            case .storeAndNetwork: .storeAndNetwork
            case .networkOnly: .networkOnly
            case .storeOnly: .storeOnly
            }
        let handle = environment.handle(for: value, fetchPolicy: fetchPolicy)
        let none = Manifest.State.plain("none")
        let live = LiveHandle(
            operation: operation,
            isSubscription: false,
            phase: {
                switch handle.phase {
                case .loading: .plain("loading")
                case .ready: .plain("ready")
                case .failed(let error): .tagged("failed", ScriptRun.kind(of: error))
                }
            },
            fetch: {
                switch handle.fetch {
                case .idle: .plain("idle")
                case .inFlight: .plain("inFlight")
                case .failed(let failure, _): .tagged("failed", ScriptRun.kind(of: failure))
                }
            },
            isRefreshing: { handle.isRefreshing },
            isStale: { handle.isStale },
            inFlight: {
                guard case .inFlight = handle.fetch else { return false }
                return true
            },
            anchor: {
                guard case .ready(let data) = handle.phase else { return nil }
                return data.anchor
            },
            refetch: { try await handle.refetch() },
            retry: { handle.retry() },
            settle: { await handle.settle() },
            stream: { none },
            events: { 0 },
            resumptions: { 0 },
            signature: { "" }
        )
        live.retention = handle.retain()
        return live
    }

    static func subscription<Op: Subscription>(_ value: Op, operation: OracleOperation, in environment: Environment) -> LiveHandle {
        let handle = environment.subscriptionHandle(for: value)
        let none = Manifest.State.plain("none")
        let stream = { () -> Manifest.State in
            switch handle.stream {
            case .idle: .plain("idle")
            case .connecting: .plain("connecting")
            case .open: .plain("open")
            case .waiting: .plain("waiting")
            case .ended(let failure): .tagged("ended", failure.map(ScriptRun.kind(of:)))
            }
        }
        let live = LiveHandle(
            operation: operation,
            isSubscription: true,
            phase: { none },
            fetch: { none },
            isRefreshing: { false },
            isStale: { false },
            inFlight: { false },
            anchor: { handle.latest?.anchor },
            refetch: {},
            retry: { handle.retry() },
            settle: {},
            stream: stream,
            events: { handle.events },
            resumptions: { handle.resumptions },
            signature: { "\(handle.events) \(stream()) \(handle.error == nil)" }
        )
        live.retention = handle.retain()
        return live
    }
}

/// The variables a step gives an operation, named for the messages.
struct StepVariables: OperationVariables {
    let name: String
    let variables: [String: Manifest.Value]
}

/// Whether a task a step started has finished.
@MainActor
final class Flag: Sendable {
    var isSet = false
}

/// The fields observations were told of during a step. Locked, since an
/// observation's change handler is not isolated.
final class Notified: Sendable {
    private let fields = Mutex<Set<Manifest.Notification>>([])

    func insert(_ notification: Manifest.Notification) {
        fields.withLock { _ = $0.insert(notification) }
    }

    var all: Set<Manifest.Notification> { fields.withLock { $0 } }
}

/// The events the environment's log heard since the step began. Locked,
/// since the image's writer logs off the main actor.
final class HeardEvents: Sendable {
    private let heard = Mutex<[LogEvent]>([])

    var all: [LogEvent] { heard.withLock { $0 } }

    func clear() { heard.withLock { $0.removeAll() } }

    var log: @Sendable (LogEvent) -> Void {
        { event in self.heard.withLock { $0.append(event) } }
    }
}

extension OracleOperation {
    /// Whether a request is one of this operation value.
    func sent(_ request: Request) -> Bool {
        request.operationName == name && request.variables == variables
    }
}

extension Result {
    /// The error, when the result is a failure.
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

extension Variable {
    /// A manifest value as the variable an optimistic response is given as.
    init(_ value: Manifest.Value) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .int(let int): self = .int(int)
        case .double(let double): self = .double(double)
        case .string(let string): self = .string(string)
        case .list(let items): self = .list(items.map(Variable.init))
        case .object(let members): self = .object(members.mapValues(Variable.init))
        }
    }
}

extension Manifest.Script {
    /// The operations the script's steps and reads name.
    var operations: [Manifest.Operation] {
        steps.flatMap { step -> [Manifest.Operation] in
            var named: [Manifest.Operation] = step.reads.compactMap { row in
                row.operation.map { Manifest.Operation(name: $0, variables: row.variables) }
            }
            switch step.action {
            case .commit(let operation, _), .payload(let operation, _), .optimistic(let operation, _, _), .attach(let operation, _, _, _), .check(let operation):
                named.append(operation)
            default:
                break
            }
            return named
        }
    }
}

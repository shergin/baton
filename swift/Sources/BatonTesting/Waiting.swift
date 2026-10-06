/// Waits for `condition` on the main actor, yielding to the tasks it depends
/// on between checks, until it holds or `timeout` passes: true when it held.
/// For an app's tests over a scripted transport, where a handle settles a
/// few hops after the answer; the test records the failure.
@MainActor
@discardableResult
public func wait(until condition: () -> Bool, timeout: Duration = .seconds(10)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        await Task.yield()
    }
    return true
}

#if canImport(AppKit)
import AppKit
import Baton

/// The app's lifecycle, told to an environment on macOS. A hidden app parks
/// its retained subscriptions and an unhidden one resumes them; an app the
/// user returns to refetches what went stale or failed while they were away.
/// A Mac app's window stays on screen when another app is frontmost, so
/// resigning active parks nothing.
@MainActor
public final class Activation {
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    public init(environment: Environment, center: NotificationCenter = .default) {
        self.center = center
        observers = [
            center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { environment.isActive = false }
            },
            center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { environment.isActive = true }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { environment.revalidate() }
            },
        ]
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
#endif

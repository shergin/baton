#if canImport(UIKit)
import Baton
import UIKit

/// The app's lifecycle, told to an environment on iOS. An app in the
/// background parks its retained subscriptions; an app coming back to the
/// foreground resumes them and refetches what went stale or failed while it
/// was away. The notifications are the application's, not a scene's: the
/// environment is the app's, and one scene leaving the screen while another
/// stays does not make the app inactive.
@MainActor
public final class Activation {
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    public init(environment: Environment, center: NotificationCenter = .default) {
        self.center = center
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { environment.isActive = false }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    environment.isActive = true
                    environment.revalidate()
                }
            },
        ]
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
#endif

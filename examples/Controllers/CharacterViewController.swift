#if canImport(AppKit)
import AppKit
import Baton

/// A character's detail, driven by a handle without SwiftUI. The controller
/// holds the handle and the retention that keeps its records alive, renders
/// once when its view loads, and again whenever anything it rendered changes.
@MainActor
public final class CharacterViewController: NSViewController {
    /// What the controller shows. It is computed inside the observed closure,
    /// so every field it reads is watched, and only those.
    enum Shown: Sendable {
        case loading
        case failed(String)
        case ready(name: String, details: String, origin: String)
    }

    private let handle: OperationHandle<CharacterQuery>
    private var retention: Retention?
    private var observation: Task<Void, Never>?

    public let nameLabel = NSTextField(labelWithString: "")
    public let detailsLabel = NSTextField(labelWithString: "")
    public let originLabel = NSTextField(labelWithString: "")
    public let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

    public init(environment: Environment, id: String) {
        handle = environment.handle(for: CharacterQuery(id: id))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        observation?.cancel()
    }

    public override func loadView() {
        nameLabel.font = .preferredFont(forTextStyle: .largeTitle)
        detailsLabel.textColor = .secondaryLabelColor
        errorLabel.textColor = .systemRed
        spinner.style = .spinning
        retryButton.target = self
        retryButton.action = #selector(retry)
        let stack = NSStackView(views: [spinner, nameLabel, detailsLabel, originLabel, errorLabel, retryButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view = stack
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        retention = handle.retain()
        // The first frame is read synchronously; the sequence then yields
        // after each change to what `shown` read, starting with the current
        // value, which renders the same thing again.
        render(Self.shown(handle.phase))
        observation = Task { [weak self, handle] in
            for await shown in Observations({ Self.shown(handle.phase) }) {
                self?.render(shown)
            }
        }
    }

    static func shown(_ phase: Phase<CharacterQuery.Data>) -> Shown {
        switch phase {
        case .loading:
            return .loading
        case .failed(let error):
            return .failed(String(describing: error))
        case .ready(let data):
            guard let character = data.character else { return .failed("No such character") }
            return .ready(
                name: character.name ?? "Unknown",
                details: [character.status, character.species].compactMap { $0 }.joined(separator: " · "),
                origin: character.origin?.name ?? "Unknown"
            )
        }
    }

    private func render(_ shown: Shown) {
        switch shown {
        case .loading:
            show(loading: true, name: "", details: "", origin: "", error: nil)
        case .failed(let message):
            show(loading: false, name: "", details: "", origin: "", error: message)
        case .ready(let name, let details, let origin):
            show(loading: false, name: name, details: details, origin: "Origin: \(origin)", error: nil)
        }
    }

    private func show(loading: Bool, name: String, details: String, origin: String, error: String?) {
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        nameLabel.stringValue = name
        detailsLabel.stringValue = details
        originLabel.stringValue = origin
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        retryButton.isHidden = error == nil
    }

    @objc private func retry() {
        handle.retry()
    }
}
#endif

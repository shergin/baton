#if canImport(UIKit)
import Baton
import UIKit

/// A character's detail, driven by a handle without SwiftUI. The controller
/// holds the handle and the retention that keeps its records alive, renders
/// once when its view loads, and again whenever anything it rendered changes.
@MainActor
public final class CharacterViewController: UIViewController {
    private let handle: OperationHandle<CharacterQuery>
    private var retention: Retention?
    private var observation: Task<Void, Never>?

    public let nameLabel = UILabel()
    public let detailsLabel = UILabel()
    public let originLabel = UILabel()
    public let errorLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(configuration: .bordered())

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
        detailsLabel.textColor = .secondaryLabel
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        retryButton.configuration?.title = "Retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.handle.retry() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [spinner, nameLabel, detailsLabel, originLabel, errorLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        stack.backgroundColor = .systemBackground
        view = stack
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        retention = handle.retain()
        // The first frame is read synchronously; the sequence then yields
        // after each change to what the content read, starting with the
        // current value, which renders the same thing again.
        render(CharacterContent(handle.phase))
        observation = Task { [weak self, handle] in
            for await content in Observations({ CharacterContent(handle.phase) }) {
                self?.render(content)
            }
        }
    }

    private func render(_ content: CharacterContent) {
        switch content {
        case .loading:
            show(loading: true, name: "", details: "", origin: "", error: nil)
        case .failed(let message):
            show(loading: false, name: "", details: "", origin: "", error: message)
        case .ready(let name, let details, let origin):
            show(loading: false, name: name, details: details, origin: "Origin: \(origin)", error: nil)
        }
    }

    private func show(loading: Bool, name: String, details: String, origin: String, error: String?) {
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        nameLabel.text = name
        detailsLabel.text = details
        originLabel.text = origin
        errorLabel.text = error
        errorLabel.isHidden = error == nil
        retryButton.isHidden = error == nil
    }
}
#endif

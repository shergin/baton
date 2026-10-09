#if canImport(UIKit)
import Baton
import UIKit

/// A page of characters in a table. The controller watches only which rows
/// there are; each cell watches the fields it shows, so a commit that renames
/// one character renders one cell and reloads nothing.
@MainActor
public final class CharactersViewController: UITableViewController {
    /// Called with the id of the character the user selects.
    public var selected: (String) -> Void = { _ in }

    private let handle: OperationHandle<CharactersQuery>
    private var retention: Retention?
    private var observation: Task<Void, Never>?
    private var rows: [CharactersContent.Row] = []

    public init(environment: Environment, page: Int = 1) {
        handle = environment.handle(for: CharactersQuery(page: page))
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        observation?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(CharacterCell.self, forCellReuseIdentifier: CharacterCell.identifier)
        retention = handle.retain()
        render(CharactersContent(handle.phase))
        observation = Task { [weak self, handle] in
            for await content in Observations({ CharactersContent(handle.phase) }) {
                self?.render(content)
            }
        }
    }

    private func render(_ content: CharactersContent) {
        switch content {
        case .loading:
            rows = []
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .failed(let message):
            rows = []
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = "Could not load"
            configuration.secondaryText = message
            var retry = UIButton.Configuration.bordered()
            retry.title = "Retry"
            configuration.button = retry
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.handle.retry() }
            contentUnavailableConfiguration = configuration
        case .ready(let ready):
            rows = ready
            contentUnavailableConfiguration = nil
        }
        tableView.reloadData()
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CharacterCell.identifier, for: indexPath)
        (cell as? CharacterCell)?.bind(rows[indexPath.row].character)
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selected(rows[indexPath.row].id)
    }
}

/// A row of the table. It takes a lens, not a model: the fragment's
/// generated struct, handed down by the controller as a parent view hands
/// it to a child.
@MainActor
public final class CharacterCell: UITableViewCell {
    static let identifier = "CharacterCell"

    private var observation: Task<Void, Never>?

    isolated deinit {
        observation?.cancel()
    }

    public func bind(_ character: CharacterCell_character) {
        observation?.cancel()
        render(CharacterCellContent(character))
        observation = Task { [weak self] in
            for await content in Observations({ CharacterCellContent(character) }) {
                self?.render(content)
            }
        }
    }

    /// A recycled cell stops watching the row it left before it is bound to
    /// the next one.
    public override func prepareForReuse() {
        super.prepareForReuse()
        observation?.cancel()
        observation = nil
    }

    private func render(_ content: CharacterCellContent) {
        var configuration = defaultContentConfiguration()
        configuration.text = content.name
        configuration.secondaryText = content.details
        configuration.secondaryTextProperties.color = .secondaryLabel
        contentConfiguration = configuration
    }
}
#endif

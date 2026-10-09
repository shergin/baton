#if canImport(AppKit)
import AppKit
import Baton

/// A page of characters in a table. The controller watches only which rows
/// there are; each cell watches the fields it shows, so a commit that renames
/// one character renders one cell and reloads nothing.
@MainActor
public final class CharactersViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// The rows, by their position in the response: the character's id and
    /// the lens its cell reads.
    public enum Shown: Sendable {
        case loading
        case failed(String)
        case ready([(id: String, character: CharacterCell_character)])
    }

    /// Called with the id of the character the user selects.
    public var selected: (String) -> Void = { _ in }

    private let handle: OperationHandle<CharactersQuery>
    private var retention: Retention?
    private var observation: Task<Void, Never>?
    private var rows: [(id: String, character: CharacterCell_character)] = []

    public let tableView = NSTableView()
    public let errorLabel = NSTextField(wrappingLabelWithString: "")

    public init(environment: Environment, page: Int = 1) {
        handle = environment.handle(for: CharactersQuery(page: page))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        observation?.cancel()
    }

    public override func loadView() {
        tableView.addTableColumn(NSTableColumn(identifier: CharacterCell.identifier))
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.dataSource = self
        tableView.delegate = self
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let stack = NSStackView(views: [errorLabel, scrollView])
        stack.orientation = .vertical
        view = stack
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        retention = handle.retain()
        render(Self.shown(handle.phase))
        observation = Task { [weak self, handle] in
            for await shown in Observations({ Self.shown(handle.phase) }) {
                self?.render(shown)
            }
        }
    }

    public static func shown(_ phase: Phase<CharactersQuery.Data>) -> Shown {
        switch phase {
        case .loading:
            return .loading
        case .failed(let error):
            return .failed(String(describing: error))
        case .ready(let data):
            guard let results = data.characters?.results else { return .ready([]) }
            return .ready(results.map { (id: $0.id ?? "", character: $0.characterCell) })
        }
    }

    private func render(_ shown: Shown) {
        switch shown {
        case .loading:
            rows = []
            errorLabel.isHidden = true
        case .failed(let message):
            rows = []
            errorLabel.stringValue = message
            errorLabel.isHidden = false
        case .ready(let ready):
            rows = ready
            errorLabel.isHidden = true
        }
        tableView.reloadData()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CharacterCell.identifier, owner: nil) as? CharacterCell ?? CharacterCell()
        cell.bind(rows[row].character)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(tableView.selectedRow) else { return }
        selected(rows[tableView.selectedRow].id)
    }
}

/// A row of the table. It takes a lens, not a model: the fragment's
/// generated struct, handed down by the controller as a parent view hands
/// it to a child. The fragment is declared here, beside what reads it.
@MainActor
public final class CharacterCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CharacterCell")

    @Fragment("""
        fragment CharacterCell_character on Character {
          name
          status
          species
        }
        """)
    private var character: CharacterCell_character?

    private var observation: Task<Void, Never>?
    public let nameLabel = NSTextField(labelWithString: "")
    public let detailsLabel = NSTextField(labelWithString: "")

    public init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        detailsLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [nameLabel, detailsLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        observation?.cancel()
    }

    public func bind(_ character: CharacterCell_character) {
        observation?.cancel()
        self.character = character
        render(Self.shown(character))
        observation = Task { [weak self] in
            for await shown in Observations({ Self.shown(character) }) {
                self?.render(shown)
            }
        }
    }

    /// A recycled cell stops watching the row it left before it is bound to
    /// the next one.
    public override func prepareForReuse() {
        super.prepareForReuse()
        observation?.cancel()
        observation = nil
        character = nil
    }

    static func shown(_ character: CharacterCell_character) -> (name: String, details: String) {
        (
            name: character.name ?? "Unknown",
            details: [character.status, character.species].compactMap { $0 }.joined(separator: " · ")
        )
    }

    private func render(_ shown: (name: String, details: String)) {
        nameLabel.stringValue = shown.name
        detailsLabel.stringValue = shown.details
    }
}
#endif

import Baton

// What the controllers show, read from the store and shared by the AppKit
// and the UIKit controllers, which only render it. Each value is computed
// inside an observed closure, so every field it reads is watched, and only
// those.

/// What a character's detail shows.
public enum CharacterContent: Sendable, Equatable {
    case loading
    case failed(String)
    case ready(name: String, details: String, origin: String)

    @MainActor
    public init(_ phase: Phase<CharacterQuery.Data>) {
        switch phase {
        case .loading:
            self = .loading
        case .failed(let error):
            self = .failed(String(describing: error))
        case .ready(let data):
            guard let character = data.character else {
                self = .failed("No such character")
                return
            }
            self = .ready(
                name: character.name ?? "Unknown",
                details: [character.status, character.species].compactMap { $0 }.joined(separator: " · "),
                origin: character.origin?.name ?? "Unknown"
            )
        }
    }
}

/// The rows of a page of characters: each character's id and the lens its
/// cell reads. It reads which rows there are, not the fields the cells show,
/// so a commit that renames a character leaves it as it was.
public enum CharactersContent: Sendable, Equatable {
    case loading
    case failed(String)
    case ready([Row])

    public struct Row: Sendable, Equatable {
        public let id: String
        public let character: CharacterCell_character
    }

    @MainActor
    public init(_ phase: Phase<CharactersQuery.Data>) {
        switch phase {
        case .loading:
            self = .loading
        case .failed(let error):
            self = .failed(String(describing: error))
        case .ready(let data):
            guard let results = data.characters?.results else {
                self = .ready([])
                return
            }
            self = .ready(results.map { Row(id: $0.id ?? "", character: $0.characterCell) })
        }
    }
}

/// What a character's cell shows of its row.
public struct CharacterCellContent: Sendable, Equatable {
    public let name: String
    public let details: String

    @MainActor
    public init(_ character: CharacterCell_character) {
        name = character.name ?? "Unknown"
        details = [character.status, character.species].compactMap { $0 }.joined(separator: " · ")
    }
}

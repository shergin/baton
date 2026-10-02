import Baton

// The memberwise initializer takes the lens type: the marker macro left the
// property stored.
let row = CharacterRow(character: CharacterRow_character())

// The memberwise initializer takes the operation value (the variables), and the
// body reads the resolved handle.
let screen = CharactersScreen(characters: CharactersScreenQuery(page: 1))
print("screen.characters.phase =", screen.characters.phase)
print("screen.characters.page =", screen.characters.page as Any)
print("persisted id =", CharactersScreenQuery.persistedID)
print("row =", row)

// Hashable by variables only; resolution does not take part.
let a = CharactersScreenQuery(page: 1)
let b = CharactersScreenQuery(page: 1)
print("equal by variables:", a == b, "hash equal:", a.hashValue == b.hashValue)

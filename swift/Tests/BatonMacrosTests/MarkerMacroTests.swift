import BatonMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

let markers: [String: MacroSpec] = [
    "Fragment": MacroSpec(type: FragmentMacro.self),
    "Query": MacroSpec(type: QueryMacro.self),
    "Mutation": MacroSpec(type: MutationMacro.self),
    "Subscription": MacroSpec(type: SubscriptionMacro.self),
]

/// Expands the markers in `source` and expects `expanded`, or the diagnostics.
func expectExpansion(_ source: String, _ expanded: String, diagnostics: [DiagnosticSpec] = [], sourceLocation: SourceLocation = #_sourceLocation) {
    assertMacroExpansion(source, expandedSource: expanded, diagnostics: diagnostics, macroSpecs: markers) { failure in
        Issue.record(Comment(rawValue: failure.message), sourceLocation: sourceLocation)
    }
}

@Suite("The marker macros", .timeLimit(.minutes(1)))
struct MarkerMacroTests {
    @Test("@Fragment leaves the property stored, so the memberwise initializer takes the lens")
    func fragment() {
        expectExpansion(
            """
            struct Row {
                @Fragment("fragment Row_character on Character { name }")
                var character: Row_character
            }
            """,
            """
            struct Row {
                var character: Row_character
            }
            """
        )
    }

    @Test("@Query turns the property into operation storage behind an init accessor, with the default policy")
    func query() {
        expectExpansion(
            """
            struct Screen {
                @Query("query Screen { a }")
                var screen: Screen
            }
            """,
            """
            struct Screen {
                var screen: Screen {
                    @storageRestrictions(initializes: _screen)
                    init(initialValue) {
                        _screen = Baton.OperationStorage(initialValue, fetchPolicy: .default)
                    }
                    get {
                        _screen.resolved
                    }
                }

                private var _screen: Baton.OperationStorage<Screen>
            }
            """
        )
    }

    @Test("@Query passes its fetch policy to the storage")
    func queryPolicy() {
        expectExpansion(
            """
            struct Screen {
                @Query("query Screen { a }", fetchPolicy: .storeOrNetwork)
                var screen: Screen
            }
            """,
            """
            struct Screen {
                var screen: Screen {
                    @storageRestrictions(initializes: _screen)
                    init(initialValue) {
                        _screen = Baton.OperationStorage(initialValue, fetchPolicy: .storeOrNetwork)
                    }
                    get {
                        _screen.resolved
                    }
                }

                private var _screen: Baton.OperationStorage<Screen>
            }
            """
        )
    }

    @Test("@Subscription turns the property into subscription storage behind an init accessor")
    func subscription() {
        expectExpansion(
            """
            struct Live {
                @Subscription("subscription Live { a }")
                var live: Live
            }
            """,
            """
            struct Live {
                var live: Live {
                    @storageRestrictions(initializes: _live)
                    init(initialValue) {
                        _live = Baton.SubscriptionStorage(initialValue)
                    }
                    get {
                        _live.resolved
                    }
                }

                private var _live: Baton.SubscriptionStorage<Live>
            }
            """
        )
    }

    @Test("@Mutation turns an Action property into an action over mutation storage the initializer does not mention")
    func mutation() {
        expectExpansion(
            """
            struct Star {
                @Mutation("mutation Star { a }")
                var star: Star.Action
            }
            """,
            """
            struct Star {
                var star: Star.Action {
                    get {
                        _star.action
                    }
                }

                var _star = Baton.MutationStorage<Star>()
            }
            """
        )
    }

    @Test("a marker on a property that is not typed as it expects, has a default, or binds several names is an error")
    func misuse() {
        expectExpansion(
            """
            struct Star {
                @Mutation("mutation Star { a }")
                var star: Star
            }
            """,
            """
            struct Star {
                var star: Star
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Mutation expects a property typed `<Operation>.Action`", line: 2, column: 5),
            ]
        )
        expectExpansion(
            """
            struct Row {
                @Fragment("fragment Row_character on Character { name }")
                var character: Row_character = Row_character()
            }
            """,
            """
            struct Row {
                var character: Row_character = Row_character()
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "a Fragment property takes its value from the initializer, not a default", line: 2, column: 5),
            ]
        )
        expectExpansion(
            """
            struct Row {
                @Fragment("fragment Row_character on Character { name }")
                var first: Row_character, second: Row_character
            }
            """,
            """
            struct Row {
                var first: Row_character, second: Row_character
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "peer macro can only be applied to a single variable", line: 2, column: 5),
            ]
        )
    }
}

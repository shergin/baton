import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct MacroError: Error, CustomStringConvertible {
    let description: String
}

/// A pure marker: validates the attachment site and expands to nothing, so the
/// property stays stored and the memberwise initializer takes its type.
public struct FragmentMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try requireTypedProperty(declaration, attribute: node)
        return []
    }
}

/// Turns `var name: Op` into a computed property over `_name: OperationStorage<Op>`
/// with an init accessor, so `init(name: Op)` still exists and `name` reads the
/// resolved value.
public struct QueryMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let (name, _) = try requireTypedProperty(declaration, attribute: node)
        let policy = labeledArgument("fetchPolicy", of: node) ?? ".default"
        return [
            """
            @storageRestrictions(initializes: _\(raw: name))
            init(initialValue) {
                _\(raw: name) = Baton.OperationStorage(initialValue, fetchPolicy: \(raw: policy))
            }
            """,
            """
            get {
                _\(raw: name).resolved
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let (name, type) = try requireTypedProperty(declaration, attribute: node)
        return ["private var _\(raw: name): Baton.OperationStorage<\(type.trimmed)>"]
    }
}

/// Turns `var live: NoteAddedSubscription` into a computed property over
/// `_live: SubscriptionStorage<Op>` with an init accessor, so `init(live:)`
/// still exists and `live` reads the resolved value.
public struct SubscriptionMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let (name, _) = try requireTypedProperty(declaration, attribute: node)
        return [
            """
            @storageRestrictions(initializes: _\(raw: name))
            init(initialValue) {
                _\(raw: name) = Baton.SubscriptionStorage(initialValue)
            }
            """,
            """
            get {
                _\(raw: name).resolved
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let (name, type) = try requireTypedProperty(declaration, attribute: node)
        return ["private var _\(raw: name): Baton.SubscriptionStorage<\(type.trimmed)>"]
    }
}

/// Turns `var star: StarMutation.Action` into a computed property over
/// `_star: MutationStorage<StarMutation>`, so the view gets an action and the
/// memberwise initializer does not mention it.
public struct MutationMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let (name, type) = try requireTypedProperty(declaration, attribute: node)
        // The peer reports a property of another type; a getter over storage
        // that is never declared would only add an error that hides it.
        guard actionBase(type) != nil else { return [] }
        return [
            """
            get {
                _\(raw: name).action
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let (name, type) = try requireTypedProperty(declaration, attribute: node)
        guard let operation = actionBase(type) else {
            throw MacroError(description: "@Mutation expects a property typed `<Operation>.Action`")
        }
        // Not `private`: a private stored property would make the view's memberwise initializer private.
        return ["var _\(raw: name) = Baton.MutationStorage<\(operation.trimmed)>()"]
    }

    /// The operation of a type spelled `<Operation>.Action`.
    private static func actionBase(_ type: TypeSyntax) -> TypeSyntax? {
        guard let member = type.as(MemberTypeSyntax.self), member.name.text == "Action" else { return nil }
        return member.baseType
    }
}

/// The source text of a labeled attribute argument, if present.
private func labeledArgument(_ label: String, of attribute: AttributeSyntax) -> String? {
    guard case .argumentList(let arguments) = attribute.arguments else { return nil }
    return arguments.first { $0.label?.text == label }?.expression.trimmedDescription
}

@discardableResult
private func requireTypedProperty(_ declaration: some DeclSyntaxProtocol, attribute: AttributeSyntax) throws -> (String, TypeSyntax) {
    guard let variable = declaration.as(VariableDeclSyntax.self),
          variable.bindings.count == 1,
          let binding = variable.bindings.first,
          let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
          let type = binding.typeAnnotation?.type
    else {
        throw MacroError(description: "\(attribute.attributeName.trimmedDescription) must be attached to a single property with an explicit type")
    }
    guard binding.initializer == nil else {
        throw MacroError(description: "a \(attribute.attributeName.trimmedDescription) property takes its value from the initializer, not a default")
    }
    return (pattern.identifier.text, type)
}

@main
struct BatonMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [FragmentMacro.self, QueryMacro.self, MutationMacro.self, SubscriptionMacro.self]
}

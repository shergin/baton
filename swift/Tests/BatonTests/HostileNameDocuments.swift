import Baton

/// Documents that use names Swift and the generated code keep for
/// themselves, in every position a document's name can take: Swift's
/// keywords and contextual keywords, what every lens and each kind of lens
/// declares, the locals and local aliases of generated bodies, what an
/// operation value and a mutation's action declare, what the runtime's
/// protocols give a generated type, the shared enums, and the modules and
/// standard library types the generated code spells. Each name stands as an
/// aliased scalar field, an aliased linked field, an aliased selection and an
/// aliased spread of a plain lens; as a field beside every kind of generated
/// body, beside a connection's members, beside the checks of a required field
/// that bubbles to the root, and on an interface; as a variable of a query,
/// a mutation and a subscription and as a fragment's argument; and as a scalar
/// and a linked field of a mutation's payload. A name the compiler refuses in
/// a position, or that it accepts and writes Swift for that does not compile,
/// is left out of that position; `compiler/src/tests/hostile_name_tests.rs`
/// lists both, and proves every other name is here.
@MainActor
struct HostileNameDocuments {
    /// Each name as an aliased scalar field of a plain lens.
    @Fragment("""
        fragment HostileScalars_character on Character {
          # Swift's keywords, as `escape` lists them.
          Type: name Protocol: name Any: name self: name Self: name init: name deinit: name
          subscript: name class: name struct: name enum: name func: name var: name let: name
          import: name extension: name operator: name static: name default: name case: name switch: name
          if: name else: name for: name in: name while: name repeat: name return: name break: name
          continue: name where: name is: name as: name try: name throw: name throws: name guard: name
          defer: name do: name catch: name true: name false: name nil: name super: name internal: name
          private: name public: name fileprivate: name open: name inout: name typealias: name
          associatedtype: name protocol: name some: name any: name
          rethrows: name fallthrough: name precedencegroup: name _: name
          # Swift's contextual keywords that start an expression or a type.
          async: name await: name borrowing: name consume: name consuming: name copy: name discard: name
          each: name isolated: name sending: name then: name unsafe: name
          # What every lens declares, and what a refetchable fragment and a connection add.
          typeName: name satisfied: name missingRequiredField: name fieldErrors: name isPresent: name
          throwing: name caught: name refetchable: name refetch: name connection: name nodes: name
          hasNext: name hasPrevious: name isLoadingNext: name isLoadingPrevious: name connectionID: name
          loadNext: name loadPrevious: name
          # The locals, parameters and local aliases of generated bodies.
          bound: name errors: name child: name missing: name count: name fields: name lhs: name
          rhs: name hasher: name optimistic: name selfValue: name Fragment: name Spread: name
          Owner: name Query: name Operation: name RefetchQuery: name
          # What an operation value, a mutation's action and its optimistic response declare.
          variables: name resolution: name name: name persistedID: name text: name plan: name
          errorBehavior: name throwsOnFieldError: name bubbles: name hasDeferred: name Data: name
          Action: name OptimisticResponse: name hash: name commit: name callAsFunction: name Op: name
          variable: name
          # What the runtime's protocols give a generated type.
          hashValue: name phase: name isRefreshing: name isStale: name retry: name subscription: name
          # The shared enums.
          Types: name Sites: name AbstractSlots: name schemaDigest: name
          # The modules, and what the generated code spells from the standard library.
          Baton: name Swift: name Set: name Result: name Optional: name String: name Int: name
          Double: name Bool: name MainActor: name Hasher: name Sendable: name
        }
        """)
    var scalars: HostileScalars_character

    /// Each name as an aliased linked field, whose nested lens takes the name
    /// capitalized.
    @Fragment("""
        fragment HostileLinks_character on Character {
          # Swift's keywords, as `escape` lists them.
          Type: origin { id } Protocol: origin { id } Any: origin { id } self: origin { id }
          Self: origin { id } init: origin { id } deinit: origin { id } subscript: origin { id }
          class: origin { id } struct: origin { id } enum: origin { id } func: origin { id }
          var: origin { id } let: origin { id } import: origin { id } extension: origin { id }
          operator: origin { id } static: origin { id } default: origin { id } case: origin { id }
          switch: origin { id } if: origin { id } else: origin { id } for: origin { id }
          in: origin { id } while: origin { id } repeat: origin { id } return: origin { id }
          break: origin { id } continue: origin { id } where: origin { id } is: origin { id }
          as: origin { id } try: origin { id } throw: origin { id } throws: origin { id }
          guard: origin { id } defer: origin { id } do: origin { id } catch: origin { id }
          true: origin { id } false: origin { id } nil: origin { id } super: origin { id }
          internal: origin { id } private: origin { id } public: origin { id }
          fileprivate: origin { id } open: origin { id } inout: origin { id } typealias: origin { id }
          associatedtype: origin { id } protocol: origin { id } some: origin { id } any: origin { id }
          rethrows: origin { id } fallthrough: origin { id } precedencegroup: origin { id }
          _: origin { id }
          # Swift's contextual keywords that start an expression or a type.
          async: origin { id } await: origin { id } borrowing: origin { id } consume: origin { id }
          consuming: origin { id } copy: origin { id } discard: origin { id } each: origin { id }
          isolated: origin { id } sending: origin { id } then: origin { id } unsafe: origin { id }
          # What every lens declares, and what a refetchable fragment and a connection add.
          typeName: origin { id } satisfied: origin { id } missingRequiredField: origin { id }
          fieldErrors: origin { id } isPresent: origin { id } throwing: origin { id }
          caught: origin { id } refetchable: origin { id } refetch: origin { id }
          connection: origin { id } nodes: origin { id } hasNext: origin { id }
          hasPrevious: origin { id } isLoadingNext: origin { id } isLoadingPrevious: origin { id }
          connectionID: origin { id } loadNext: origin { id } loadPrevious: origin { id }
          # The locals, parameters and local aliases of generated bodies.
          bound: origin { id } errors: origin { id } child: origin { id } missing: origin { id }
          count: origin { id } fields: origin { id } lhs: origin { id } rhs: origin { id }
          hasher: origin { id } optimistic: origin { id } selfValue: origin { id }
          Fragment: origin { id } Spread: origin { id } Owner: origin { id } Query: origin { id }
          Operation: origin { id } RefetchQuery: origin { id }
          # What an operation value, a mutation's action and its optimistic response declare.
          variables: origin { id } resolution: origin { id } name: origin { id }
          persistedID: origin { id } text: origin { id } plan: origin { id }
          errorBehavior: origin { id } throwsOnFieldError: origin { id } bubbles: origin { id }
          hasDeferred: origin { id } Data: origin { id } Action: origin { id }
          OptimisticResponse: origin { id } hash: origin { id } commit: origin { id }
          callAsFunction: origin { id } Op: origin { id } variable: origin { id }
          # What the runtime's protocols give a generated type.
          hashValue: origin { id } phase: origin { id } isRefreshing: origin { id }
          isStale: origin { id } retry: origin { id } subscription: origin { id }
          # The shared enums.
          Types: origin { id } Sites: origin { id } AbstractSlots: origin { id }
          schemaDigest: origin { id }
          # The modules, and what the generated code spells from the standard library.
          Baton: origin { id } Swift: origin { id } Set: origin { id } Result: origin { id }
          Optional: origin { id } String: origin { id } Int: origin { id } Double: origin { id }
          Bool: origin { id } MainActor: origin { id } Hasher: origin { id } Sendable: origin { id }
        }
        """)
    var links: HostileLinks_character

    /// Each name as an aliased selection, an accessor and a nested lens of the
    /// name.
    @Fragment("""
        fragment HostileSelections_character on Character {
          # Swift's keywords, as `escape` lists them.
          ... @alias(as: "Type") { name } ... @alias(as: "Protocol") { name }
          ... @alias(as: "Any") { name } ... @alias(as: "self") { name } ... @alias(as: "Self") { name }
          ... @alias(as: "init") { name } ... @alias(as: "deinit") { name }
          ... @alias(as: "subscript") { name } ... @alias(as: "class") { name }
          ... @alias(as: "struct") { name } ... @alias(as: "enum") { name }
          ... @alias(as: "func") { name } ... @alias(as: "var") { name } ... @alias(as: "let") { name }
          ... @alias(as: "import") { name } ... @alias(as: "extension") { name }
          ... @alias(as: "operator") { name } ... @alias(as: "static") { name }
          ... @alias(as: "default") { name } ... @alias(as: "case") { name }
          ... @alias(as: "switch") { name } ... @alias(as: "if") { name }
          ... @alias(as: "else") { name } ... @alias(as: "for") { name } ... @alias(as: "in") { name }
          ... @alias(as: "while") { name } ... @alias(as: "repeat") { name }
          ... @alias(as: "return") { name } ... @alias(as: "break") { name }
          ... @alias(as: "continue") { name } ... @alias(as: "where") { name }
          ... @alias(as: "is") { name } ... @alias(as: "as") { name } ... @alias(as: "try") { name }
          ... @alias(as: "throw") { name } ... @alias(as: "throws") { name }
          ... @alias(as: "guard") { name } ... @alias(as: "defer") { name }
          ... @alias(as: "do") { name } ... @alias(as: "catch") { name } ... @alias(as: "true") { name }
          ... @alias(as: "false") { name } ... @alias(as: "nil") { name }
          ... @alias(as: "super") { name } ... @alias(as: "internal") { name }
          ... @alias(as: "private") { name } ... @alias(as: "public") { name }
          ... @alias(as: "fileprivate") { name } ... @alias(as: "open") { name }
          ... @alias(as: "inout") { name } ... @alias(as: "typealias") { name }
          ... @alias(as: "associatedtype") { name } ... @alias(as: "protocol") { name }
          ... @alias(as: "some") { name } ... @alias(as: "any") { name }
          ... @alias(as: "rethrows") { name } ... @alias(as: "fallthrough") { name }
          ... @alias(as: "precedencegroup") { name } ... @alias(as: "_") { name }
          # Swift's contextual keywords that start an expression or a type.
          ... @alias(as: "async") { name } ... @alias(as: "await") { name }
          ... @alias(as: "borrowing") { name } ... @alias(as: "consume") { name }
          ... @alias(as: "consuming") { name } ... @alias(as: "copy") { name }
          ... @alias(as: "discard") { name } ... @alias(as: "each") { name }
          ... @alias(as: "isolated") { name } ... @alias(as: "sending") { name }
          ... @alias(as: "then") { name } ... @alias(as: "unsafe") { name }
          # What every lens declares, and what a refetchable fragment and a connection add.
          ... @alias(as: "typeName") { name } ... @alias(as: "satisfied") { name }
          ... @alias(as: "missingRequiredField") { name } ... @alias(as: "fieldErrors") { name }
          ... @alias(as: "isPresent") { name } ... @alias(as: "throwing") { name }
          ... @alias(as: "caught") { name } ... @alias(as: "refetchable") { name }
          ... @alias(as: "refetch") { name } ... @alias(as: "connection") { name }
          ... @alias(as: "nodes") { name } ... @alias(as: "hasNext") { name }
          ... @alias(as: "hasPrevious") { name } ... @alias(as: "isLoadingNext") { name }
          ... @alias(as: "isLoadingPrevious") { name } ... @alias(as: "connectionID") { name }
          ... @alias(as: "loadNext") { name } ... @alias(as: "loadPrevious") { name }
          # The locals, parameters and local aliases of generated bodies.
          ... @alias(as: "bound") { name } ... @alias(as: "errors") { name }
          ... @alias(as: "child") { name } ... @alias(as: "missing") { name }
          ... @alias(as: "count") { name } ... @alias(as: "fields") { name }
          ... @alias(as: "lhs") { name } ... @alias(as: "rhs") { name }
          ... @alias(as: "hasher") { name } ... @alias(as: "optimistic") { name }
          ... @alias(as: "selfValue") { name } ... @alias(as: "Fragment") { name }
          ... @alias(as: "Spread") { name } ... @alias(as: "Owner") { name }
          ... @alias(as: "Query") { name } ... @alias(as: "Operation") { name }
          ... @alias(as: "RefetchQuery") { name }
          # What an operation value, a mutation's action and its optimistic response declare.
          ... @alias(as: "variables") { name } ... @alias(as: "resolution") { name }
          ... @alias(as: "name") { name } ... @alias(as: "persistedID") { name }
          ... @alias(as: "text") { name } ... @alias(as: "plan") { name }
          ... @alias(as: "errorBehavior") { name } ... @alias(as: "throwsOnFieldError") { name }
          ... @alias(as: "bubbles") { name } ... @alias(as: "hasDeferred") { name }
          ... @alias(as: "Data") { name } ... @alias(as: "Action") { name }
          ... @alias(as: "OptimisticResponse") { name } ... @alias(as: "hash") { name }
          ... @alias(as: "commit") { name } ... @alias(as: "callAsFunction") { name }
          ... @alias(as: "Op") { name } ... @alias(as: "variable") { name }
          # What the runtime's protocols give a generated type.
          ... @alias(as: "hashValue") { name } ... @alias(as: "phase") { name }
          ... @alias(as: "isRefreshing") { name } ... @alias(as: "isStale") { name }
          ... @alias(as: "retry") { name } ... @alias(as: "subscription") { name }
          # The shared enums.
          ... @alias(as: "Types") { name } ... @alias(as: "Sites") { name }
          ... @alias(as: "AbstractSlots") { name } ... @alias(as: "schemaDigest") { name }
          # The modules, and what the generated code spells from the standard library.
          ... @alias(as: "Baton") { name } ... @alias(as: "Swift") { name }
          ... @alias(as: "Set") { name } ... @alias(as: "Result") { name }
          ... @alias(as: "Optional") { name } ... @alias(as: "String") { name }
          ... @alias(as: "Int") { name } ... @alias(as: "Double") { name }
          ... @alias(as: "Bool") { name } ... @alias(as: "MainActor") { name }
          ... @alias(as: "Hasher") { name } ... @alias(as: "Sendable") { name }
        }
        """)
    var selections: HostileSelections_character

    /// The fragment the aliased spreads spread.
    @Fragment("""
        fragment HostileSpreadTarget_character on Character {
          name
        }
        """)
    var spreadTarget: HostileSpreadTarget_character

    /// Each name as an aliased spread, an accessor of the name that builds a
    /// fragment's lens.
    @Fragment("""
        fragment HostileSpreads_character on Character {
          # Swift's keywords, as `escape` lists them.
          ... @alias(as: "Type") { ...HostileSpreadTarget_character }
          ... @alias(as: "Protocol") { ...HostileSpreadTarget_character }
          ... @alias(as: "Any") { ...HostileSpreadTarget_character }
          ... @alias(as: "self") { ...HostileSpreadTarget_character }
          ... @alias(as: "Self") { ...HostileSpreadTarget_character }
          ... @alias(as: "init") { ...HostileSpreadTarget_character }
          ... @alias(as: "deinit") { ...HostileSpreadTarget_character }
          ... @alias(as: "subscript") { ...HostileSpreadTarget_character }
          ... @alias(as: "class") { ...HostileSpreadTarget_character }
          ... @alias(as: "struct") { ...HostileSpreadTarget_character }
          ... @alias(as: "enum") { ...HostileSpreadTarget_character }
          ... @alias(as: "func") { ...HostileSpreadTarget_character }
          ... @alias(as: "var") { ...HostileSpreadTarget_character }
          ... @alias(as: "let") { ...HostileSpreadTarget_character }
          ... @alias(as: "import") { ...HostileSpreadTarget_character }
          ... @alias(as: "extension") { ...HostileSpreadTarget_character }
          ... @alias(as: "operator") { ...HostileSpreadTarget_character }
          ... @alias(as: "static") { ...HostileSpreadTarget_character }
          ... @alias(as: "default") { ...HostileSpreadTarget_character }
          ... @alias(as: "case") { ...HostileSpreadTarget_character }
          ... @alias(as: "switch") { ...HostileSpreadTarget_character }
          ... @alias(as: "if") { ...HostileSpreadTarget_character }
          ... @alias(as: "else") { ...HostileSpreadTarget_character }
          ... @alias(as: "for") { ...HostileSpreadTarget_character }
          ... @alias(as: "in") { ...HostileSpreadTarget_character }
          ... @alias(as: "while") { ...HostileSpreadTarget_character }
          ... @alias(as: "repeat") { ...HostileSpreadTarget_character }
          ... @alias(as: "return") { ...HostileSpreadTarget_character }
          ... @alias(as: "break") { ...HostileSpreadTarget_character }
          ... @alias(as: "continue") { ...HostileSpreadTarget_character }
          ... @alias(as: "where") { ...HostileSpreadTarget_character }
          ... @alias(as: "is") { ...HostileSpreadTarget_character }
          ... @alias(as: "as") { ...HostileSpreadTarget_character }
          ... @alias(as: "try") { ...HostileSpreadTarget_character }
          ... @alias(as: "throw") { ...HostileSpreadTarget_character }
          ... @alias(as: "throws") { ...HostileSpreadTarget_character }
          ... @alias(as: "guard") { ...HostileSpreadTarget_character }
          ... @alias(as: "defer") { ...HostileSpreadTarget_character }
          ... @alias(as: "do") { ...HostileSpreadTarget_character }
          ... @alias(as: "catch") { ...HostileSpreadTarget_character }
          ... @alias(as: "true") { ...HostileSpreadTarget_character }
          ... @alias(as: "false") { ...HostileSpreadTarget_character }
          ... @alias(as: "nil") { ...HostileSpreadTarget_character }
          ... @alias(as: "super") { ...HostileSpreadTarget_character }
          ... @alias(as: "internal") { ...HostileSpreadTarget_character }
          ... @alias(as: "private") { ...HostileSpreadTarget_character }
          ... @alias(as: "public") { ...HostileSpreadTarget_character }
          ... @alias(as: "fileprivate") { ...HostileSpreadTarget_character }
          ... @alias(as: "open") { ...HostileSpreadTarget_character }
          ... @alias(as: "inout") { ...HostileSpreadTarget_character }
          ... @alias(as: "typealias") { ...HostileSpreadTarget_character }
          ... @alias(as: "associatedtype") { ...HostileSpreadTarget_character }
          ... @alias(as: "protocol") { ...HostileSpreadTarget_character }
          ... @alias(as: "some") { ...HostileSpreadTarget_character }
          ... @alias(as: "any") { ...HostileSpreadTarget_character }
          ... @alias(as: "rethrows") { ...HostileSpreadTarget_character }
          ... @alias(as: "fallthrough") { ...HostileSpreadTarget_character }
          ... @alias(as: "precedencegroup") { ...HostileSpreadTarget_character }
          ... @alias(as: "_") { ...HostileSpreadTarget_character }
          # Swift's contextual keywords that start an expression or a type.
          ... @alias(as: "async") { ...HostileSpreadTarget_character }
          ... @alias(as: "await") { ...HostileSpreadTarget_character }
          ... @alias(as: "borrowing") { ...HostileSpreadTarget_character }
          ... @alias(as: "consume") { ...HostileSpreadTarget_character }
          ... @alias(as: "consuming") { ...HostileSpreadTarget_character }
          ... @alias(as: "copy") { ...HostileSpreadTarget_character }
          ... @alias(as: "discard") { ...HostileSpreadTarget_character }
          ... @alias(as: "each") { ...HostileSpreadTarget_character }
          ... @alias(as: "isolated") { ...HostileSpreadTarget_character }
          ... @alias(as: "sending") { ...HostileSpreadTarget_character }
          ... @alias(as: "then") { ...HostileSpreadTarget_character }
          ... @alias(as: "unsafe") { ...HostileSpreadTarget_character }
          # What every lens declares, and what a refetchable fragment and a connection add.
          ... @alias(as: "typeName") { ...HostileSpreadTarget_character }
          ... @alias(as: "satisfied") { ...HostileSpreadTarget_character }
          ... @alias(as: "missingRequiredField") { ...HostileSpreadTarget_character }
          ... @alias(as: "fieldErrors") { ...HostileSpreadTarget_character }
          ... @alias(as: "isPresent") { ...HostileSpreadTarget_character }
          ... @alias(as: "throwing") { ...HostileSpreadTarget_character }
          ... @alias(as: "caught") { ...HostileSpreadTarget_character }
          ... @alias(as: "refetchable") { ...HostileSpreadTarget_character }
          ... @alias(as: "refetch") { ...HostileSpreadTarget_character }
          ... @alias(as: "connection") { ...HostileSpreadTarget_character }
          ... @alias(as: "nodes") { ...HostileSpreadTarget_character }
          ... @alias(as: "hasNext") { ...HostileSpreadTarget_character }
          ... @alias(as: "hasPrevious") { ...HostileSpreadTarget_character }
          ... @alias(as: "isLoadingNext") { ...HostileSpreadTarget_character }
          ... @alias(as: "isLoadingPrevious") { ...HostileSpreadTarget_character }
          ... @alias(as: "connectionID") { ...HostileSpreadTarget_character }
          ... @alias(as: "loadNext") { ...HostileSpreadTarget_character }
          ... @alias(as: "loadPrevious") { ...HostileSpreadTarget_character }
          # The locals, parameters and local aliases of generated bodies.
          ... @alias(as: "bound") { ...HostileSpreadTarget_character }
          ... @alias(as: "errors") { ...HostileSpreadTarget_character }
          ... @alias(as: "child") { ...HostileSpreadTarget_character }
          ... @alias(as: "missing") { ...HostileSpreadTarget_character }
          ... @alias(as: "count") { ...HostileSpreadTarget_character }
          ... @alias(as: "fields") { ...HostileSpreadTarget_character }
          ... @alias(as: "lhs") { ...HostileSpreadTarget_character }
          ... @alias(as: "rhs") { ...HostileSpreadTarget_character }
          ... @alias(as: "hasher") { ...HostileSpreadTarget_character }
          ... @alias(as: "optimistic") { ...HostileSpreadTarget_character }
          ... @alias(as: "selfValue") { ...HostileSpreadTarget_character }
          ... @alias(as: "Fragment") { ...HostileSpreadTarget_character }
          ... @alias(as: "Spread") { ...HostileSpreadTarget_character }
          ... @alias(as: "Owner") { ...HostileSpreadTarget_character }
          ... @alias(as: "Query") { ...HostileSpreadTarget_character }
          ... @alias(as: "Operation") { ...HostileSpreadTarget_character }
          ... @alias(as: "RefetchQuery") { ...HostileSpreadTarget_character }
          # What an operation value, a mutation's action and its optimistic response declare.
          ... @alias(as: "variables") { ...HostileSpreadTarget_character }
          ... @alias(as: "resolution") { ...HostileSpreadTarget_character }
          ... @alias(as: "name") { ...HostileSpreadTarget_character }
          ... @alias(as: "persistedID") { ...HostileSpreadTarget_character }
          ... @alias(as: "text") { ...HostileSpreadTarget_character }
          ... @alias(as: "plan") { ...HostileSpreadTarget_character }
          ... @alias(as: "errorBehavior") { ...HostileSpreadTarget_character }
          ... @alias(as: "throwsOnFieldError") { ...HostileSpreadTarget_character }
          ... @alias(as: "bubbles") { ...HostileSpreadTarget_character }
          ... @alias(as: "hasDeferred") { ...HostileSpreadTarget_character }
          ... @alias(as: "Data") { ...HostileSpreadTarget_character }
          ... @alias(as: "Action") { ...HostileSpreadTarget_character }
          ... @alias(as: "OptimisticResponse") { ...HostileSpreadTarget_character }
          ... @alias(as: "hash") { ...HostileSpreadTarget_character }
          ... @alias(as: "commit") { ...HostileSpreadTarget_character }
          ... @alias(as: "callAsFunction") { ...HostileSpreadTarget_character }
          ... @alias(as: "Op") { ...HostileSpreadTarget_character }
          ... @alias(as: "variable") { ...HostileSpreadTarget_character }
          # What the runtime's protocols give a generated type.
          ... @alias(as: "hashValue") { ...HostileSpreadTarget_character }
          ... @alias(as: "phase") { ...HostileSpreadTarget_character }
          ... @alias(as: "isRefreshing") { ...HostileSpreadTarget_character }
          ... @alias(as: "isStale") { ...HostileSpreadTarget_character }
          ... @alias(as: "retry") { ...HostileSpreadTarget_character }
          ... @alias(as: "subscription") { ...HostileSpreadTarget_character }
          # The shared enums.
          ... @alias(as: "Types") { ...HostileSpreadTarget_character }
          ... @alias(as: "Slots") { ...HostileSpreadTarget_character }
          ... @alias(as: "Sites") { ...HostileSpreadTarget_character }
          ... @alias(as: "AbstractSlots") { ...HostileSpreadTarget_character }
          ... @alias(as: "schemaDigest") { ...HostileSpreadTarget_character }
          # The modules, and what the generated code spells from the standard library.
          ... @alias(as: "Baton") { ...HostileSpreadTarget_character }
          ... @alias(as: "Swift") { ...HostileSpreadTarget_character }
          ... @alias(as: "Set") { ...HostileSpreadTarget_character }
          ... @alias(as: "Result") { ...HostileSpreadTarget_character }
          ... @alias(as: "Optional") { ...HostileSpreadTarget_character }
          ... @alias(as: "String") { ...HostileSpreadTarget_character }
          ... @alias(as: "Int") { ...HostileSpreadTarget_character }
          ... @alias(as: "Double") { ...HostileSpreadTarget_character }
          ... @alias(as: "Bool") { ...HostileSpreadTarget_character }
          ... @alias(as: "MainActor") { ...HostileSpreadTarget_character }
          ... @alias(as: "Hasher") { ...HostileSpreadTarget_character }
          ... @alias(as: "Sendable") { ...HostileSpreadTarget_character }
        }
        """)
    var spreads: HostileSpreads_character

    /// The fragments the lens with every kind of body spreads.
    @Fragment("""
        fragment HostileBound_character on Character
        @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) {
          name @include(if: $flag)
          origin @required(action: NONE) { id }
        }
        """)
    var bound: HostileBound_character

    @Fragment("""
        fragment HostileDeferred_character on Character {
          name
        }
        """)
    var deferred: HostileDeferred_character

    @Fragment("""
        fragment HostileCaught_character on Character {
          name
        }
        """)
    var caught: HostileCaught_character

    /// Each name as a field of a lens with every kind of generated body: the
    /// checks of `@throwOnFieldError` and `@required`, a throwing accessor,
    /// `refetch()`, and spreads that bind arguments, wait for a deferred part
    /// and catch field errors, each through a local alias.
    @Fragment("""
        fragment HostileBodies_character on Character
        @refetchable(queryName: "HostileBodiesRefetchQuery")
        @throwOnFieldError {
          # Swift's keywords, as `escape` lists them.
          Type: name Protocol: name Any: name self: name init: name deinit: name subscript: name
          class: name struct: name enum: name func: name var: name let: name import: name
          extension: name operator: name static: name default: name case: name switch: name if: name
          else: name for: name in: name while: name repeat: name return: name break: name continue: name
          where: name is: name as: name try: name throw: name throws: name guard: name defer: name
          do: name catch: name true: name false: name nil: name super: name internal: name private: name
          public: name fileprivate: name open: name inout: name typealias: name associatedtype: name
          protocol: name some: name any: name
          rethrows: name fallthrough: name precedencegroup: name _: name
          # Swift's contextual keywords that start an expression or a type.
          async: name await: name borrowing: name consume: name consuming: name copy: name discard: name
          each: name isolated: name sending: name then: name unsafe: name
          # What every lens declares, and what a refetchable fragment and a connection add.
          typeName: name satisfied: name missingRequiredField: name fieldErrors: name isPresent: name
          throwing: name caught: name refetchable: name refetch: name connection: name nodes: name
          hasNext: name hasPrevious: name isLoadingNext: name isLoadingPrevious: name connectionID: name
          loadNext: name loadPrevious: name
          # The locals, parameters and local aliases of generated bodies.
          bound: name errors: name child: name missing: name count: name fields: name lhs: name
          rhs: name hasher: name optimistic: name selfValue: name Fragment: name Spread: name
          Owner: name Query: name Operation: name RefetchQuery: name
          # What an operation value, a mutation's action and its optimistic response declare.
          variables: name resolution: name name: name persistedID: name text: name plan: name
          errorBehavior: name throwsOnFieldError: name bubbles: name hasDeferred: name Data: name
          Action: name OptimisticResponse: name hash: name commit: name callAsFunction: name Op: name
          variable: name
          # What the runtime's protocols give a generated type.
          hashValue: name phase: name isRefreshing: name isStale: name retry: name subscription: name
          # The shared enums.
          AbstractSlots: name schemaDigest: name
          # The modules, and what the generated code spells from the standard library.
          Baton: name Swift: name Set: name Result: name Optional: name String: name Int: name
          Double: name Bool: name MainActor: name Hasher: name Sendable: name
          # What gives the lens its bodies.
          species @required(action: THROW)
          origin @required(action: NONE) { name @required(action: NONE) }
          ...HostileBound_character @arguments(flag: false)
          ...HostileDeferred_character @defer
          ... @alias(as: "caughtSpread") @catch { ...HostileCaught_character }
        }
        """)
    var bodies: HostileBodies_character

    /// Each name as a field of a connection's lens, beside its state, `nodes`,
    /// and the pagination that names the refetch query and the fragment through
    /// local aliases.
    @Fragment("""
        fragment HostileConnection_character on Character
        @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"})
        @refetchable(queryName: "HostileConnectionRefetchQuery") {
          notes(first: $count, after: $cursor) @connection(key: "HostileConnection_notes") {
            # Swift's keywords, as `escape` lists them.
            Type: totalCount Protocol: totalCount Any: totalCount self: totalCount init: totalCount
            deinit: totalCount subscript: totalCount class: totalCount struct: totalCount
            enum: totalCount func: totalCount var: totalCount let: totalCount import: totalCount
            extension: totalCount operator: totalCount static: totalCount default: totalCount
            case: totalCount switch: totalCount if: totalCount else: totalCount for: totalCount
            in: totalCount while: totalCount repeat: totalCount return: totalCount break: totalCount
            continue: totalCount where: totalCount is: totalCount as: totalCount try: totalCount
            throw: totalCount throws: totalCount guard: totalCount defer: totalCount do: totalCount
            catch: totalCount true: totalCount false: totalCount nil: totalCount super: totalCount
            internal: totalCount private: totalCount public: totalCount fileprivate: totalCount
            open: totalCount inout: totalCount typealias: totalCount associatedtype: totalCount
            protocol: totalCount some: totalCount any: totalCount
            rethrows: totalCount fallthrough: totalCount precedencegroup: totalCount _: totalCount
            # Swift's contextual keywords that start an expression or a type.
            async: totalCount await: totalCount borrowing: totalCount consume: totalCount
            consuming: totalCount copy: totalCount discard: totalCount each: totalCount
            isolated: totalCount sending: totalCount then: totalCount unsafe: totalCount
            # What every lens declares, and what a refetchable fragment and a connection add.
            typeName: totalCount satisfied: totalCount missingRequiredField: totalCount
            fieldErrors: totalCount isPresent: totalCount throwing: totalCount caught: totalCount
            refetchable: totalCount refetch: totalCount connection: totalCount loadNext: totalCount
            loadPrevious: totalCount
            # The locals, parameters and local aliases of generated bodies.
            bound: totalCount errors: totalCount child: totalCount missing: totalCount count: totalCount
            fields: totalCount lhs: totalCount rhs: totalCount hasher: totalCount optimistic: totalCount
            selfValue: totalCount Fragment: totalCount Spread: totalCount Owner: totalCount
            Query: totalCount Operation: totalCount RefetchQuery: totalCount
            # What an operation value, a mutation's action and its optimistic response declare.
            variables: totalCount resolution: totalCount name: totalCount persistedID: totalCount
            text: totalCount plan: totalCount errorBehavior: totalCount throwsOnFieldError: totalCount
            bubbles: totalCount hasDeferred: totalCount Data: totalCount Action: totalCount
            OptimisticResponse: totalCount hash: totalCount commit: totalCount
            callAsFunction: totalCount Op: totalCount variable: totalCount
            # What the runtime's protocols give a generated type.
            hashValue: totalCount phase: totalCount isRefreshing: totalCount isStale: totalCount
            retry: totalCount subscription: totalCount
            # The shared enums.
            Sites: totalCount AbstractSlots: totalCount schemaDigest: totalCount
            # The modules, and what the generated code spells from the standard library.
            Baton: totalCount Swift: totalCount Set: totalCount Result: totalCount Optional: totalCount
            String: totalCount Int: totalCount Double: totalCount Bool: totalCount MainActor: totalCount
            Hasher: totalCount Sendable: totalCount
            edges { node { id } }
          }
        }
        """)
    var connection: HostileConnection_character

    /// A connection whose field named `nodes` takes the place of the generated
    /// one.
    @Fragment("""
        fragment HostileConnectionNodes_character on Character {
          notes(first: 2) @connection(key: "HostileConnectionNodes_notes") {
            nodes: totalCount
            edges { node { id } }
          }
        }
        """)
    var connectionNodes: HostileConnectionNodes_character

    /// A fragment named from an underscore, which has no owner's prefix: its
    /// spread's accessor takes its whole name.
    @Fragment("""
        fragment _hostileHidden on Character {
          name
        }
        """)
    var hidden: _hostileHidden

    @Query("""
        query HostileHidden {
          character(id: 1) { ..._hostileHidden }
        }
        """)
    var hiddenQuery: HostileHidden

    /// Each name as a field of a lens whose required field bubbles to the root,
    /// whose checks read a link as `child` and report the field that is
    /// `missing`.
    @Query("""
        query HostileRequired {
          character(id: 1) @required(action: NONE) {
            # Swift's keywords, as `escape` lists them.
            Type: name Protocol: name Any: name self: name Self: name init: name deinit: name
            subscript: name class: name struct: name enum: name func: name var: name let: name
            import: name extension: name operator: name static: name default: name case: name
            switch: name if: name else: name for: name in: name while: name repeat: name return: name
            break: name continue: name where: name is: name as: name try: name throw: name throws: name
            guard: name defer: name do: name catch: name true: name false: name nil: name super: name
            internal: name private: name public: name fileprivate: name open: name inout: name
            typealias: name associatedtype: name protocol: name some: name any: name
            rethrows: name fallthrough: name precedencegroup: name _: name
            # Swift's contextual keywords that start an expression or a type.
            async: name await: name borrowing: name consume: name consuming: name copy: name
            discard: name each: name isolated: name sending: name then: name unsafe: name
            # What every lens declares, and what a refetchable fragment and a connection add.
            typeName: name satisfied: name missingRequiredField: name fieldErrors: name isPresent: name
            throwing: name caught: name refetchable: name refetch: name connection: name nodes: name
            hasNext: name hasPrevious: name isLoadingNext: name isLoadingPrevious: name
            connectionID: name loadNext: name loadPrevious: name
            # The locals, parameters and local aliases of generated bodies.
            bound: name errors: name child: name missing: name count: name fields: name lhs: name
            rhs: name hasher: name optimistic: name selfValue: name Fragment: name Spread: name
            Owner: name Query: name Operation: name RefetchQuery: name
            # What an operation value, a mutation's action and its optimistic response declare.
            variables: name resolution: name name: name persistedID: name text: name plan: name
            errorBehavior: name throwsOnFieldError: name bubbles: name hasDeferred: name Data: name
            Action: name OptimisticResponse: name hash: name commit: name callAsFunction: name Op: name
            variable: name
            # What the runtime's protocols give a generated type.
            hashValue: name phase: name isRefreshing: name isStale: name retry: name subscription: name
            # The shared enums.
            Sites: name AbstractSlots: name schemaDigest: name
            # The modules, and what the generated code spells from the standard library.
            Baton: name Swift: name Set: name Result: name Optional: name String: name Int: name
            Double: name Bool: name MainActor: name Hasher: name Sendable: name
            origin @required(action: NONE) { name @required(action: NONE) }
          }
        }
        """)
    var required: HostileRequired

    /// Each name as a field of a lens on an interface, which reads its slots on
    /// the record's type and tests the record against a type condition.
    @Fragment("""
        fragment HostileAbstract_node on Node {
          # Swift's keywords, as `escape` lists them.
          Type: id Protocol: id Any: id self: id Self: id init: id deinit: id subscript: id class: id
          struct: id enum: id func: id var: id let: id import: id extension: id operator: id static: id
          default: id case: id switch: id if: id else: id for: id in: id while: id repeat: id return: id
          break: id continue: id where: id is: id as: id try: id throw: id throws: id guard: id
          defer: id do: id catch: id true: id false: id nil: id super: id internal: id private: id
          public: id fileprivate: id open: id inout: id typealias: id associatedtype: id protocol: id
          some: id any: id
          rethrows: id fallthrough: id precedencegroup: id _: id
          # Swift's contextual keywords that start an expression or a type.
          async: id await: id borrowing: id consume: id consuming: id copy: id discard: id each: id
          isolated: id sending: id then: id unsafe: id
          # What every lens declares, and what a refetchable fragment and a connection add.
          typeName: id satisfied: id missingRequiredField: id fieldErrors: id isPresent: id throwing: id
          caught: id refetchable: id refetch: id connection: id nodes: id hasNext: id hasPrevious: id
          isLoadingNext: id isLoadingPrevious: id connectionID: id loadNext: id loadPrevious: id
          # The locals, parameters and local aliases of generated bodies.
          bound: id errors: id child: id missing: id count: id fields: id lhs: id rhs: id hasher: id
          optimistic: id selfValue: id Fragment: id Spread: id Owner: id Query: id Operation: id
          RefetchQuery: id
          # What an operation value, a mutation's action and its optimistic response declare.
          variables: id resolution: id name: id persistedID: id text: id plan: id errorBehavior: id
          throwsOnFieldError: id bubbles: id hasDeferred: id Data: id Action: id OptimisticResponse: id
          hash: id commit: id callAsFunction: id Op: id variable: id
          # What the runtime's protocols give a generated type.
          hashValue: id phase: id isRefreshing: id isStale: id retry: id subscription: id
          # The shared enums.
          Sites: id schemaDigest: id
          # The modules, and what the generated code spells from the standard library.
          Baton: id Swift: id Set: id Result: id Optional: id String: id Int: id Double: id Bool: id
          MainActor: id Hasher: id Sendable: id
          ... on Character { status }
        }
        """)
    var abstract: HostileAbstract_node

    /// Each name as a variable of a query: a stored property of its value,
    /// which every lens nested in it sees, and these lenses check their field
    /// errors.
    @Query("""
        query HostileVariables(
          # Swift's keywords, as `escape` lists them.
          $Type: ID!, $Protocol: ID!, $Any: ID!, $self: ID!, $init: ID!, $deinit: ID!, $subscript: ID!,
          $class: ID!, $struct: ID!, $enum: ID!, $func: ID!, $var: ID!, $let: ID!, $import: ID!,
          $extension: ID!, $operator: ID!, $static: ID!, $default: ID!, $case: ID!, $switch: ID!,
          $if: ID!, $else: ID!, $for: ID!, $in: ID!, $while: ID!, $repeat: ID!, $return: ID!,
          $break: ID!, $continue: ID!, $where: ID!, $is: ID!, $as: ID!, $try: ID!, $throw: ID!,
          $throws: ID!, $guard: ID!, $defer: ID!, $do: ID!, $catch: ID!, $true: ID!, $false: ID!,
          $nil: ID!, $super: ID!, $internal: ID!, $private: ID!, $public: ID!, $fileprivate: ID!,
          $open: ID!, $inout: ID!, $typealias: ID!, $associatedtype: ID!, $protocol: ID!, $some: ID!,
          $any: ID!,
          $rethrows: ID!, $fallthrough: ID!, $precedencegroup: ID!, $_: ID!, $Self: ID!,
          # Swift's contextual keywords that start an expression or a type.
          $async: ID!, $borrowing: ID!, $consume: ID!, $consuming: ID!, $copy: ID!, $discard: ID!,
          $each: ID!, $isolated: ID!, $sending: ID!, $then: ID!, $unsafe: ID!, $await: ID!,
          # What every lens declares, and what a refetchable fragment and a connection add.
          $anchor: ID!, $recordID: ID!, $typeName: ID!, $satisfied: ID!, $missingRequiredField: ID!,
          $fieldErrors: ID!, $isPresent: ID!, $throwing: ID!, $caught: ID!, $refetchable: ID!,
          $refetch: ID!, $connection: ID!, $nodes: ID!, $hasNext: ID!, $hasPrevious: ID!,
          $isLoadingNext: ID!, $isLoadingPrevious: ID!, $connectionID: ID!, $loadNext: ID!,
          $loadPrevious: ID!,
          # The locals, parameters and local aliases of generated bodies.
          $bound: ID!, $errors: ID!, $child: ID!, $missing: ID!, $count: ID!, $fields: ID!, $lhs: ID!,
          $rhs: ID!, $hasher: ID!, $optimistic: ID!, $selfValue: ID!, $Fragment: ID!, $Spread: ID!,
          $Owner: ID!, $Query: ID!, $Operation: ID!, $RefetchQuery: ID!,
          # What an operation value, a mutation's action and its optimistic response declare.
          $name: ID!, $persistedID: ID!, $text: ID!, $plan: ID!, $errorBehavior: ID!,
          $throwsOnFieldError: ID!, $bubbles: ID!, $hasDeferred: ID!, $Action: ID!,
          $OptimisticResponse: ID!, $hash: ID!, $commit: ID!, $callAsFunction: ID!, $Op: ID!,
          $variable: ID!,
          # What the runtime's protocols give a generated type.
          $retry: ID!, $subscription: ID!,
          # The shared enums.
          $Sites: ID!, $AbstractSlots: ID!, $schemaDigest: ID!,
          # The modules, and what the generated code spells from the standard library.
          $Swift: ID!, $Set: ID!, $Result: ID!, $Optional: ID!, $String: ID!, $Int: ID!, $Double: ID!,
          $Bool: ID!, $MainActor: ID!, $Hasher: ID!, $Sendable: ID!
        ) @throwOnFieldError {
          charactersByIds(ids: [
            # Swift's keywords, as `escape` lists them.
            $Type, $Protocol, $Any, $self, $init, $deinit, $subscript, $class, $struct, $enum, $func,
            $var, $let, $import, $extension, $operator, $static, $default, $case, $switch, $if, $else,
            $for, $in, $while, $repeat, $return, $break, $continue, $where, $is, $as, $try, $throw,
            $throws, $guard, $defer, $do, $catch, $true, $false, $nil, $super, $internal, $private,
            $public, $fileprivate, $open, $inout, $typealias, $associatedtype, $protocol, $some, $any,
            $rethrows, $fallthrough, $precedencegroup, $_, $Self,
            # Swift's contextual keywords that start an expression or a type.
            $async, $borrowing, $consume, $consuming, $copy, $discard, $each, $isolated, $sending,
            $then, $unsafe, $await,
            # What every lens declares, and what a refetchable fragment and a connection add.
            $anchor, $recordID, $typeName, $satisfied, $missingRequiredField, $fieldErrors, $isPresent,
            $throwing, $caught, $refetchable, $refetch, $connection, $nodes, $hasNext, $hasPrevious,
            $isLoadingNext, $isLoadingPrevious, $connectionID, $loadNext, $loadPrevious,
            # The locals, parameters and local aliases of generated bodies.
            $bound, $errors, $child, $missing, $count, $fields, $lhs, $rhs, $hasher, $optimistic,
            $selfValue, $Fragment, $Spread, $Owner, $Query, $Operation, $RefetchQuery,
            # What an operation value, a mutation's action and its optimistic response declare.
            $name, $persistedID, $text, $plan, $errorBehavior, $throwsOnFieldError, $bubbles,
            $hasDeferred, $Action, $OptimisticResponse, $hash, $commit, $callAsFunction, $Op, $variable,
            # What the runtime's protocols give a generated type.
            $retry, $subscription,
            # The shared enums.
            $Sites, $AbstractSlots, $schemaDigest,
            # The modules, and what the generated code spells from the standard library.
            $Swift, $Set, $Result, $Optional, $String, $Int, $Double, $Bool, $MainActor, $Hasher,
            $Sendable
          ]) { id }
        }
        """)
    var variables: HostileVariables

    /// Each name as a variable of a mutation: a stored property of its value,
    /// which the lenses nested in it see as they check a caught field's errors,
    /// and a parameter label of its action.
    @Mutation("""
        mutation HostileMutationVariables(
          # Swift's keywords, as `escape` lists them.
          $Type: Boolean!, $Protocol: Boolean!, $Any: Boolean!, $self: Boolean!, $init: Boolean!,
          $deinit: Boolean!, $subscript: Boolean!, $class: Boolean!, $struct: Boolean!, $enum: Boolean!,
          $func: Boolean!, $import: Boolean!, $extension: Boolean!, $operator: Boolean!,
          $static: Boolean!, $default: Boolean!, $case: Boolean!, $switch: Boolean!, $if: Boolean!,
          $else: Boolean!, $for: Boolean!, $in: Boolean!, $while: Boolean!, $repeat: Boolean!,
          $return: Boolean!, $break: Boolean!, $continue: Boolean!, $where: Boolean!, $is: Boolean!,
          $as: Boolean!, $try: Boolean!, $throw: Boolean!, $throws: Boolean!, $guard: Boolean!,
          $defer: Boolean!, $do: Boolean!, $catch: Boolean!, $true: Boolean!, $false: Boolean!,
          $nil: Boolean!, $super: Boolean!, $internal: Boolean!, $private: Boolean!, $public: Boolean!,
          $fileprivate: Boolean!, $open: Boolean!, $inout: Boolean!, $typealias: Boolean!,
          $associatedtype: Boolean!, $protocol: Boolean!, $some: Boolean!, $any: Boolean!,
          $rethrows: Boolean!, $fallthrough: Boolean!, $precedencegroup: Boolean!, $_: Boolean!,
          $var: Boolean!, $let: Boolean!, $Self: Boolean!,
          # Swift's contextual keywords that start an expression or a type.
          $async: Boolean!, $borrowing: Boolean!, $consume: Boolean!, $consuming: Boolean!,
          $copy: Boolean!, $discard: Boolean!, $each: Boolean!, $isolated: Boolean!, $sending: Boolean!,
          $then: Boolean!, $unsafe: Boolean!, $await: Boolean!,
          # What every lens declares, and what a refetchable fragment and a connection add.
          $anchor: Boolean!, $recordID: Boolean!, $typeName: Boolean!, $satisfied: Boolean!,
          $missingRequiredField: Boolean!, $fieldErrors: Boolean!, $isPresent: Boolean!,
          $throwing: Boolean!, $caught: Boolean!, $refetchable: Boolean!, $refetch: Boolean!,
          $connection: Boolean!, $nodes: Boolean!, $hasNext: Boolean!, $hasPrevious: Boolean!,
          $isLoadingNext: Boolean!, $isLoadingPrevious: Boolean!, $connectionID: Boolean!,
          $loadNext: Boolean!, $loadPrevious: Boolean!,
          # The locals, parameters and local aliases of generated bodies.
          $bound: Boolean!, $errors: Boolean!, $child: Boolean!, $missing: Boolean!, $count: Boolean!,
          $fields: Boolean!, $lhs: Boolean!, $rhs: Boolean!, $hasher: Boolean!, $selfValue: Boolean!,
          $Fragment: Boolean!, $Spread: Boolean!, $Owner: Boolean!, $Query: Boolean!,
          $Operation: Boolean!, $RefetchQuery: Boolean!,
          # What an operation value, a mutation's action and its optimistic response declare.
          $resolution: Boolean!, $name: Boolean!, $persistedID: Boolean!, $text: Boolean!,
          $plan: Boolean!, $errorBehavior: Boolean!, $throwsOnFieldError: Boolean!, $bubbles: Boolean!,
          $hasDeferred: Boolean!, $hash: Boolean!, $commit: Boolean!, $callAsFunction: Boolean!,
          $Op: Boolean!, $variable: Boolean!,
          # What the runtime's protocols give a generated type.
          $phase: Boolean!, $isRefreshing: Boolean!, $isStale: Boolean!, $retry: Boolean!,
          $subscription: Boolean!,
          # The shared enums.
          $Sites: Boolean!, $AbstractSlots: Boolean!, $schemaDigest: Boolean!,
          # The modules, and what the generated code spells from the standard library.
          $Swift: Boolean!, $Set: Boolean!, $Result: Boolean!, $Optional: Boolean!, $String: Boolean!,
          $Int: Boolean!, $Double: Boolean!, $Bool: Boolean!, $MainActor: Boolean!, $Hasher: Boolean!,
          $Sendable: Boolean!
        ) {
          setFavorite(id: "1", favorite: true) @catch {
            character {
              id
              # Swift's keywords, as `escape` lists them.
              ... @include(if: $Type) { name } ... @include(if: $Protocol) { name }
              ... @include(if: $Any) { name } ... @include(if: $self) { name }
              ... @include(if: $init) { name } ... @include(if: $deinit) { name }
              ... @include(if: $subscript) { name } ... @include(if: $class) { name }
              ... @include(if: $struct) { name } ... @include(if: $enum) { name }
              ... @include(if: $func) { name } ... @include(if: $import) { name }
              ... @include(if: $extension) { name } ... @include(if: $operator) { name }
              ... @include(if: $static) { name } ... @include(if: $default) { name }
              ... @include(if: $case) { name } ... @include(if: $switch) { name }
              ... @include(if: $if) { name } ... @include(if: $else) { name }
              ... @include(if: $for) { name } ... @include(if: $in) { name }
              ... @include(if: $while) { name } ... @include(if: $repeat) { name }
              ... @include(if: $return) { name } ... @include(if: $break) { name }
              ... @include(if: $continue) { name } ... @include(if: $where) { name }
              ... @include(if: $is) { name } ... @include(if: $as) { name }
              ... @include(if: $try) { name } ... @include(if: $throw) { name }
              ... @include(if: $throws) { name } ... @include(if: $guard) { name }
              ... @include(if: $defer) { name } ... @include(if: $do) { name }
              ... @include(if: $catch) { name } ... @include(if: $true) { name }
              ... @include(if: $false) { name } ... @include(if: $nil) { name }
              ... @include(if: $super) { name } ... @include(if: $internal) { name }
              ... @include(if: $private) { name } ... @include(if: $public) { name }
              ... @include(if: $fileprivate) { name } ... @include(if: $open) { name }
              ... @include(if: $inout) { name } ... @include(if: $typealias) { name }
              ... @include(if: $associatedtype) { name } ... @include(if: $protocol) { name }
              ... @include(if: $some) { name } ... @include(if: $any) { name }
              ... @include(if: $rethrows) { name } ... @include(if: $fallthrough) { name }
              ... @include(if: $precedencegroup) { name } ... @include(if: $_) { name }
              ... @include(if: $var) { name } ... @include(if: $let) { name }
              ... @include(if: $Self) { name }
              # Swift's contextual keywords that start an expression or a type.
              ... @include(if: $async) { name } ... @include(if: $borrowing) { name }
              ... @include(if: $consume) { name } ... @include(if: $consuming) { name }
              ... @include(if: $copy) { name } ... @include(if: $discard) { name }
              ... @include(if: $each) { name } ... @include(if: $isolated) { name }
              ... @include(if: $sending) { name } ... @include(if: $then) { name }
              ... @include(if: $unsafe) { name } ... @include(if: $await) { name }
              # What every lens declares, and what a refetchable fragment and a connection add.
              ... @include(if: $anchor) { name } ... @include(if: $recordID) { name }
              ... @include(if: $typeName) { name } ... @include(if: $satisfied) { name }
              ... @include(if: $missingRequiredField) { name } ... @include(if: $fieldErrors) { name }
              ... @include(if: $isPresent) { name } ... @include(if: $throwing) { name }
              ... @include(if: $caught) { name } ... @include(if: $refetchable) { name }
              ... @include(if: $refetch) { name } ... @include(if: $connection) { name }
              ... @include(if: $nodes) { name } ... @include(if: $hasNext) { name }
              ... @include(if: $hasPrevious) { name } ... @include(if: $isLoadingNext) { name }
              ... @include(if: $isLoadingPrevious) { name } ... @include(if: $connectionID) { name }
              ... @include(if: $loadNext) { name } ... @include(if: $loadPrevious) { name }
              # The locals, parameters and local aliases of generated bodies.
              ... @include(if: $bound) { name } ... @include(if: $errors) { name }
              ... @include(if: $child) { name } ... @include(if: $missing) { name }
              ... @include(if: $count) { name } ... @include(if: $fields) { name }
              ... @include(if: $lhs) { name } ... @include(if: $rhs) { name }
              ... @include(if: $hasher) { name } ... @include(if: $selfValue) { name }
              ... @include(if: $Fragment) { name } ... @include(if: $Spread) { name }
              ... @include(if: $Owner) { name } ... @include(if: $Query) { name }
              ... @include(if: $Operation) { name } ... @include(if: $RefetchQuery) { name }
              # What an operation value, a mutation's action and its optimistic response declare.
              ... @include(if: $resolution) { name } ... @include(if: $name) { name }
              ... @include(if: $persistedID) { name } ... @include(if: $text) { name }
              ... @include(if: $plan) { name } ... @include(if: $errorBehavior) { name }
              ... @include(if: $throwsOnFieldError) { name } ... @include(if: $bubbles) { name }
              ... @include(if: $hasDeferred) { name } ... @include(if: $hash) { name }
              ... @include(if: $commit) { name } ... @include(if: $callAsFunction) { name }
              ... @include(if: $Op) { name } ... @include(if: $variable) { name }
              # What the runtime's protocols give a generated type.
              ... @include(if: $phase) { name } ... @include(if: $isRefreshing) { name }
              ... @include(if: $isStale) { name } ... @include(if: $retry) { name }
              ... @include(if: $subscription) { name }
              # The shared enums.
              ... @include(if: $Sites) { name } ... @include(if: $AbstractSlots) { name }
              ... @include(if: $schemaDigest) { name }
              # The modules, and what the generated code spells from the standard library.
              ... @include(if: $Swift) { name } ... @include(if: $Set) { name }
              ... @include(if: $Result) { name } ... @include(if: $Optional) { name }
              ... @include(if: $String) { name } ... @include(if: $Int) { name }
              ... @include(if: $Double) { name } ... @include(if: $Bool) { name }
              ... @include(if: $MainActor) { name } ... @include(if: $Hasher) { name }
              ... @include(if: $Sendable) { name }
            }
          }
        }
        """)
    var mutationVariables: HostileMutationVariables.Action

    /// A mutation whose variable is named like it, which its action passes
    /// to the mutation's initializer.
    @Mutation("""
        mutation HostileNamesake($HostileNamesake: ID!) {
          setFavorite(id: $HostileNamesake, favorite: true) { character { id } }
        }
        """)
    var namesake: HostileNamesake.Action

    /// Each name as a variable of a subscription, which the lenses nested in it
    /// see as they check a caught field's errors.
    @Subscription("""
        subscription HostileSubscriptionVariables(
          # Swift's keywords, as `escape` lists them.
          $Type: Boolean!, $Protocol: Boolean!, $Any: Boolean!, $self: Boolean!, $init: Boolean!,
          $deinit: Boolean!, $subscript: Boolean!, $class: Boolean!, $struct: Boolean!, $enum: Boolean!,
          $func: Boolean!, $var: Boolean!, $let: Boolean!, $import: Boolean!, $extension: Boolean!,
          $operator: Boolean!, $static: Boolean!, $default: Boolean!, $case: Boolean!,
          $switch: Boolean!, $if: Boolean!, $else: Boolean!, $for: Boolean!, $in: Boolean!,
          $while: Boolean!, $repeat: Boolean!, $return: Boolean!, $break: Boolean!, $continue: Boolean!,
          $where: Boolean!, $is: Boolean!, $as: Boolean!, $try: Boolean!, $throw: Boolean!,
          $throws: Boolean!, $guard: Boolean!, $defer: Boolean!, $do: Boolean!, $catch: Boolean!,
          $true: Boolean!, $false: Boolean!, $nil: Boolean!, $super: Boolean!, $internal: Boolean!,
          $private: Boolean!, $public: Boolean!, $fileprivate: Boolean!, $open: Boolean!,
          $inout: Boolean!, $typealias: Boolean!, $associatedtype: Boolean!, $protocol: Boolean!,
          $some: Boolean!, $any: Boolean!,
          $rethrows: Boolean!, $fallthrough: Boolean!, $precedencegroup: Boolean!, $_: Boolean!,
          $Self: Boolean!,
          # Swift's contextual keywords that start an expression or a type.
          $async: Boolean!, $borrowing: Boolean!, $consume: Boolean!, $consuming: Boolean!,
          $copy: Boolean!, $discard: Boolean!, $each: Boolean!, $isolated: Boolean!, $sending: Boolean!,
          $then: Boolean!, $unsafe: Boolean!, $await: Boolean!,
          # What every lens declares, and what a refetchable fragment and a connection add.
          $anchor: Boolean!, $recordID: Boolean!, $typeName: Boolean!, $satisfied: Boolean!,
          $missingRequiredField: Boolean!, $fieldErrors: Boolean!, $isPresent: Boolean!,
          $throwing: Boolean!, $caught: Boolean!, $refetchable: Boolean!, $refetch: Boolean!,
          $connection: Boolean!, $nodes: Boolean!, $hasNext: Boolean!, $hasPrevious: Boolean!,
          $isLoadingNext: Boolean!, $isLoadingPrevious: Boolean!, $connectionID: Boolean!,
          $loadNext: Boolean!, $loadPrevious: Boolean!,
          # The locals, parameters and local aliases of generated bodies.
          $bound: Boolean!, $errors: Boolean!, $child: Boolean!, $missing: Boolean!, $count: Boolean!,
          $fields: Boolean!, $lhs: Boolean!, $rhs: Boolean!, $hasher: Boolean!, $optimistic: Boolean!,
          $selfValue: Boolean!, $Fragment: Boolean!, $Spread: Boolean!, $Owner: Boolean!,
          $Query: Boolean!, $Operation: Boolean!, $RefetchQuery: Boolean!,
          # What an operation value, a mutation's action and its optimistic response declare.
          $name: Boolean!, $persistedID: Boolean!, $text: Boolean!, $plan: Boolean!,
          $errorBehavior: Boolean!, $throwsOnFieldError: Boolean!, $bubbles: Boolean!,
          $hasDeferred: Boolean!, $Action: Boolean!, $OptimisticResponse: Boolean!, $hash: Boolean!,
          $commit: Boolean!, $callAsFunction: Boolean!, $Op: Boolean!, $variable: Boolean!,
          # What the runtime's protocols give a generated type.
          $phase: Boolean!, $isRefreshing: Boolean!, $isStale: Boolean!, $retry: Boolean!,
          # The shared enums.
          $Sites: Boolean!, $AbstractSlots: Boolean!, $schemaDigest: Boolean!,
          # The modules, and what the generated code spells from the standard library.
          $Swift: Boolean!, $Set: Boolean!, $Result: Boolean!, $Optional: Boolean!, $String: Boolean!,
          $Int: Boolean!, $Double: Boolean!, $Bool: Boolean!, $MainActor: Boolean!, $Hasher: Boolean!,
          $Sendable: Boolean!
        ) {
          noteAdded(characterId: "1") @catch {
            noteEdge {
              node { id }
              # Swift's keywords, as `escape` lists them.
              ... @include(if: $Type) { cursor } ... @include(if: $Protocol) { cursor }
              ... @include(if: $Any) { cursor } ... @include(if: $self) { cursor }
              ... @include(if: $init) { cursor } ... @include(if: $deinit) { cursor }
              ... @include(if: $subscript) { cursor } ... @include(if: $class) { cursor }
              ... @include(if: $struct) { cursor } ... @include(if: $enum) { cursor }
              ... @include(if: $func) { cursor } ... @include(if: $var) { cursor }
              ... @include(if: $let) { cursor } ... @include(if: $import) { cursor }
              ... @include(if: $extension) { cursor } ... @include(if: $operator) { cursor }
              ... @include(if: $static) { cursor } ... @include(if: $default) { cursor }
              ... @include(if: $case) { cursor } ... @include(if: $switch) { cursor }
              ... @include(if: $if) { cursor } ... @include(if: $else) { cursor }
              ... @include(if: $for) { cursor } ... @include(if: $in) { cursor }
              ... @include(if: $while) { cursor } ... @include(if: $repeat) { cursor }
              ... @include(if: $return) { cursor } ... @include(if: $break) { cursor }
              ... @include(if: $continue) { cursor } ... @include(if: $where) { cursor }
              ... @include(if: $is) { cursor } ... @include(if: $as) { cursor }
              ... @include(if: $try) { cursor } ... @include(if: $throw) { cursor }
              ... @include(if: $throws) { cursor } ... @include(if: $guard) { cursor }
              ... @include(if: $defer) { cursor } ... @include(if: $do) { cursor }
              ... @include(if: $catch) { cursor } ... @include(if: $true) { cursor }
              ... @include(if: $false) { cursor } ... @include(if: $nil) { cursor }
              ... @include(if: $super) { cursor } ... @include(if: $internal) { cursor }
              ... @include(if: $private) { cursor } ... @include(if: $public) { cursor }
              ... @include(if: $fileprivate) { cursor } ... @include(if: $open) { cursor }
              ... @include(if: $inout) { cursor } ... @include(if: $typealias) { cursor }
              ... @include(if: $associatedtype) { cursor } ... @include(if: $protocol) { cursor }
              ... @include(if: $some) { cursor } ... @include(if: $any) { cursor }
              ... @include(if: $rethrows) { cursor } ... @include(if: $fallthrough) { cursor }
              ... @include(if: $precedencegroup) { cursor } ... @include(if: $_) { cursor }
              ... @include(if: $Self) { cursor }
              # Swift's contextual keywords that start an expression or a type.
              ... @include(if: $async) { cursor } ... @include(if: $borrowing) { cursor }
              ... @include(if: $consume) { cursor } ... @include(if: $consuming) { cursor }
              ... @include(if: $copy) { cursor } ... @include(if: $discard) { cursor }
              ... @include(if: $each) { cursor } ... @include(if: $isolated) { cursor }
              ... @include(if: $sending) { cursor } ... @include(if: $then) { cursor }
              ... @include(if: $unsafe) { cursor } ... @include(if: $await) { cursor }
              # What every lens declares, and what a refetchable fragment and a connection add.
              ... @include(if: $anchor) { cursor } ... @include(if: $recordID) { cursor }
              ... @include(if: $typeName) { cursor } ... @include(if: $satisfied) { cursor }
              ... @include(if: $missingRequiredField) { cursor }
              ... @include(if: $fieldErrors) { cursor } ... @include(if: $isPresent) { cursor }
              ... @include(if: $throwing) { cursor } ... @include(if: $caught) { cursor }
              ... @include(if: $refetchable) { cursor } ... @include(if: $refetch) { cursor }
              ... @include(if: $connection) { cursor } ... @include(if: $nodes) { cursor }
              ... @include(if: $hasNext) { cursor } ... @include(if: $hasPrevious) { cursor }
              ... @include(if: $isLoadingNext) { cursor }
              ... @include(if: $isLoadingPrevious) { cursor } ... @include(if: $connectionID) { cursor }
              ... @include(if: $loadNext) { cursor } ... @include(if: $loadPrevious) { cursor }
              # The locals, parameters and local aliases of generated bodies.
              ... @include(if: $bound) { cursor } ... @include(if: $errors) { cursor }
              ... @include(if: $child) { cursor } ... @include(if: $missing) { cursor }
              ... @include(if: $count) { cursor } ... @include(if: $fields) { cursor }
              ... @include(if: $lhs) { cursor } ... @include(if: $rhs) { cursor }
              ... @include(if: $hasher) { cursor } ... @include(if: $optimistic) { cursor }
              ... @include(if: $selfValue) { cursor } ... @include(if: $Fragment) { cursor }
              ... @include(if: $Spread) { cursor } ... @include(if: $Owner) { cursor }
              ... @include(if: $Query) { cursor } ... @include(if: $Operation) { cursor }
              ... @include(if: $RefetchQuery) { cursor }
              # What an operation value, a mutation's action and its optimistic response declare.
              ... @include(if: $name) { cursor } ... @include(if: $persistedID) { cursor }
              ... @include(if: $text) { cursor } ... @include(if: $plan) { cursor }
              ... @include(if: $errorBehavior) { cursor }
              ... @include(if: $throwsOnFieldError) { cursor } ... @include(if: $bubbles) { cursor }
              ... @include(if: $hasDeferred) { cursor } ... @include(if: $Action) { cursor }
              ... @include(if: $OptimisticResponse) { cursor } ... @include(if: $hash) { cursor }
              ... @include(if: $commit) { cursor } ... @include(if: $callAsFunction) { cursor }
              ... @include(if: $Op) { cursor } ... @include(if: $variable) { cursor }
              # What the runtime's protocols give a generated type.
              ... @include(if: $phase) { cursor } ... @include(if: $isRefreshing) { cursor }
              ... @include(if: $isStale) { cursor } ... @include(if: $retry) { cursor }
              # The shared enums.
              ... @include(if: $Sites) { cursor } ... @include(if: $AbstractSlots) { cursor }
              ... @include(if: $schemaDigest) { cursor }
              # The modules, and what the generated code spells from the standard library.
              ... @include(if: $Swift) { cursor } ... @include(if: $Set) { cursor }
              ... @include(if: $Result) { cursor } ... @include(if: $Optional) { cursor }
              ... @include(if: $String) { cursor } ... @include(if: $Int) { cursor }
              ... @include(if: $Double) { cursor } ... @include(if: $Bool) { cursor }
              ... @include(if: $MainActor) { cursor } ... @include(if: $Hasher) { cursor }
              ... @include(if: $Sendable) { cursor }
            }
          }
        }
        """)
    var subscriptionVariables: HostileSubscriptionVariables

    /// Each name as an argument of a refetchable fragment, a variable of its
    /// refetch query, which binds every one of them in one expression.
    @Fragment("""
        fragment HostileArguments_character on Character
        @argumentDefinitions(
          # Swift's keywords, as `escape` lists them.
          Type: {type: "Boolean", defaultValue: true},
          Protocol: {type: "Boolean", defaultValue: true},
          Any: {type: "Boolean", defaultValue: true},
          self: {type: "Boolean", defaultValue: true},
          Self: {type: "Boolean", defaultValue: true},
          init: {type: "Boolean", defaultValue: true},
          deinit: {type: "Boolean", defaultValue: true},
          subscript: {type: "Boolean", defaultValue: true},
          class: {type: "Boolean", defaultValue: true},
          struct: {type: "Boolean", defaultValue: true},
          enum: {type: "Boolean", defaultValue: true},
          func: {type: "Boolean", defaultValue: true},
          var: {type: "Boolean", defaultValue: true},
          let: {type: "Boolean", defaultValue: true},
          import: {type: "Boolean", defaultValue: true},
          extension: {type: "Boolean", defaultValue: true},
          operator: {type: "Boolean", defaultValue: true},
          static: {type: "Boolean", defaultValue: true},
          default: {type: "Boolean", defaultValue: true},
          case: {type: "Boolean", defaultValue: true},
          switch: {type: "Boolean", defaultValue: true},
          if: {type: "Boolean", defaultValue: true},
          else: {type: "Boolean", defaultValue: true},
          for: {type: "Boolean", defaultValue: true},
          in: {type: "Boolean", defaultValue: true},
          while: {type: "Boolean", defaultValue: true},
          repeat: {type: "Boolean", defaultValue: true},
          return: {type: "Boolean", defaultValue: true},
          break: {type: "Boolean", defaultValue: true},
          continue: {type: "Boolean", defaultValue: true},
          where: {type: "Boolean", defaultValue: true},
          is: {type: "Boolean", defaultValue: true},
          as: {type: "Boolean", defaultValue: true},
          try: {type: "Boolean", defaultValue: true},
          throw: {type: "Boolean", defaultValue: true},
          throws: {type: "Boolean", defaultValue: true},
          guard: {type: "Boolean", defaultValue: true},
          defer: {type: "Boolean", defaultValue: true},
          do: {type: "Boolean", defaultValue: true},
          catch: {type: "Boolean", defaultValue: true},
          true: {type: "Boolean", defaultValue: true},
          false: {type: "Boolean", defaultValue: true},
          nil: {type: "Boolean", defaultValue: true},
          super: {type: "Boolean", defaultValue: true},
          internal: {type: "Boolean", defaultValue: true},
          private: {type: "Boolean", defaultValue: true},
          public: {type: "Boolean", defaultValue: true},
          fileprivate: {type: "Boolean", defaultValue: true},
          open: {type: "Boolean", defaultValue: true},
          inout: {type: "Boolean", defaultValue: true},
          typealias: {type: "Boolean", defaultValue: true},
          associatedtype: {type: "Boolean", defaultValue: true},
          protocol: {type: "Boolean", defaultValue: true},
          some: {type: "Boolean", defaultValue: true},
          any: {type: "Boolean", defaultValue: true},
          rethrows: {type: "Boolean", defaultValue: true},
          fallthrough: {type: "Boolean", defaultValue: true},
          precedencegroup: {type: "Boolean", defaultValue: true},
          _: {type: "Boolean", defaultValue: true},
          # Swift's contextual keywords that start an expression or a type.
          async: {type: "Boolean", defaultValue: true},
          borrowing: {type: "Boolean", defaultValue: true},
          consume: {type: "Boolean", defaultValue: true},
          consuming: {type: "Boolean", defaultValue: true},
          copy: {type: "Boolean", defaultValue: true},
          discard: {type: "Boolean", defaultValue: true},
          each: {type: "Boolean", defaultValue: true},
          isolated: {type: "Boolean", defaultValue: true},
          sending: {type: "Boolean", defaultValue: true},
          then: {type: "Boolean", defaultValue: true},
          unsafe: {type: "Boolean", defaultValue: true},
          await: {type: "Boolean", defaultValue: true},
          # What every lens declares, and what a refetchable fragment and a connection add.
          anchor: {type: "Boolean", defaultValue: true},
          recordID: {type: "Boolean", defaultValue: true},
          typeName: {type: "Boolean", defaultValue: true},
          satisfied: {type: "Boolean", defaultValue: true},
          missingRequiredField: {type: "Boolean", defaultValue: true},
          fieldErrors: {type: "Boolean", defaultValue: true},
          isPresent: {type: "Boolean", defaultValue: true},
          throwing: {type: "Boolean", defaultValue: true},
          caught: {type: "Boolean", defaultValue: true},
          refetchable: {type: "Boolean", defaultValue: true},
          refetch: {type: "Boolean", defaultValue: true},
          connection: {type: "Boolean", defaultValue: true},
          nodes: {type: "Boolean", defaultValue: true},
          hasNext: {type: "Boolean", defaultValue: true},
          hasPrevious: {type: "Boolean", defaultValue: true},
          isLoadingNext: {type: "Boolean", defaultValue: true},
          isLoadingPrevious: {type: "Boolean", defaultValue: true},
          connectionID: {type: "Boolean", defaultValue: true},
          loadNext: {type: "Boolean", defaultValue: true},
          loadPrevious: {type: "Boolean", defaultValue: true},
          # The locals, parameters and local aliases of generated bodies.
          bound: {type: "Boolean", defaultValue: true},
          errors: {type: "Boolean", defaultValue: true},
          child: {type: "Boolean", defaultValue: true},
          missing: {type: "Boolean", defaultValue: true},
          count: {type: "Boolean", defaultValue: true},
          fields: {type: "Boolean", defaultValue: true},
          lhs: {type: "Boolean", defaultValue: true},
          rhs: {type: "Boolean", defaultValue: true},
          hasher: {type: "Boolean", defaultValue: true},
          optimistic: {type: "Boolean", defaultValue: true},
          selfValue: {type: "Boolean", defaultValue: true},
          Fragment: {type: "Boolean", defaultValue: true},
          Spread: {type: "Boolean", defaultValue: true},
          Owner: {type: "Boolean", defaultValue: true},
          Query: {type: "Boolean", defaultValue: true},
          Operation: {type: "Boolean", defaultValue: true},
          RefetchQuery: {type: "Boolean", defaultValue: true},
          # What an operation value, a mutation's action and its optimistic response declare.
          name: {type: "Boolean", defaultValue: true},
          persistedID: {type: "Boolean", defaultValue: true},
          text: {type: "Boolean", defaultValue: true},
          plan: {type: "Boolean", defaultValue: true},
          errorBehavior: {type: "Boolean", defaultValue: true},
          throwsOnFieldError: {type: "Boolean", defaultValue: true},
          bubbles: {type: "Boolean", defaultValue: true},
          hasDeferred: {type: "Boolean", defaultValue: true},
          Action: {type: "Boolean", defaultValue: true},
          OptimisticResponse: {type: "Boolean", defaultValue: true},
          hash: {type: "Boolean", defaultValue: true},
          commit: {type: "Boolean", defaultValue: true},
          callAsFunction: {type: "Boolean", defaultValue: true},
          Op: {type: "Boolean", defaultValue: true},
          variable: {type: "Boolean", defaultValue: true},
          # What the runtime's protocols give a generated type.
          retry: {type: "Boolean", defaultValue: true},
          subscription: {type: "Boolean", defaultValue: true},
          # The shared enums.
          AbstractSlots: {type: "Boolean", defaultValue: true},
          schemaDigest: {type: "Boolean", defaultValue: true},
          # The modules, and what the generated code spells from the standard library.
          Swift: {type: "Boolean", defaultValue: true},
          Set: {type: "Boolean", defaultValue: true},
          Result: {type: "Boolean", defaultValue: true},
          Optional: {type: "Boolean", defaultValue: true},
          String: {type: "Boolean", defaultValue: true},
          Int: {type: "Boolean", defaultValue: true},
          Double: {type: "Boolean", defaultValue: true},
          Bool: {type: "Boolean", defaultValue: true},
          MainActor: {type: "Boolean", defaultValue: true},
          Hasher: {type: "Boolean", defaultValue: true},
          Sendable: {type: "Boolean", defaultValue: true}
        )
        @refetchable(queryName: "HostileArgumentsRefetchQuery") {
          # Swift's keywords, as `escape` lists them.
          ... @include(if: $Type) { name } ... @include(if: $Protocol) { name }
          ... @include(if: $Any) { name } ... @include(if: $self) { name }
          ... @include(if: $Self) { name } ... @include(if: $init) { name }
          ... @include(if: $deinit) { name } ... @include(if: $subscript) { name }
          ... @include(if: $class) { name } ... @include(if: $struct) { name }
          ... @include(if: $enum) { name } ... @include(if: $func) { name }
          ... @include(if: $var) { name } ... @include(if: $let) { name }
          ... @include(if: $import) { name } ... @include(if: $extension) { name }
          ... @include(if: $operator) { name } ... @include(if: $static) { name }
          ... @include(if: $default) { name } ... @include(if: $case) { name }
          ... @include(if: $switch) { name } ... @include(if: $if) { name }
          ... @include(if: $else) { name } ... @include(if: $for) { name }
          ... @include(if: $in) { name } ... @include(if: $while) { name }
          ... @include(if: $repeat) { name } ... @include(if: $return) { name }
          ... @include(if: $break) { name } ... @include(if: $continue) { name }
          ... @include(if: $where) { name } ... @include(if: $is) { name }
          ... @include(if: $as) { name } ... @include(if: $try) { name }
          ... @include(if: $throw) { name } ... @include(if: $throws) { name }
          ... @include(if: $guard) { name } ... @include(if: $defer) { name }
          ... @include(if: $do) { name } ... @include(if: $catch) { name }
          ... @include(if: $true) { name } ... @include(if: $false) { name }
          ... @include(if: $nil) { name } ... @include(if: $super) { name }
          ... @include(if: $internal) { name } ... @include(if: $private) { name }
          ... @include(if: $public) { name } ... @include(if: $fileprivate) { name }
          ... @include(if: $open) { name } ... @include(if: $inout) { name }
          ... @include(if: $typealias) { name } ... @include(if: $associatedtype) { name }
          ... @include(if: $protocol) { name } ... @include(if: $some) { name }
          ... @include(if: $any) { name }
          ... @include(if: $rethrows) { name } ... @include(if: $fallthrough) { name }
          ... @include(if: $precedencegroup) { name } ... @include(if: $_) { name }
          # Swift's contextual keywords that start an expression or a type.
          ... @include(if: $async) { name } ... @include(if: $borrowing) { name }
          ... @include(if: $consume) { name } ... @include(if: $consuming) { name }
          ... @include(if: $copy) { name } ... @include(if: $discard) { name }
          ... @include(if: $each) { name } ... @include(if: $isolated) { name }
          ... @include(if: $sending) { name } ... @include(if: $then) { name }
          ... @include(if: $unsafe) { name } ... @include(if: $await) { name }
          # What every lens declares, and what a refetchable fragment and a connection add.
          ... @include(if: $anchor) { name } ... @include(if: $recordID) { name }
          ... @include(if: $typeName) { name } ... @include(if: $satisfied) { name }
          ... @include(if: $missingRequiredField) { name } ... @include(if: $fieldErrors) { name }
          ... @include(if: $isPresent) { name } ... @include(if: $throwing) { name }
          ... @include(if: $caught) { name } ... @include(if: $refetchable) { name }
          ... @include(if: $refetch) { name } ... @include(if: $connection) { name }
          ... @include(if: $nodes) { name } ... @include(if: $hasNext) { name }
          ... @include(if: $hasPrevious) { name } ... @include(if: $isLoadingNext) { name }
          ... @include(if: $isLoadingPrevious) { name } ... @include(if: $connectionID) { name }
          ... @include(if: $loadNext) { name } ... @include(if: $loadPrevious) { name }
          # The locals, parameters and local aliases of generated bodies.
          ... @include(if: $bound) { name } ... @include(if: $errors) { name }
          ... @include(if: $child) { name } ... @include(if: $missing) { name }
          ... @include(if: $count) { name } ... @include(if: $fields) { name }
          ... @include(if: $lhs) { name } ... @include(if: $rhs) { name }
          ... @include(if: $hasher) { name } ... @include(if: $optimistic) { name }
          ... @include(if: $selfValue) { name } ... @include(if: $Fragment) { name }
          ... @include(if: $Spread) { name } ... @include(if: $Owner) { name }
          ... @include(if: $Query) { name } ... @include(if: $Operation) { name }
          ... @include(if: $RefetchQuery) { name }
          # What an operation value, a mutation's action and its optimistic response declare.
          ... @include(if: $name) { name } ... @include(if: $persistedID) { name }
          ... @include(if: $text) { name } ... @include(if: $plan) { name }
          ... @include(if: $errorBehavior) { name } ... @include(if: $throwsOnFieldError) { name }
          ... @include(if: $bubbles) { name } ... @include(if: $hasDeferred) { name }
          ... @include(if: $Action) { name } ... @include(if: $OptimisticResponse) { name }
          ... @include(if: $hash) { name } ... @include(if: $commit) { name }
          ... @include(if: $callAsFunction) { name } ... @include(if: $Op) { name }
          ... @include(if: $variable) { name }
          # What the runtime's protocols give a generated type.
          ... @include(if: $retry) { name }
          ... @include(if: $subscription) { name }
          # The shared enums.
          ... @include(if: $AbstractSlots) { name } ... @include(if: $schemaDigest) { name }
          # The modules, and what the generated code spells from the standard library.
          ... @include(if: $Swift) { name } ... @include(if: $Set) { name }
          ... @include(if: $Result) { name } ... @include(if: $Optional) { name }
          ... @include(if: $String) { name } ... @include(if: $Int) { name }
          ... @include(if: $Double) { name } ... @include(if: $Bool) { name }
          ... @include(if: $MainActor) { name } ... @include(if: $Hasher) { name }
          ... @include(if: $Sendable) { name }
        }
        """)
    var arguments: HostileArguments_character

    /// Each name as a scalar and as a linked field of a mutation's payload: a
    /// property, a parameter and a local of the optimistic response's builder,
    /// and a nested builder of the name capitalized.
    @Mutation("""
        mutation HostilePayload {
          setFavorite(id: "1", favorite: true) {
            character {
              # Swift's keywords, as `escape` lists them.
              Type: name Protocol: name Any: name self: name Self: name init: name deinit: name
              subscript: name class: name struct: name enum: name func: name var: name let: name
              import: name extension: name operator: name static: name default: name case: name
              switch: name if: name else: name for: name in: name while: name repeat: name return: name
              break: name continue: name where: name is: name as: name try: name throw: name
              throws: name guard: name defer: name do: name catch: name true: name false: name nil: name
              super: name internal: name private: name public: name fileprivate: name open: name
              inout: name typealias: name associatedtype: name protocol: name some: name any: name
              rethrows: name fallthrough: name precedencegroup: name _: name
              # Swift's contextual keywords that start an expression or a type.
              async: name borrowing: name consume: name consuming: name copy: name discard: name
              each: name isolated: name sending: name then: name unsafe: name await: name
              # What every lens declares, and what a refetchable fragment and a connection add.
              typeName: name satisfied: name missingRequiredField: name fieldErrors: name
              isPresent: name throwing: name caught: name refetchable: name refetch: name
              connection: name nodes: name hasNext: name hasPrevious: name isLoadingNext: name
              isLoadingPrevious: name connectionID: name loadNext: name loadPrevious: name
              # The locals, parameters and local aliases of generated bodies.
              bound: name errors: name child: name missing: name count: name lhs: name rhs: name
              hasher: name optimistic: name selfValue: name Fragment: name Spread: name Owner: name
              Query: name Operation: name RefetchQuery: name fields: name
              # What an operation value, a mutation's action and its optimistic response declare.
              variables: name resolution: name name: name persistedID: name text: name plan: name
              errorBehavior: name throwsOnFieldError: name bubbles: name hasDeferred: name Data: name
              Action: name OptimisticResponse: name hash: name commit: name callAsFunction: name
              Op: name
              # What the runtime's protocols give a generated type.
              hashValue: name phase: name isRefreshing: name isStale: name retry: name
              subscription: name
              # The shared enums.
              Types: name Sites: name AbstractSlots: name schemaDigest: name
              # The modules, and what the generated code spells from the standard library.
              Baton: name Swift: name Set: name Result: name Optional: name String: name Int: name
              Double: name Bool: name MainActor: name Hasher: name Sendable: name
            }
          }
          addNote(characterId: "1", text: "hostile") {
            # Swift's keywords, as `escape` lists them.
            Type: note { id } Protocol: note { id } Any: note { id } self: note { id } Self: note { id }
            init: note { id } deinit: note { id } subscript: note { id } class: note { id }
            struct: note { id } enum: note { id } func: note { id } var: note { id } let: note { id }
            import: note { id } extension: note { id } operator: note { id } static: note { id }
            default: note { id } case: note { id } switch: note { id } if: note { id } else: note { id }
            for: note { id } in: note { id } while: note { id } repeat: note { id } return: note { id }
            break: note { id } continue: note { id } where: note { id } is: note { id } as: note { id }
            try: note { id } throw: note { id } throws: note { id } guard: note { id }
            defer: note { id } do: note { id } catch: note { id } true: note { id } false: note { id }
            nil: note { id } super: note { id } internal: note { id } private: note { id }
            public: note { id } fileprivate: note { id } open: note { id } inout: note { id }
            typealias: note { id } associatedtype: note { id } protocol: note { id } some: note { id }
            any: note { id }
            rethrows: note { id } fallthrough: note { id } precedencegroup: note { id }
            _: note { id }
            # Swift's contextual keywords that start an expression or a type.
            async: note { id } borrowing: note { id } consume: note { id } consuming: note { id }
            copy: note { id } discard: note { id } each: note { id } isolated: note { id }
            sending: note { id } then: note { id } unsafe: note { id } await: note { id }
            # What every lens declares, and what a refetchable fragment and a connection add.
            typeName: note { id } satisfied: note { id } missingRequiredField: note { id }
            fieldErrors: note { id } isPresent: note { id } throwing: note { id } caught: note { id }
            refetchable: note { id } refetch: note { id } connection: note { id } nodes: note { id }
            hasNext: note { id } hasPrevious: note { id } isLoadingNext: note { id }
            isLoadingPrevious: note { id } connectionID: note { id } loadNext: note { id }
            loadPrevious: note { id }
            # The locals, parameters and local aliases of generated bodies.
            bound: note { id } errors: note { id } child: note { id } missing: note { id }
            count: note { id } lhs: note { id } rhs: note { id } hasher: note { id }
            optimistic: note { id } selfValue: note { id } Fragment: note { id } Spread: note { id }
            Owner: note { id } Query: note { id } Operation: note { id } RefetchQuery: note { id }
            fields: note { id }
            # What an operation value, a mutation's action and its optimistic response declare.
            variables: note { id } resolution: note { id } name: note { id } persistedID: note { id }
            text: note { id } plan: note { id } errorBehavior: note { id }
            throwsOnFieldError: note { id } bubbles: note { id } hasDeferred: note { id }
            Data: note { id } Action: note { id } OptimisticResponse: note { id } hash: note { id }
            commit: note { id } callAsFunction: note { id } Op: note { id }
            # What the runtime's protocols give a generated type.
            hashValue: note { id } phase: note { id } isRefreshing: note { id } isStale: note { id }
            retry: note { id } subscription: note { id }
            # The shared enums.
            Types: note { id } Sites: note { id } AbstractSlots: note { id } schemaDigest: note { id }
            # The modules, and what the generated code spells from the standard library.
            Baton: note { id } Swift: note { id } Set: note { id } Result: note { id }
            Optional: note { id } String: note { id } Int: note { id } Double: note { id }
            Bool: note { id } MainActor: note { id } Hasher: note { id } Sendable: note { id }
          }
        }
        """)
    var payload: HostilePayload.Action
}

// Documents that use names Kotlin and the generated Kotlin keep for
// themselves, in every position a document's name can take inside a
// document: Kotlin's hard, soft and modifier keywords, what every lens and
// each kind of lens declares, the locals and lambda parameters of generated
// bodies, what an operation value, its companion and a mutation's action
// declare, what a class, a data class and an enum give, the shared objects,
// the runtime's names and what the generated code spells from the standard
// library and Compose. Each name stands as an aliased scalar, linked,
// caught and required field, an aliased selection and an aliased spread of
// a plain lens; as a field beside every kind of generated body, beside a
// connection's members, beside the checks of a required field that bubbles
// to the root, and on an interface; as a variable of a query, a mutation
// and a subscription, as a fragment's argument and as an argument a spread
// passes; as a scalar, a linked and a plural linked field of a mutation's
// payload; and as a scalar, a linked and a plural linked field and an
// aliased spread of an `@inline` fragment's value. A name the compiler
// refuses in a position, or that it accepts and writes Kotlin for that
// does not compile, is left out of that position;
// `compiler/src/tests/kotlin_hostile_tests.rs` lists both, and proves every
// other name is here. The name of a fragment or an operation is a class of
// the package, which the package holds once, so the sweep,
// `scripts/hostile-name-sweep-kotlin.py`, compiles those positions.
@file:Suppress("unused")

package baton.goldens.hostile

import baton.Fragment
import baton.Mutation
import baton.Query
import baton.Subscription

// Each name as an aliased scalar field of a plain lens.
@Fragment($$"""
    fragment KotlinScalars_character on Character {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: name break: name class: name continue: name do: name else: name false: name for: name
      fun: name if: name in: name interface: name is: name null: name object: name package: name
      return: name super: name this: name throw: name true: name try: name typealias: name
      typeof: name val: name var: name when: name while: name _: name
      # Kotlin's soft and modifier keywords.
      by: name catch: name constructor: name delegate: name dynamic: name field: name file: name
      finally: name get: name import: name init: name param: name property: name receiver: name
      set: name setparam: name value: name where: name abstract: name actual: name annotation: name
      companion: name const: name crossinline: name data: name enum: name expect: name
      external: name final: name infix: name inline: name inner: name internal: name lateinit: name
      noinline: name open: name operator: name out: name override: name private: name
      protected: name public: name reified: name sealed: name suspend: name tailrec: name
      vararg: name context: name
      # What every lens declares, and what a refetchable fragment and a connection add.
      satisfied: name missingRequiredField: name fieldErrors: name isPresent: name throwing: name
      caught: name refetchable: name refetch: name connection: name nodes: name hasNext: name
      hasPrevious: name isLoadingNext: name isLoadingPrevious: name connectionID: name
      loadNext: name loadPrevious: name
      # The locals, parameters and lambda parameters of generated bodies.
      bound: name errors: name child: name missing: name other: name it: name element: name
      count: name optimistic: name text: name fields: name
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      variables: name type: name resolution: name name: name document: name kind: name
      errorBehavior: name cacheExpirationSeconds: name throwsOnFieldError: name bubbles: name
      hasDeferred: name plan: name selection: name selection0: name Data: name Action: name
      OptimisticResponse: name invoke: name commit: name variable: name payload: name
      # What a class, a data class, an enum and a collection give.
      copy: name component1: name component2: name javaClass: name of: name scalarText: name
      Undeclared: name size: name keys: name values: name entries: name
      # The shared objects, and what they declare or spell.
      Types: name AbstractSlots: name Sites: name Guards: name schemaDigest: name format: name
      transient: name baton: name MappedScalar: name
      # The runtime's names generated code spells.
      AbstractSlot: name Anchor: name ArgumentSite: name ConnectionCursor: name ConnectionPlan: name
      ConnectionSlots: name Document: name DynamicKey: name Edit: name ErrorBehavior: name
      FieldError: name FieldErrors: name Generated: name GeneratedEnum: name Guard: name
      InputObject: name KeyArgument: name KeyPart: name Lens: name LensList: name Lookup: name
      Members: name MutationAction: name MutationOperation: name OperationHandle: name
      OperationKind: name OperationType: name QueryType: name MutationType: name SubscriptionType: name Payload: name Plan: name PlanField: name
      QueryOperation: name Refetch: name Registry: name Resolution: name ScalarKind: name
      Selection: name Slot: name StorageKey: name SubscriptionHandle: name
      SubscriptionOperation: name Transient: name TypeID: name Format1: name
      # What generated code spells from the standard library and Compose.
      Any: name Boolean: name Double: name Int: name List: name Long: name Map: name Pair: name
      Result: name String: name Unit: name Stable: name JvmName: name JvmField: name OptIn: name
      run: name let: name takeIf: name map: name lazy: name listOf: name mapOf: name emptyList: name
      emptyMap: name mutableListOf: name getOrThrow: name success: name failure: name
    }
    """)
fun KotlinScalars() {}

// Each name as an aliased linked field, whose nested lens takes the name
// capitalized.
@Fragment($$"""
    fragment KotlinLinks_character on Character {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: origin { id } break: origin { id } class: origin { id } continue: origin { id }
      do: origin { id } else: origin { id } false: origin { id } for: origin { id }
      fun: origin { id } if: origin { id } in: origin { id } interface: origin { id }
      is: origin { id } null: origin { id } object: origin { id } package: origin { id }
      return: origin { id } super: origin { id } this: origin { id } throw: origin { id }
      true: origin { id } try: origin { id } typealias: origin { id } typeof: origin { id }
      val: origin { id } var: origin { id } when: origin { id } while: origin { id }
      _: origin { id }
      # Kotlin's soft and modifier keywords.
      by: origin { id } catch: origin { id } constructor: origin { id } delegate: origin { id }
      dynamic: origin { id } field: origin { id } file: origin { id } finally: origin { id }
      get: origin { id } import: origin { id } init: origin { id } param: origin { id }
      property: origin { id } receiver: origin { id } set: origin { id } setparam: origin { id }
      value: origin { id } where: origin { id } abstract: origin { id } actual: origin { id }
      annotation: origin { id } companion: origin { id } const: origin { id }
      crossinline: origin { id } data: origin { id } enum: origin { id } expect: origin { id }
      external: origin { id } final: origin { id } infix: origin { id } inline: origin { id }
      inner: origin { id } internal: origin { id } lateinit: origin { id } noinline: origin { id }
      open: origin { id } operator: origin { id } out: origin { id } override: origin { id }
      private: origin { id } protected: origin { id } public: origin { id } reified: origin { id }
      sealed: origin { id } suspend: origin { id } tailrec: origin { id } vararg: origin { id }
      context: origin { id }
      # What every lens declares, and what a refetchable fragment and a connection add.
      satisfied: origin { id } missingRequiredField: origin { id } fieldErrors: origin { id }
      isPresent: origin { id } throwing: origin { id } caught: origin { id }
      refetchable: origin { id } refetch: origin { id } connection: origin { id }
      nodes: origin { id } hasNext: origin { id } hasPrevious: origin { id }
      isLoadingNext: origin { id } isLoadingPrevious: origin { id } connectionID: origin { id }
      loadNext: origin { id } loadPrevious: origin { id }
      # The locals, parameters and lambda parameters of generated bodies.
      bound: origin { id } errors: origin { id } child: origin { id } missing: origin { id }
      other: origin { id } it: origin { id } element: origin { id } count: origin { id }
      optimistic: origin { id } text: origin { id } fields: origin { id }
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      variables: origin { id } type: origin { id } resolution: origin { id } name: origin { id }
      document: origin { id } kind: origin { id } errorBehavior: origin { id }
      cacheExpirationSeconds: origin { id } throwsOnFieldError: origin { id } bubbles: origin { id }
      hasDeferred: origin { id } plan: origin { id } selection: origin { id }
      selection0: origin { id } Data: origin { id } Action: origin { id }
      OptimisticResponse: origin { id } invoke: origin { id } commit: origin { id }
      variable: origin { id } payload: origin { id }
      # What a class, a data class, an enum and a collection give.
      copy: origin { id } component1: origin { id } component2: origin { id }
      javaClass: origin { id } of: origin { id } scalarText: origin { id } Undeclared: origin { id }
      size: origin { id } keys: origin { id } values: origin { id } entries: origin { id }
      # The shared objects, and what they declare or spell.
      Types: origin { id } AbstractSlots: origin { id } Sites: origin { id } Guards: origin { id }
      schemaDigest: origin { id } format: origin { id } transient: origin { id }
      baton: origin { id } MappedScalar: origin { id }
      # The runtime's names generated code spells.
      AbstractSlot: origin { id } Anchor: origin { id } ArgumentSite: origin { id }
      ConnectionCursor: origin { id } ConnectionPlan: origin { id } ConnectionSlots: origin { id }
      Document: origin { id } DynamicKey: origin { id } Edit: origin { id }
      ErrorBehavior: origin { id } FieldError: origin { id } FieldErrors: origin { id }
      Generated: origin { id } GeneratedEnum: origin { id } Guard: origin { id }
      InputObject: origin { id } KeyArgument: origin { id } KeyPart: origin { id }
      Lens: origin { id } LensList: origin { id } Lookup: origin { id } Members: origin { id }
      MutationAction: origin { id } MutationOperation: origin { id } OperationHandle: origin { id }
      OperationKind: origin { id } OperationType: origin { id } QueryType: origin { id } MutationType: origin { id } SubscriptionType: origin { id } Payload: origin { id }
      Plan: origin { id } PlanField: origin { id } QueryOperation: origin { id }
      Refetch: origin { id } Registry: origin { id } Resolution: origin { id }
      ScalarKind: origin { id } Selection: origin { id } Slot: origin { id }
      StorageKey: origin { id } SubscriptionHandle: origin { id }
      SubscriptionOperation: origin { id } Transient: origin { id } TypeID: origin { id }
      Format1: origin { id }
      # What generated code spells from the standard library and Compose.
      Any: origin { id } Boolean: origin { id } Double: origin { id } Int: origin { id }
      List: origin { id } Long: origin { id } Map: origin { id } Pair: origin { id }
      Result: origin { id } String: origin { id } Unit: origin { id } Stable: origin { id }
      JvmName: origin { id } JvmField: origin { id } OptIn: origin { id } run: origin { id }
      let: origin { id } takeIf: origin { id } map: origin { id } lazy: origin { id }
      listOf: origin { id } mapOf: origin { id } emptyList: origin { id } emptyMap: origin { id }
      mutableListOf: origin { id } getOrThrow: origin { id } success: origin { id }
      failure: origin { id }
    }
    """)
fun KotlinLinks() {}

// Each name as an aliased selection, an accessor and a nested lens of the
// name.
@Fragment($$"""
    fragment KotlinSelections_character on Character {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      ... @alias(as: "as") { name } ... @alias(as: "break") { name }
      ... @alias(as: "class") { name } ... @alias(as: "continue") { name }
      ... @alias(as: "do") { name } ... @alias(as: "else") { name } ... @alias(as: "false") { name }
      ... @alias(as: "for") { name } ... @alias(as: "fun") { name } ... @alias(as: "if") { name }
      ... @alias(as: "in") { name } ... @alias(as: "interface") { name }
      ... @alias(as: "is") { name } ... @alias(as: "null") { name }
      ... @alias(as: "object") { name } ... @alias(as: "package") { name }
      ... @alias(as: "return") { name } ... @alias(as: "super") { name }
      ... @alias(as: "this") { name } ... @alias(as: "throw") { name }
      ... @alias(as: "true") { name } ... @alias(as: "try") { name }
      ... @alias(as: "typealias") { name } ... @alias(as: "typeof") { name }
      ... @alias(as: "val") { name } ... @alias(as: "var") { name } ... @alias(as: "when") { name }
      ... @alias(as: "while") { name } ... @alias(as: "_") { name }
      # Kotlin's soft and modifier keywords.
      ... @alias(as: "by") { name } ... @alias(as: "catch") { name }
      ... @alias(as: "constructor") { name } ... @alias(as: "delegate") { name }
      ... @alias(as: "dynamic") { name } ... @alias(as: "field") { name }
      ... @alias(as: "file") { name } ... @alias(as: "finally") { name }
      ... @alias(as: "get") { name } ... @alias(as: "import") { name }
      ... @alias(as: "init") { name } ... @alias(as: "param") { name }
      ... @alias(as: "property") { name } ... @alias(as: "receiver") { name }
      ... @alias(as: "set") { name } ... @alias(as: "setparam") { name }
      ... @alias(as: "value") { name } ... @alias(as: "where") { name }
      ... @alias(as: "abstract") { name } ... @alias(as: "actual") { name }
      ... @alias(as: "annotation") { name } ... @alias(as: "companion") { name }
      ... @alias(as: "const") { name } ... @alias(as: "crossinline") { name }
      ... @alias(as: "data") { name } ... @alias(as: "enum") { name }
      ... @alias(as: "expect") { name } ... @alias(as: "external") { name }
      ... @alias(as: "final") { name } ... @alias(as: "infix") { name }
      ... @alias(as: "inline") { name } ... @alias(as: "inner") { name }
      ... @alias(as: "internal") { name } ... @alias(as: "lateinit") { name }
      ... @alias(as: "noinline") { name } ... @alias(as: "open") { name }
      ... @alias(as: "operator") { name } ... @alias(as: "out") { name }
      ... @alias(as: "override") { name } ... @alias(as: "private") { name }
      ... @alias(as: "protected") { name } ... @alias(as: "public") { name }
      ... @alias(as: "reified") { name } ... @alias(as: "sealed") { name }
      ... @alias(as: "suspend") { name } ... @alias(as: "tailrec") { name }
      ... @alias(as: "vararg") { name } ... @alias(as: "context") { name }
      # What every lens declares, and what a refetchable fragment and a connection add.
      ... @alias(as: "satisfied") { name } ... @alias(as: "missingRequiredField") { name }
      ... @alias(as: "fieldErrors") { name } ... @alias(as: "isPresent") { name }
      ... @alias(as: "throwing") { name } ... @alias(as: "caught") { name }
      ... @alias(as: "refetchable") { name } ... @alias(as: "refetch") { name }
      ... @alias(as: "connection") { name } ... @alias(as: "nodes") { name }
      ... @alias(as: "hasNext") { name } ... @alias(as: "hasPrevious") { name }
      ... @alias(as: "isLoadingNext") { name } ... @alias(as: "isLoadingPrevious") { name }
      ... @alias(as: "connectionID") { name } ... @alias(as: "loadNext") { name }
      ... @alias(as: "loadPrevious") { name }
      # The locals, parameters and lambda parameters of generated bodies.
      ... @alias(as: "bound") { name } ... @alias(as: "errors") { name }
      ... @alias(as: "child") { name } ... @alias(as: "missing") { name }
      ... @alias(as: "other") { name } ... @alias(as: "it") { name }
      ... @alias(as: "element") { name } ... @alias(as: "count") { name }
      ... @alias(as: "optimistic") { name } ... @alias(as: "text") { name }
      ... @alias(as: "fields") { name }
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      ... @alias(as: "variables") { name } ... @alias(as: "type") { name }
      ... @alias(as: "resolution") { name } ... @alias(as: "name") { name }
      ... @alias(as: "document") { name } ... @alias(as: "kind") { name }
      ... @alias(as: "errorBehavior") { name } ... @alias(as: "cacheExpirationSeconds") { name }
      ... @alias(as: "throwsOnFieldError") { name } ... @alias(as: "bubbles") { name }
      ... @alias(as: "hasDeferred") { name } ... @alias(as: "plan") { name }
      ... @alias(as: "selection") { name } ... @alias(as: "selection0") { name }
      ... @alias(as: "Data") { name } ... @alias(as: "Action") { name }
      ... @alias(as: "OptimisticResponse") { name } ... @alias(as: "invoke") { name }
      ... @alias(as: "commit") { name } ... @alias(as: "variable") { name }
      ... @alias(as: "payload") { name }
      # What a class, a data class, an enum and a collection give.
      ... @alias(as: "copy") { name } ... @alias(as: "component1") { name }
      ... @alias(as: "component2") { name } ... @alias(as: "javaClass") { name }
      ... @alias(as: "of") { name } ... @alias(as: "scalarText") { name }
      ... @alias(as: "Undeclared") { name } ... @alias(as: "size") { name }
      ... @alias(as: "keys") { name } ... @alias(as: "values") { name }
      ... @alias(as: "entries") { name }
      # The shared objects, and what they declare or spell.
      ... @alias(as: "Types") { name } ... @alias(as: "AbstractSlots") { name }
      ... @alias(as: "Sites") { name } ... @alias(as: "Guards") { name }
      ... @alias(as: "schemaDigest") { name } ... @alias(as: "format") { name }
      ... @alias(as: "transient") { name } ... @alias(as: "baton") { name }
      ... @alias(as: "MappedScalar") { name }
      # The runtime's names generated code spells.
      ... @alias(as: "AbstractSlot") { name } ... @alias(as: "Anchor") { name }
      ... @alias(as: "ArgumentSite") { name } ... @alias(as: "ConnectionCursor") { name }
      ... @alias(as: "ConnectionPlan") { name } ... @alias(as: "ConnectionSlots") { name }
      ... @alias(as: "Document") { name } ... @alias(as: "DynamicKey") { name }
      ... @alias(as: "Edit") { name } ... @alias(as: "ErrorBehavior") { name }
      ... @alias(as: "FieldError") { name } ... @alias(as: "FieldErrors") { name }
      ... @alias(as: "Generated") { name } ... @alias(as: "GeneratedEnum") { name }
      ... @alias(as: "Guard") { name } ... @alias(as: "InputObject") { name }
      ... @alias(as: "KeyArgument") { name } ... @alias(as: "KeyPart") { name }
      ... @alias(as: "Lens") { name } ... @alias(as: "LensList") { name }
      ... @alias(as: "Lookup") { name } ... @alias(as: "Members") { name }
      ... @alias(as: "MutationAction") { name } ... @alias(as: "MutationOperation") { name }
      ... @alias(as: "OperationHandle") { name } ... @alias(as: "OperationKind") { name }
      ... @alias(as: "OperationType") { name } ... @alias(as: "QueryType") { name } ... @alias(as: "MutationType") { name } ... @alias(as: "SubscriptionType") { name } ... @alias(as: "Payload") { name }
      ... @alias(as: "Plan") { name } ... @alias(as: "PlanField") { name }
      ... @alias(as: "QueryOperation") { name } ... @alias(as: "Refetch") { name }
      ... @alias(as: "Registry") { name } ... @alias(as: "Resolution") { name }
      ... @alias(as: "ScalarKind") { name } ... @alias(as: "Selection") { name }
      ... @alias(as: "Slot") { name } ... @alias(as: "StorageKey") { name }
      ... @alias(as: "SubscriptionHandle") { name } ... @alias(as: "SubscriptionOperation") { name }
      ... @alias(as: "Transient") { name } ... @alias(as: "TypeID") { name }
      ... @alias(as: "Format1") { name }
      # What generated code spells from the standard library and Compose.
      ... @alias(as: "Any") { name } ... @alias(as: "Boolean") { name }
      ... @alias(as: "Double") { name } ... @alias(as: "Int") { name }
      ... @alias(as: "List") { name } ... @alias(as: "Long") { name } ... @alias(as: "Map") { name }
      ... @alias(as: "Pair") { name } ... @alias(as: "Result") { name }
      ... @alias(as: "String") { name } ... @alias(as: "Unit") { name }
      ... @alias(as: "Stable") { name } ... @alias(as: "JvmName") { name }
      ... @alias(as: "JvmField") { name } ... @alias(as: "OptIn") { name }
      ... @alias(as: "run") { name } ... @alias(as: "let") { name }
      ... @alias(as: "takeIf") { name } ... @alias(as: "map") { name }
      ... @alias(as: "lazy") { name } ... @alias(as: "listOf") { name }
      ... @alias(as: "mapOf") { name } ... @alias(as: "emptyList") { name }
      ... @alias(as: "emptyMap") { name } ... @alias(as: "mutableListOf") { name }
      ... @alias(as: "getOrThrow") { name } ... @alias(as: "success") { name }
      ... @alias(as: "failure") { name }
    }
    """)
fun KotlinSelections() {}

// The fragment the aliased spreads spread.
@Fragment($$"""
    fragment KotlinSpreadTarget_character on Character {
      name
    }
    """)
fun KotlinSpreadTarget() {}

// Each name as an aliased spread, an accessor of the name that builds a
// fragment's lens.
@Fragment($$"""
    fragment KotlinSpreads_character on Character {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      ... @alias(as: "as") { ...KotlinSpreadTarget_character }
      ... @alias(as: "break") { ...KotlinSpreadTarget_character }
      ... @alias(as: "class") { ...KotlinSpreadTarget_character }
      ... @alias(as: "continue") { ...KotlinSpreadTarget_character }
      ... @alias(as: "do") { ...KotlinSpreadTarget_character }
      ... @alias(as: "else") { ...KotlinSpreadTarget_character }
      ... @alias(as: "false") { ...KotlinSpreadTarget_character }
      ... @alias(as: "for") { ...KotlinSpreadTarget_character }
      ... @alias(as: "fun") { ...KotlinSpreadTarget_character }
      ... @alias(as: "if") { ...KotlinSpreadTarget_character }
      ... @alias(as: "in") { ...KotlinSpreadTarget_character }
      ... @alias(as: "interface") { ...KotlinSpreadTarget_character }
      ... @alias(as: "is") { ...KotlinSpreadTarget_character }
      ... @alias(as: "null") { ...KotlinSpreadTarget_character }
      ... @alias(as: "object") { ...KotlinSpreadTarget_character }
      ... @alias(as: "package") { ...KotlinSpreadTarget_character }
      ... @alias(as: "return") { ...KotlinSpreadTarget_character }
      ... @alias(as: "super") { ...KotlinSpreadTarget_character }
      ... @alias(as: "this") { ...KotlinSpreadTarget_character }
      ... @alias(as: "throw") { ...KotlinSpreadTarget_character }
      ... @alias(as: "true") { ...KotlinSpreadTarget_character }
      ... @alias(as: "try") { ...KotlinSpreadTarget_character }
      ... @alias(as: "typealias") { ...KotlinSpreadTarget_character }
      ... @alias(as: "typeof") { ...KotlinSpreadTarget_character }
      ... @alias(as: "val") { ...KotlinSpreadTarget_character }
      ... @alias(as: "var") { ...KotlinSpreadTarget_character }
      ... @alias(as: "when") { ...KotlinSpreadTarget_character }
      ... @alias(as: "while") { ...KotlinSpreadTarget_character }
      ... @alias(as: "_") { ...KotlinSpreadTarget_character }
      # Kotlin's soft and modifier keywords.
      ... @alias(as: "by") { ...KotlinSpreadTarget_character }
      ... @alias(as: "catch") { ...KotlinSpreadTarget_character }
      ... @alias(as: "constructor") { ...KotlinSpreadTarget_character }
      ... @alias(as: "delegate") { ...KotlinSpreadTarget_character }
      ... @alias(as: "dynamic") { ...KotlinSpreadTarget_character }
      ... @alias(as: "field") { ...KotlinSpreadTarget_character }
      ... @alias(as: "file") { ...KotlinSpreadTarget_character }
      ... @alias(as: "finally") { ...KotlinSpreadTarget_character }
      ... @alias(as: "get") { ...KotlinSpreadTarget_character }
      ... @alias(as: "import") { ...KotlinSpreadTarget_character }
      ... @alias(as: "init") { ...KotlinSpreadTarget_character }
      ... @alias(as: "param") { ...KotlinSpreadTarget_character }
      ... @alias(as: "property") { ...KotlinSpreadTarget_character }
      ... @alias(as: "receiver") { ...KotlinSpreadTarget_character }
      ... @alias(as: "set") { ...KotlinSpreadTarget_character }
      ... @alias(as: "setparam") { ...KotlinSpreadTarget_character }
      ... @alias(as: "value") { ...KotlinSpreadTarget_character }
      ... @alias(as: "where") { ...KotlinSpreadTarget_character }
      ... @alias(as: "abstract") { ...KotlinSpreadTarget_character }
      ... @alias(as: "actual") { ...KotlinSpreadTarget_character }
      ... @alias(as: "annotation") { ...KotlinSpreadTarget_character }
      ... @alias(as: "companion") { ...KotlinSpreadTarget_character }
      ... @alias(as: "const") { ...KotlinSpreadTarget_character }
      ... @alias(as: "crossinline") { ...KotlinSpreadTarget_character }
      ... @alias(as: "data") { ...KotlinSpreadTarget_character }
      ... @alias(as: "enum") { ...KotlinSpreadTarget_character }
      ... @alias(as: "expect") { ...KotlinSpreadTarget_character }
      ... @alias(as: "external") { ...KotlinSpreadTarget_character }
      ... @alias(as: "final") { ...KotlinSpreadTarget_character }
      ... @alias(as: "infix") { ...KotlinSpreadTarget_character }
      ... @alias(as: "inline") { ...KotlinSpreadTarget_character }
      ... @alias(as: "inner") { ...KotlinSpreadTarget_character }
      ... @alias(as: "internal") { ...KotlinSpreadTarget_character }
      ... @alias(as: "lateinit") { ...KotlinSpreadTarget_character }
      ... @alias(as: "noinline") { ...KotlinSpreadTarget_character }
      ... @alias(as: "open") { ...KotlinSpreadTarget_character }
      ... @alias(as: "operator") { ...KotlinSpreadTarget_character }
      ... @alias(as: "out") { ...KotlinSpreadTarget_character }
      ... @alias(as: "override") { ...KotlinSpreadTarget_character }
      ... @alias(as: "private") { ...KotlinSpreadTarget_character }
      ... @alias(as: "protected") { ...KotlinSpreadTarget_character }
      ... @alias(as: "public") { ...KotlinSpreadTarget_character }
      ... @alias(as: "reified") { ...KotlinSpreadTarget_character }
      ... @alias(as: "sealed") { ...KotlinSpreadTarget_character }
      ... @alias(as: "suspend") { ...KotlinSpreadTarget_character }
      ... @alias(as: "tailrec") { ...KotlinSpreadTarget_character }
      ... @alias(as: "vararg") { ...KotlinSpreadTarget_character }
      ... @alias(as: "context") { ...KotlinSpreadTarget_character }
      # What every lens declares, and what a refetchable fragment and a connection add.
      ... @alias(as: "satisfied") { ...KotlinSpreadTarget_character }
      ... @alias(as: "missingRequiredField") { ...KotlinSpreadTarget_character }
      ... @alias(as: "fieldErrors") { ...KotlinSpreadTarget_character }
      ... @alias(as: "isPresent") { ...KotlinSpreadTarget_character }
      ... @alias(as: "throwing") { ...KotlinSpreadTarget_character }
      ... @alias(as: "caught") { ...KotlinSpreadTarget_character }
      ... @alias(as: "refetchable") { ...KotlinSpreadTarget_character }
      ... @alias(as: "refetch") { ...KotlinSpreadTarget_character }
      ... @alias(as: "connection") { ...KotlinSpreadTarget_character }
      ... @alias(as: "nodes") { ...KotlinSpreadTarget_character }
      ... @alias(as: "hasNext") { ...KotlinSpreadTarget_character }
      ... @alias(as: "hasPrevious") { ...KotlinSpreadTarget_character }
      ... @alias(as: "isLoadingNext") { ...KotlinSpreadTarget_character }
      ... @alias(as: "isLoadingPrevious") { ...KotlinSpreadTarget_character }
      ... @alias(as: "connectionID") { ...KotlinSpreadTarget_character }
      ... @alias(as: "loadNext") { ...KotlinSpreadTarget_character }
      ... @alias(as: "loadPrevious") { ...KotlinSpreadTarget_character }
      # The locals, parameters and lambda parameters of generated bodies.
      ... @alias(as: "bound") { ...KotlinSpreadTarget_character }
      ... @alias(as: "errors") { ...KotlinSpreadTarget_character }
      ... @alias(as: "child") { ...KotlinSpreadTarget_character }
      ... @alias(as: "missing") { ...KotlinSpreadTarget_character }
      ... @alias(as: "other") { ...KotlinSpreadTarget_character }
      ... @alias(as: "it") { ...KotlinSpreadTarget_character }
      ... @alias(as: "element") { ...KotlinSpreadTarget_character }
      ... @alias(as: "count") { ...KotlinSpreadTarget_character }
      ... @alias(as: "optimistic") { ...KotlinSpreadTarget_character }
      ... @alias(as: "text") { ...KotlinSpreadTarget_character }
      ... @alias(as: "fields") { ...KotlinSpreadTarget_character }
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      ... @alias(as: "variables") { ...KotlinSpreadTarget_character }
      ... @alias(as: "type") { ...KotlinSpreadTarget_character }
      ... @alias(as: "resolution") { ...KotlinSpreadTarget_character }
      ... @alias(as: "name") { ...KotlinSpreadTarget_character }
      ... @alias(as: "document") { ...KotlinSpreadTarget_character }
      ... @alias(as: "kind") { ...KotlinSpreadTarget_character }
      ... @alias(as: "errorBehavior") { ...KotlinSpreadTarget_character }
      ... @alias(as: "cacheExpirationSeconds") { ...KotlinSpreadTarget_character }
      ... @alias(as: "throwsOnFieldError") { ...KotlinSpreadTarget_character }
      ... @alias(as: "bubbles") { ...KotlinSpreadTarget_character }
      ... @alias(as: "hasDeferred") { ...KotlinSpreadTarget_character }
      ... @alias(as: "plan") { ...KotlinSpreadTarget_character }
      ... @alias(as: "selection") { ...KotlinSpreadTarget_character }
      ... @alias(as: "selection0") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Data") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Action") { ...KotlinSpreadTarget_character }
      ... @alias(as: "OptimisticResponse") { ...KotlinSpreadTarget_character }
      ... @alias(as: "invoke") { ...KotlinSpreadTarget_character }
      ... @alias(as: "commit") { ...KotlinSpreadTarget_character }
      ... @alias(as: "variable") { ...KotlinSpreadTarget_character }
      ... @alias(as: "payload") { ...KotlinSpreadTarget_character }
      # What a class, a data class, an enum and a collection give.
      ... @alias(as: "copy") { ...KotlinSpreadTarget_character }
      ... @alias(as: "component1") { ...KotlinSpreadTarget_character }
      ... @alias(as: "component2") { ...KotlinSpreadTarget_character }
      ... @alias(as: "javaClass") { ...KotlinSpreadTarget_character }
      ... @alias(as: "of") { ...KotlinSpreadTarget_character }
      ... @alias(as: "scalarText") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Undeclared") { ...KotlinSpreadTarget_character }
      ... @alias(as: "size") { ...KotlinSpreadTarget_character }
      ... @alias(as: "keys") { ...KotlinSpreadTarget_character }
      ... @alias(as: "values") { ...KotlinSpreadTarget_character }
      ... @alias(as: "entries") { ...KotlinSpreadTarget_character }
      # The shared objects, and what they declare or spell.
      ... @alias(as: "Types") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Slots") { ...KotlinSpreadTarget_character }
      ... @alias(as: "AbstractSlots") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Sites") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Guards") { ...KotlinSpreadTarget_character }
      ... @alias(as: "schemaDigest") { ...KotlinSpreadTarget_character }
      ... @alias(as: "format") { ...KotlinSpreadTarget_character }
      ... @alias(as: "transient") { ...KotlinSpreadTarget_character }
      ... @alias(as: "baton") { ...KotlinSpreadTarget_character }
      ... @alias(as: "MappedScalar") { ...KotlinSpreadTarget_character }
      # The runtime's names generated code spells.
      ... @alias(as: "AbstractSlot") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Anchor") { ...KotlinSpreadTarget_character }
      ... @alias(as: "ArgumentSite") { ...KotlinSpreadTarget_character }
      ... @alias(as: "ConnectionCursor") { ...KotlinSpreadTarget_character }
      ... @alias(as: "ConnectionPlan") { ...KotlinSpreadTarget_character }
      ... @alias(as: "ConnectionSlots") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Document") { ...KotlinSpreadTarget_character }
      ... @alias(as: "DynamicKey") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Edit") { ...KotlinSpreadTarget_character }
      ... @alias(as: "ErrorBehavior") { ...KotlinSpreadTarget_character }
      ... @alias(as: "FieldError") { ...KotlinSpreadTarget_character }
      ... @alias(as: "FieldErrors") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Generated") { ...KotlinSpreadTarget_character }
      ... @alias(as: "GeneratedEnum") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Guard") { ...KotlinSpreadTarget_character }
      ... @alias(as: "InputObject") { ...KotlinSpreadTarget_character }
      ... @alias(as: "KeyArgument") { ...KotlinSpreadTarget_character }
      ... @alias(as: "KeyPart") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Lens") { ...KotlinSpreadTarget_character }
      ... @alias(as: "LensList") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Lookup") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Members") { ...KotlinSpreadTarget_character }
      ... @alias(as: "MutationAction") { ...KotlinSpreadTarget_character }
      ... @alias(as: "MutationOperation") { ...KotlinSpreadTarget_character }
      ... @alias(as: "OperationHandle") { ...KotlinSpreadTarget_character }
      ... @alias(as: "OperationKind") { ...KotlinSpreadTarget_character }
      ... @alias(as: "OperationType") { ...KotlinSpreadTarget_character } ... @alias(as: "QueryType") { ...KotlinSpreadTarget_character } ... @alias(as: "MutationType") { ...KotlinSpreadTarget_character } ... @alias(as: "SubscriptionType") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Payload") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Plan") { ...KotlinSpreadTarget_character }
      ... @alias(as: "PlanField") { ...KotlinSpreadTarget_character }
      ... @alias(as: "QueryOperation") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Refetch") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Registry") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Resolution") { ...KotlinSpreadTarget_character }
      ... @alias(as: "ScalarKind") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Selection") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Slot") { ...KotlinSpreadTarget_character }
      ... @alias(as: "StorageKey") { ...KotlinSpreadTarget_character }
      ... @alias(as: "SubscriptionHandle") { ...KotlinSpreadTarget_character }
      ... @alias(as: "SubscriptionOperation") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Transient") { ...KotlinSpreadTarget_character }
      ... @alias(as: "TypeID") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Format1") { ...KotlinSpreadTarget_character }
      # What generated code spells from the standard library and Compose.
      ... @alias(as: "Any") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Boolean") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Double") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Int") { ...KotlinSpreadTarget_character }
      ... @alias(as: "List") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Long") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Map") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Pair") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Result") { ...KotlinSpreadTarget_character }
      ... @alias(as: "String") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Unit") { ...KotlinSpreadTarget_character }
      ... @alias(as: "Stable") { ...KotlinSpreadTarget_character }
      ... @alias(as: "JvmName") { ...KotlinSpreadTarget_character }
      ... @alias(as: "JvmField") { ...KotlinSpreadTarget_character }
      ... @alias(as: "OptIn") { ...KotlinSpreadTarget_character }
      ... @alias(as: "run") { ...KotlinSpreadTarget_character }
      ... @alias(as: "let") { ...KotlinSpreadTarget_character }
      ... @alias(as: "takeIf") { ...KotlinSpreadTarget_character }
      ... @alias(as: "map") { ...KotlinSpreadTarget_character }
      ... @alias(as: "lazy") { ...KotlinSpreadTarget_character }
      ... @alias(as: "listOf") { ...KotlinSpreadTarget_character }
      ... @alias(as: "mapOf") { ...KotlinSpreadTarget_character }
      ... @alias(as: "emptyList") { ...KotlinSpreadTarget_character }
      ... @alias(as: "emptyMap") { ...KotlinSpreadTarget_character }
      ... @alias(as: "mutableListOf") { ...KotlinSpreadTarget_character }
      ... @alias(as: "getOrThrow") { ...KotlinSpreadTarget_character }
      ... @alias(as: "success") { ...KotlinSpreadTarget_character }
      ... @alias(as: "failure") { ...KotlinSpreadTarget_character }
    }
    """)
fun KotlinSpreads() {}

// The fragments the lens with every kind of body spreads.
@Fragment($$"""
    fragment KotlinBound_character on Character
    @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) {
      name @include(if: $flag)
      origin @required(action: NONE) { id }
    }
    """)
fun KotlinBound() {}

@Fragment($$"""
    fragment KotlinDeferred_character on Character {
      name
    }
    """)
fun KotlinDeferred() {}

@Fragment($$"""
    fragment KotlinCaughtTarget_character on Character {
      name
    }
    """)
fun KotlinCaughtTarget() {}

// Each name as a field of a lens with every kind of generated body: the
// checks of `@throwOnFieldError` and `@required`, a throwing accessor,
// `refetch()`, and spreads that bind arguments, wait for a deferred part
// and catch field errors.
@Fragment($$"""
    fragment KotlinBodies_character on Character
    @refetchable(queryName: "KotlinBodiesRefetchQuery")
    @throwOnFieldError {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: name break: name class: name continue: name do: name else: name false: name for: name
      fun: name if: name in: name interface: name is: name null: name object: name package: name
      return: name super: name this: name throw: name true: name try: name typealias: name
      typeof: name val: name var: name when: name while: name _: name
      # Kotlin's soft and modifier keywords.
      by: name catch: name constructor: name delegate: name dynamic: name field: name file: name
      finally: name get: name import: name init: name param: name property: name receiver: name
      set: name setparam: name value: name where: name abstract: name actual: name annotation: name
      companion: name const: name crossinline: name data: name enum: name expect: name
      external: name final: name infix: name inline: name inner: name internal: name lateinit: name
      noinline: name open: name operator: name out: name override: name private: name
      protected: name public: name reified: name sealed: name suspend: name tailrec: name
      vararg: name context: name
      # What every lens declares, and what a refetchable fragment and a connection add.
      satisfied: name missingRequiredField: name fieldErrors: name isPresent: name throwing: name
      caught: name refetchable: name refetch: name connection: name nodes: name hasNext: name
      hasPrevious: name isLoadingNext: name isLoadingPrevious: name connectionID: name
      loadNext: name loadPrevious: name
      # The locals, parameters and lambda parameters of generated bodies.
      bound: name errors: name child: name missing: name other: name it: name element: name
      count: name optimistic: name text: name fields: name
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      variables: name type: name resolution: name name: name document: name kind: name
      errorBehavior: name cacheExpirationSeconds: name throwsOnFieldError: name bubbles: name
      hasDeferred: name plan: name selection: name selection0: name Data: name Action: name
      OptimisticResponse: name invoke: name commit: name variable: name payload: name
      # What a class, a data class, an enum and a collection give.
      copy: name component1: name component2: name javaClass: name of: name scalarText: name
      Undeclared: name size: name keys: name values: name entries: name
      # The shared objects, and what they declare or spell.
      AbstractSlots: name Guards: name schemaDigest: name format: name transient: name baton: name
      MappedScalar: name
      # The runtime's names generated code spells.
      AbstractSlot: name Anchor: name ArgumentSite: name ConnectionCursor: name ConnectionPlan: name
      ConnectionSlots: name Document: name DynamicKey: name Edit: name ErrorBehavior: name
      FieldError: name FieldErrors: name Generated: name GeneratedEnum: name Guard: name
      InputObject: name KeyArgument: name KeyPart: name Lens: name LensList: name Lookup: name
      Members: name MutationAction: name MutationOperation: name OperationHandle: name
      OperationKind: name OperationType: name QueryType: name MutationType: name SubscriptionType: name Payload: name Plan: name PlanField: name
      QueryOperation: name Refetch: name Registry: name Resolution: name ScalarKind: name
      Selection: name Slot: name StorageKey: name SubscriptionHandle: name
      SubscriptionOperation: name Transient: name TypeID: name Format1: name
      # What generated code spells from the standard library and Compose.
      Any: name Boolean: name Double: name Int: name List: name Long: name Map: name Pair: name
      Result: name String: name Unit: name Stable: name JvmName: name JvmField: name OptIn: name
      run: name let: name takeIf: name map: name lazy: name listOf: name mapOf: name emptyList: name
      emptyMap: name mutableListOf: name getOrThrow: name success: name failure: name
      # What gives the lens its bodies.
      species @required(action: THROW)
      origin @required(action: NONE) { name @required(action: NONE) }
      ...KotlinBound_character @arguments(flag: false)
      ...KotlinDeferred_character @defer
      ... @alias(as: "caughtSpread") @catch { ...KotlinCaughtTarget_character }
    }
    """)
fun KotlinBodies() {}

// Each name as a field of a connection's lens, beside its state, `nodes`
// and the pagination.
@Fragment($$"""
    fragment KotlinConnection_character on Character
    @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"})
    @refetchable(queryName: "KotlinConnectionRefetchQuery") {
      notes(first: $count, after: $cursor) @connection(key: "KotlinConnection_notes") {
          # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
          as: totalCount break: totalCount class: totalCount continue: totalCount do: totalCount
          else: totalCount false: totalCount for: totalCount fun: totalCount if: totalCount
          in: totalCount interface: totalCount is: totalCount null: totalCount object: totalCount
          package: totalCount return: totalCount super: totalCount this: totalCount
          throw: totalCount true: totalCount try: totalCount typealias: totalCount
          typeof: totalCount val: totalCount var: totalCount when: totalCount while: totalCount
          _: totalCount
          # Kotlin's soft and modifier keywords.
          by: totalCount catch: totalCount constructor: totalCount delegate: totalCount
          dynamic: totalCount field: totalCount file: totalCount finally: totalCount get: totalCount
          import: totalCount init: totalCount param: totalCount property: totalCount
          receiver: totalCount set: totalCount setparam: totalCount value: totalCount
          where: totalCount abstract: totalCount actual: totalCount annotation: totalCount
          companion: totalCount const: totalCount crossinline: totalCount data: totalCount
          enum: totalCount expect: totalCount external: totalCount final: totalCount
          infix: totalCount inline: totalCount inner: totalCount internal: totalCount
          lateinit: totalCount noinline: totalCount open: totalCount operator: totalCount
          out: totalCount override: totalCount private: totalCount protected: totalCount
          public: totalCount reified: totalCount sealed: totalCount suspend: totalCount
          tailrec: totalCount vararg: totalCount context: totalCount
          # What every lens declares, and what a refetchable fragment and a connection add.
          satisfied: totalCount missingRequiredField: totalCount fieldErrors: totalCount
          isPresent: totalCount throwing: totalCount caught: totalCount refetchable: totalCount
          refetch: totalCount connection: totalCount nodes: totalCount loadNext: totalCount
          loadPrevious: totalCount
          # The locals, parameters and lambda parameters of generated bodies.
          bound: totalCount errors: totalCount child: totalCount missing: totalCount
          other: totalCount it: totalCount element: totalCount count: totalCount
          optimistic: totalCount text: totalCount fields: totalCount
          # What an operation value, its companion, a mutation's action and its optimistic response declare.
          variables: totalCount type: totalCount resolution: totalCount name: totalCount
          document: totalCount kind: totalCount errorBehavior: totalCount
          cacheExpirationSeconds: totalCount throwsOnFieldError: totalCount bubbles: totalCount
          hasDeferred: totalCount plan: totalCount selection: totalCount selection0: totalCount
          Data: totalCount Action: totalCount OptimisticResponse: totalCount invoke: totalCount
          commit: totalCount variable: totalCount payload: totalCount
          # What a class, a data class, an enum and a collection give.
          copy: totalCount component1: totalCount component2: totalCount javaClass: totalCount
          of: totalCount scalarText: totalCount Undeclared: totalCount size: totalCount
          keys: totalCount values: totalCount entries: totalCount
          # The shared objects, and what they declare or spell.
          AbstractSlots: totalCount Sites: totalCount Guards: totalCount schemaDigest: totalCount
          format: totalCount transient: totalCount baton: totalCount MappedScalar: totalCount
          # The runtime's names generated code spells.
          AbstractSlot: totalCount Anchor: totalCount ArgumentSite: totalCount
          ConnectionCursor: totalCount ConnectionPlan: totalCount ConnectionSlots: totalCount
          Document: totalCount DynamicKey: totalCount Edit: totalCount ErrorBehavior: totalCount
          FieldError: totalCount FieldErrors: totalCount Generated: totalCount
          GeneratedEnum: totalCount Guard: totalCount InputObject: totalCount
          KeyArgument: totalCount KeyPart: totalCount Lens: totalCount LensList: totalCount
          Lookup: totalCount Members: totalCount MutationAction: totalCount
          MutationOperation: totalCount OperationHandle: totalCount OperationKind: totalCount
          OperationType: totalCount QueryType: totalCount MutationType: totalCount SubscriptionType: totalCount Payload: totalCount Plan: totalCount PlanField: totalCount
          QueryOperation: totalCount Refetch: totalCount Registry: totalCount Resolution: totalCount
          ScalarKind: totalCount Selection: totalCount Slot: totalCount StorageKey: totalCount
          SubscriptionHandle: totalCount SubscriptionOperation: totalCount Transient: totalCount
          TypeID: totalCount Format1: totalCount
          # What generated code spells from the standard library and Compose.
          Any: totalCount Boolean: totalCount Double: totalCount Int: totalCount List: totalCount
          Long: totalCount Map: totalCount Pair: totalCount Result: totalCount String: totalCount
          Unit: totalCount Stable: totalCount JvmName: totalCount JvmField: totalCount
          OptIn: totalCount run: totalCount let: totalCount takeIf: totalCount map: totalCount
          lazy: totalCount listOf: totalCount mapOf: totalCount emptyList: totalCount
          emptyMap: totalCount mutableListOf: totalCount getOrThrow: totalCount success: totalCount
          failure: totalCount
        edges { node { id } }
      }
    }
    """)
fun KotlinConnection() {}

// Each name as a field of a lens whose required field bubbles to the root,
// whose checks read a link as `child` and report the field that is
// `missing`.
@Query($$"""
    query KotlinRequired {
      character(id: 1) @required(action: NONE) {
          # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
          as: name break: name class: name continue: name do: name else: name false: name for: name
          fun: name if: name in: name interface: name is: name null: name object: name package: name
          return: name super: name this: name throw: name true: name try: name typealias: name
          typeof: name val: name var: name when: name while: name _: name
          # Kotlin's soft and modifier keywords.
          by: name catch: name constructor: name delegate: name dynamic: name field: name file: name
          finally: name get: name import: name init: name param: name property: name receiver: name
          set: name setparam: name value: name where: name abstract: name actual: name
          annotation: name companion: name const: name crossinline: name data: name enum: name
          expect: name external: name final: name infix: name inline: name inner: name
          internal: name lateinit: name noinline: name open: name operator: name out: name
          override: name private: name protected: name public: name reified: name sealed: name
          suspend: name tailrec: name vararg: name context: name
          # What every lens declares, and what a refetchable fragment and a connection add.
          satisfied: name missingRequiredField: name fieldErrors: name isPresent: name
          throwing: name caught: name refetchable: name refetch: name connection: name nodes: name
          hasNext: name hasPrevious: name isLoadingNext: name isLoadingPrevious: name
          connectionID: name loadNext: name loadPrevious: name
          # The locals, parameters and lambda parameters of generated bodies.
          bound: name errors: name child: name missing: name other: name it: name element: name
          count: name optimistic: name text: name fields: name
          # What an operation value, its companion, a mutation's action and its optimistic response declare.
          variables: name type: name resolution: name name: name document: name kind: name
          errorBehavior: name cacheExpirationSeconds: name throwsOnFieldError: name bubbles: name
          hasDeferred: name plan: name selection: name selection0: name Data: name Action: name
          OptimisticResponse: name invoke: name commit: name variable: name payload: name
          # What a class, a data class, an enum and a collection give.
          copy: name component1: name component2: name javaClass: name of: name scalarText: name
          Undeclared: name size: name keys: name values: name entries: name
          # The shared objects, and what they declare or spell.
          AbstractSlots: name Sites: name Guards: name schemaDigest: name format: name
          transient: name baton: name MappedScalar: name
          # The runtime's names generated code spells.
          AbstractSlot: name Anchor: name ArgumentSite: name ConnectionCursor: name
          ConnectionPlan: name ConnectionSlots: name Document: name DynamicKey: name Edit: name
          ErrorBehavior: name FieldError: name FieldErrors: name Generated: name GeneratedEnum: name
          Guard: name InputObject: name KeyArgument: name KeyPart: name Lens: name LensList: name
          Lookup: name Members: name MutationAction: name MutationOperation: name
          OperationHandle: name OperationKind: name OperationType: name QueryType: name MutationType: name SubscriptionType: name Payload: name Plan: name
          PlanField: name QueryOperation: name Refetch: name Registry: name Resolution: name
          ScalarKind: name Selection: name Slot: name StorageKey: name SubscriptionHandle: name
          SubscriptionOperation: name Transient: name TypeID: name Format1: name
          # What generated code spells from the standard library and Compose.
          Any: name Boolean: name Double: name Int: name List: name Long: name Map: name Pair: name
          Result: name String: name Unit: name Stable: name JvmName: name JvmField: name OptIn: name
          run: name let: name takeIf: name map: name lazy: name listOf: name mapOf: name
          emptyList: name emptyMap: name mutableListOf: name getOrThrow: name success: name
          failure: name
        origin @required(action: NONE) { name @required(action: NONE) }
      }
    }
    """)
fun KotlinRequired() {}

// Each name as a field of a lens on an interface, which reads its slots on
// the record's type and tests the record against a type condition.
@Fragment($$"""
    fragment KotlinAbstract_node on Node {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: id break: id class: id continue: id do: id else: id false: id for: id fun: id if: id
      in: id interface: id is: id null: id object: id package: id return: id super: id this: id
      throw: id true: id try: id typealias: id typeof: id val: id var: id when: id while: id _: id
      # Kotlin's soft and modifier keywords.
      by: id catch: id constructor: id delegate: id dynamic: id field: id file: id finally: id
      get: id import: id init: id param: id property: id receiver: id set: id setparam: id value: id
      where: id abstract: id actual: id annotation: id companion: id const: id crossinline: id
      data: id enum: id expect: id external: id final: id infix: id inline: id inner: id
      internal: id lateinit: id noinline: id open: id operator: id out: id override: id private: id
      protected: id public: id reified: id sealed: id suspend: id tailrec: id vararg: id context: id
      # What every lens declares, and what a refetchable fragment and a connection add.
      satisfied: id missingRequiredField: id fieldErrors: id isPresent: id throwing: id caught: id
      refetchable: id refetch: id connection: id nodes: id hasNext: id hasPrevious: id
      isLoadingNext: id isLoadingPrevious: id connectionID: id loadNext: id loadPrevious: id
      # The locals, parameters and lambda parameters of generated bodies.
      bound: id errors: id child: id missing: id other: id it: id element: id count: id
      optimistic: id text: id fields: id
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      variables: id type: id resolution: id name: id document: id kind: id errorBehavior: id
      cacheExpirationSeconds: id throwsOnFieldError: id bubbles: id hasDeferred: id plan: id
      selection: id selection0: id Data: id Action: id OptimisticResponse: id invoke: id commit: id
      variable: id payload: id
      # What a class, a data class, an enum and a collection give.
      copy: id component1: id component2: id javaClass: id of: id scalarText: id Undeclared: id
      size: id keys: id values: id entries: id
      # The shared objects, and what they declare or spell.
      Sites: id Guards: id schemaDigest: id format: id transient: id baton: id MappedScalar: id
      # The runtime's names generated code spells.
      AbstractSlot: id Anchor: id ArgumentSite: id ConnectionCursor: id ConnectionPlan: id
      ConnectionSlots: id Document: id DynamicKey: id Edit: id ErrorBehavior: id FieldError: id
      FieldErrors: id Generated: id GeneratedEnum: id Guard: id InputObject: id KeyArgument: id
      KeyPart: id Lens: id LensList: id Lookup: id Members: id MutationAction: id
      MutationOperation: id OperationHandle: id OperationKind: id OperationType: id QueryType: id MutationType: id SubscriptionType: id Payload: id
      Plan: id PlanField: id QueryOperation: id Refetch: id Registry: id Resolution: id
      ScalarKind: id Selection: id Slot: id StorageKey: id SubscriptionHandle: id
      SubscriptionOperation: id Transient: id TypeID: id Format1: id
      # What generated code spells from the standard library and Compose.
      Any: id Boolean: id Double: id Int: id List: id Long: id Map: id Pair: id Result: id
      String: id Unit: id Stable: id JvmName: id JvmField: id OptIn: id run: id let: id takeIf: id
      map: id lazy: id listOf: id mapOf: id emptyList: id emptyMap: id mutableListOf: id
      getOrThrow: id success: id failure: id
      ... on Character { status }
    }
    """)
fun KotlinAbstract() {}

// Each name as an aliased field under `@catch`, read as a `Result`.
@Fragment($$"""
    fragment KotlinCaught_character on Character {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: name @catch break: name @catch class: name @catch continue: name @catch do: name @catch
      else: name @catch false: name @catch for: name @catch fun: name @catch if: name @catch
      in: name @catch interface: name @catch is: name @catch null: name @catch object: name @catch
      package: name @catch return: name @catch super: name @catch this: name @catch
      throw: name @catch true: name @catch try: name @catch typealias: name @catch
      typeof: name @catch val: name @catch var: name @catch when: name @catch while: name @catch
      _: name @catch
      # Kotlin's soft and modifier keywords.
      by: name @catch catch: name @catch constructor: name @catch delegate: name @catch
      dynamic: name @catch field: name @catch file: name @catch finally: name @catch
      get: name @catch import: name @catch init: name @catch param: name @catch
      property: name @catch receiver: name @catch set: name @catch setparam: name @catch
      value: name @catch where: name @catch abstract: name @catch actual: name @catch
      annotation: name @catch companion: name @catch const: name @catch crossinline: name @catch
      data: name @catch enum: name @catch expect: name @catch external: name @catch
      final: name @catch infix: name @catch inline: name @catch inner: name @catch
      internal: name @catch lateinit: name @catch noinline: name @catch open: name @catch
      operator: name @catch out: name @catch override: name @catch private: name @catch
      protected: name @catch public: name @catch reified: name @catch sealed: name @catch
      suspend: name @catch tailrec: name @catch vararg: name @catch context: name @catch
      # What every lens declares, and what a refetchable fragment and a connection add.
      satisfied: name @catch missingRequiredField: name @catch fieldErrors: name @catch
      isPresent: name @catch throwing: name @catch caught: name @catch refetchable: name @catch
      refetch: name @catch connection: name @catch nodes: name @catch hasNext: name @catch
      hasPrevious: name @catch isLoadingNext: name @catch isLoadingPrevious: name @catch
      connectionID: name @catch loadNext: name @catch loadPrevious: name @catch
      # The locals, parameters and lambda parameters of generated bodies.
      bound: name @catch errors: name @catch child: name @catch missing: name @catch
      other: name @catch it: name @catch element: name @catch count: name @catch
      optimistic: name @catch text: name @catch fields: name @catch
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      variables: name @catch type: name @catch resolution: name @catch name: name @catch
      document: name @catch kind: name @catch errorBehavior: name @catch
      cacheExpirationSeconds: name @catch throwsOnFieldError: name @catch bubbles: name @catch
      hasDeferred: name @catch plan: name @catch selection: name @catch selection0: name @catch
      Data: name @catch Action: name @catch OptimisticResponse: name @catch invoke: name @catch
      commit: name @catch variable: name @catch payload: name @catch
      # What a class, a data class, an enum and a collection give.
      copy: name @catch component1: name @catch component2: name @catch javaClass: name @catch
      of: name @catch scalarText: name @catch Undeclared: name @catch size: name @catch
      keys: name @catch values: name @catch entries: name @catch
      # The shared objects, and what they declare or spell.
      Types: name @catch AbstractSlots: name @catch Sites: name @catch Guards: name @catch
      schemaDigest: name @catch format: name @catch transient: name @catch baton: name @catch
      MappedScalar: name @catch
      # The runtime's names generated code spells.
      AbstractSlot: name @catch Anchor: name @catch ArgumentSite: name @catch
      ConnectionCursor: name @catch ConnectionPlan: name @catch ConnectionSlots: name @catch
      Document: name @catch DynamicKey: name @catch Edit: name @catch ErrorBehavior: name @catch
      FieldError: name @catch FieldErrors: name @catch Generated: name @catch
      GeneratedEnum: name @catch Guard: name @catch InputObject: name @catch
      KeyArgument: name @catch KeyPart: name @catch Lens: name @catch LensList: name @catch
      Lookup: name @catch Members: name @catch MutationAction: name @catch
      MutationOperation: name @catch OperationHandle: name @catch OperationKind: name @catch
      OperationType: name @catch QueryType: name @catch MutationType: name @catch SubscriptionType: name @catch Payload: name @catch Plan: name @catch PlanField: name @catch
      QueryOperation: name @catch Refetch: name @catch Registry: name @catch Resolution: name @catch
      ScalarKind: name @catch Selection: name @catch Slot: name @catch StorageKey: name @catch
      SubscriptionHandle: name @catch SubscriptionOperation: name @catch Transient: name @catch
      TypeID: name @catch Format1: name @catch
      # What generated code spells from the standard library and Compose.
      Any: name @catch Boolean: name @catch Double: name @catch Int: name @catch List: name @catch
      Long: name @catch Map: name @catch Pair: name @catch Result: name @catch String: name @catch
      Unit: name @catch Stable: name @catch JvmName: name @catch JvmField: name @catch
      OptIn: name @catch run: name @catch let: name @catch takeIf: name @catch map: name @catch
      lazy: name @catch listOf: name @catch mapOf: name @catch emptyList: name @catch
      emptyMap: name @catch mutableListOf: name @catch getOrThrow: name @catch success: name @catch
      failure: name @catch
    }
    """)
fun KotlinCaught() {}

// Each name as an aliased field under `@required`, which the lens's
// checks name.
@Fragment($$"""
    fragment KotlinRequiredFields_character on Character {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: name @required(action: LOG) break: name @required(action: LOG)
      class: name @required(action: LOG) continue: name @required(action: LOG)
      do: name @required(action: LOG) else: name @required(action: LOG)
      false: name @required(action: LOG) for: name @required(action: LOG)
      fun: name @required(action: LOG) if: name @required(action: LOG)
      in: name @required(action: LOG) interface: name @required(action: LOG)
      is: name @required(action: LOG) null: name @required(action: LOG)
      object: name @required(action: LOG) package: name @required(action: LOG)
      return: name @required(action: LOG) super: name @required(action: LOG)
      this: name @required(action: LOG) throw: name @required(action: LOG)
      true: name @required(action: LOG) try: name @required(action: LOG)
      typealias: name @required(action: LOG) typeof: name @required(action: LOG)
      val: name @required(action: LOG) var: name @required(action: LOG)
      when: name @required(action: LOG) while: name @required(action: LOG)
      _: name @required(action: LOG)
      # Kotlin's soft and modifier keywords.
      by: name @required(action: LOG) catch: name @required(action: LOG)
      constructor: name @required(action: LOG) delegate: name @required(action: LOG)
      dynamic: name @required(action: LOG) field: name @required(action: LOG)
      file: name @required(action: LOG) finally: name @required(action: LOG)
      get: name @required(action: LOG) import: name @required(action: LOG)
      init: name @required(action: LOG) param: name @required(action: LOG)
      property: name @required(action: LOG) receiver: name @required(action: LOG)
      set: name @required(action: LOG) setparam: name @required(action: LOG)
      value: name @required(action: LOG) where: name @required(action: LOG)
      abstract: name @required(action: LOG) actual: name @required(action: LOG)
      annotation: name @required(action: LOG) companion: name @required(action: LOG)
      const: name @required(action: LOG) crossinline: name @required(action: LOG)
      data: name @required(action: LOG) enum: name @required(action: LOG)
      expect: name @required(action: LOG) external: name @required(action: LOG)
      final: name @required(action: LOG) infix: name @required(action: LOG)
      inline: name @required(action: LOG) inner: name @required(action: LOG)
      internal: name @required(action: LOG) lateinit: name @required(action: LOG)
      noinline: name @required(action: LOG) open: name @required(action: LOG)
      operator: name @required(action: LOG) out: name @required(action: LOG)
      override: name @required(action: LOG) private: name @required(action: LOG)
      protected: name @required(action: LOG) public: name @required(action: LOG)
      reified: name @required(action: LOG) sealed: name @required(action: LOG)
      suspend: name @required(action: LOG) tailrec: name @required(action: LOG)
      vararg: name @required(action: LOG) context: name @required(action: LOG)
      # What every lens declares, and what a refetchable fragment and a connection add.
      satisfied: name @required(action: LOG) missingRequiredField: name @required(action: LOG)
      fieldErrors: name @required(action: LOG) isPresent: name @required(action: LOG)
      throwing: name @required(action: LOG) caught: name @required(action: LOG)
      refetchable: name @required(action: LOG) refetch: name @required(action: LOG)
      connection: name @required(action: LOG) nodes: name @required(action: LOG)
      hasNext: name @required(action: LOG) hasPrevious: name @required(action: LOG)
      isLoadingNext: name @required(action: LOG) isLoadingPrevious: name @required(action: LOG)
      connectionID: name @required(action: LOG) loadNext: name @required(action: LOG)
      loadPrevious: name @required(action: LOG)
      # The locals, parameters and lambda parameters of generated bodies.
      bound: name @required(action: LOG) errors: name @required(action: LOG)
      child: name @required(action: LOG) missing: name @required(action: LOG)
      other: name @required(action: LOG) it: name @required(action: LOG)
      element: name @required(action: LOG) count: name @required(action: LOG)
      optimistic: name @required(action: LOG) text: name @required(action: LOG)
      fields: name @required(action: LOG)
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      variables: name @required(action: LOG) type: name @required(action: LOG)
      resolution: name @required(action: LOG) name: name @required(action: LOG)
      document: name @required(action: LOG) kind: name @required(action: LOG)
      errorBehavior: name @required(action: LOG) cacheExpirationSeconds: name @required(action: LOG)
      throwsOnFieldError: name @required(action: LOG) bubbles: name @required(action: LOG)
      hasDeferred: name @required(action: LOG) plan: name @required(action: LOG)
      selection: name @required(action: LOG) selection0: name @required(action: LOG)
      Data: name @required(action: LOG) Action: name @required(action: LOG)
      OptimisticResponse: name @required(action: LOG) invoke: name @required(action: LOG)
      commit: name @required(action: LOG) variable: name @required(action: LOG)
      payload: name @required(action: LOG)
      # What a class, a data class, an enum and a collection give.
      copy: name @required(action: LOG) component1: name @required(action: LOG)
      component2: name @required(action: LOG) javaClass: name @required(action: LOG)
      of: name @required(action: LOG) scalarText: name @required(action: LOG)
      Undeclared: name @required(action: LOG) size: name @required(action: LOG)
      keys: name @required(action: LOG) values: name @required(action: LOG)
      entries: name @required(action: LOG)
      # The shared objects, and what they declare or spell.
      Types: name @required(action: LOG) AbstractSlots: name @required(action: LOG)
      Sites: name @required(action: LOG) Guards: name @required(action: LOG)
      schemaDigest: name @required(action: LOG) format: name @required(action: LOG)
      transient: name @required(action: LOG) baton: name @required(action: LOG)
      MappedScalar: name @required(action: LOG)
      # The runtime's names generated code spells.
      AbstractSlot: name @required(action: LOG) Anchor: name @required(action: LOG)
      ArgumentSite: name @required(action: LOG) ConnectionCursor: name @required(action: LOG)
      ConnectionPlan: name @required(action: LOG) ConnectionSlots: name @required(action: LOG)
      Document: name @required(action: LOG) DynamicKey: name @required(action: LOG)
      Edit: name @required(action: LOG) ErrorBehavior: name @required(action: LOG)
      FieldError: name @required(action: LOG) FieldErrors: name @required(action: LOG)
      Generated: name @required(action: LOG) GeneratedEnum: name @required(action: LOG)
      Guard: name @required(action: LOG) InputObject: name @required(action: LOG)
      KeyArgument: name @required(action: LOG) KeyPart: name @required(action: LOG)
      Lens: name @required(action: LOG) LensList: name @required(action: LOG)
      Lookup: name @required(action: LOG) Members: name @required(action: LOG)
      MutationAction: name @required(action: LOG) MutationOperation: name @required(action: LOG)
      OperationHandle: name @required(action: LOG) OperationKind: name @required(action: LOG)
      OperationType: name @required(action: LOG) QueryType: name @required(action: LOG) MutationType: name @required(action: LOG) SubscriptionType: name @required(action: LOG) Payload: name @required(action: LOG)
      Plan: name @required(action: LOG) PlanField: name @required(action: LOG)
      QueryOperation: name @required(action: LOG) Refetch: name @required(action: LOG)
      Registry: name @required(action: LOG) Resolution: name @required(action: LOG)
      ScalarKind: name @required(action: LOG) Selection: name @required(action: LOG)
      Slot: name @required(action: LOG) StorageKey: name @required(action: LOG)
      SubscriptionHandle: name @required(action: LOG)
      SubscriptionOperation: name @required(action: LOG) Transient: name @required(action: LOG)
      TypeID: name @required(action: LOG) Format1: name @required(action: LOG)
      # What generated code spells from the standard library and Compose.
      Any: name @required(action: LOG) Boolean: name @required(action: LOG)
      Double: name @required(action: LOG) Int: name @required(action: LOG)
      List: name @required(action: LOG) Long: name @required(action: LOG)
      Map: name @required(action: LOG) Pair: name @required(action: LOG)
      Result: name @required(action: LOG) String: name @required(action: LOG)
      Unit: name @required(action: LOG) Stable: name @required(action: LOG)
      JvmName: name @required(action: LOG) JvmField: name @required(action: LOG)
      OptIn: name @required(action: LOG) run: name @required(action: LOG)
      let: name @required(action: LOG) takeIf: name @required(action: LOG)
      map: name @required(action: LOG) lazy: name @required(action: LOG)
      listOf: name @required(action: LOG) mapOf: name @required(action: LOG)
      emptyList: name @required(action: LOG) emptyMap: name @required(action: LOG)
      mutableListOf: name @required(action: LOG) getOrThrow: name @required(action: LOG)
      success: name @required(action: LOG) failure: name @required(action: LOG)
    }
    """)
fun KotlinRequiredFields() {}

// Each name as a variable of a query: a property and a constructor
// parameter of its value, read by `variables`, `equals` and `hashCode`.
@Query($$"""
    query KotlinVariables(
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      $as: ID! $break: ID! $class: ID! $continue: ID! $do: ID! $else: ID! $false: ID! $for: ID!
      $fun: ID! $if: ID! $in: ID! $interface: ID! $is: ID! $null: ID! $object: ID! $package: ID!
      $return: ID! $super: ID! $this: ID! $throw: ID! $true: ID! $try: ID! $typealias: ID!
      $typeof: ID! $val: ID! $var: ID! $when: ID! $while: ID! $_: ID!
      # Kotlin's soft and modifier keywords.
      $by: ID! $catch: ID! $constructor: ID! $delegate: ID! $dynamic: ID! $field: ID! $file: ID!
      $finally: ID! $get: ID! $import: ID! $init: ID! $param: ID! $property: ID! $receiver: ID!
      $set: ID! $setparam: ID! $value: ID! $where: ID! $abstract: ID! $actual: ID! $annotation: ID!
      $companion: ID! $const: ID! $crossinline: ID! $data: ID! $enum: ID! $expect: ID!
      $external: ID! $final: ID! $infix: ID! $inline: ID! $inner: ID! $internal: ID! $lateinit: ID!
      $noinline: ID! $open: ID! $operator: ID! $out: ID! $override: ID! $private: ID!
      $protected: ID! $public: ID! $reified: ID! $sealed: ID! $suspend: ID! $tailrec: ID!
      $vararg: ID! $context: ID!
      # What every lens declares, and what a refetchable fragment and a connection add.
      $anchor: ID! $recordID: ID! $satisfied: ID! $missingRequiredField: ID! $fieldErrors: ID!
      $isPresent: ID! $throwing: ID! $caught: ID! $refetchable: ID! $refetch: ID! $connection: ID!
      $nodes: ID! $hasNext: ID! $hasPrevious: ID! $isLoadingNext: ID! $isLoadingPrevious: ID!
      $connectionID: ID! $loadNext: ID! $loadPrevious: ID!
      # The locals, parameters and lambda parameters of generated bodies.
      $bound: ID! $errors: ID! $child: ID! $missing: ID! $other: ID! $it: ID! $element: ID!
      $count: ID! $optimistic: ID! $text: ID! $fields: ID!
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      $name: ID! $document: ID! $kind: ID! $errorBehavior: ID! $cacheExpirationSeconds: ID!
      $throwsOnFieldError: ID! $bubbles: ID! $hasDeferred: ID! $plan: ID! $selection: ID!
      $selection0: ID! $Action: ID! $OptimisticResponse: ID! $invoke: ID! $commit: ID!
      $variable: ID! $payload: ID!
      # What a class, a data class, an enum and a collection give.
      $copy: ID! $component1: ID! $component2: ID! $javaClass: ID! $of: ID! $scalarText: ID!
      $Undeclared: ID! $size: ID! $keys: ID! $values: ID! $entries: ID!
      # The shared objects, and what they declare or spell.
      $Types: ID! $Slots: ID! $AbstractSlots: ID! $Sites: ID! $Guards: ID! $schemaDigest: ID!
      $format: ID! $transient: ID! $baton: ID! $MappedScalar: ID!
      # The runtime's names generated code spells.
      $AbstractSlot: ID! $Anchor: ID! $ArgumentSite: ID! $ConnectionCursor: ID! $ConnectionPlan: ID!
      $ConnectionSlots: ID! $Document: ID! $DynamicKey: ID! $Edit: ID! $ErrorBehavior: ID!
      $FieldError: ID! $FieldErrors: ID! $Generated: ID! $GeneratedEnum: ID! $Guard: ID!
      $InputObject: ID! $KeyArgument: ID! $KeyPart: ID! $Lens: ID! $LensList: ID! $Lookup: ID!
      $Members: ID! $MutationAction: ID! $MutationOperation: ID! $OperationHandle: ID!
      $OperationKind: ID! $OperationType: ID! $QueryType: ID! $MutationType: ID! $SubscriptionType: ID! $Payload: ID! $Plan: ID! $PlanField: ID!
      $QueryOperation: ID! $Refetch: ID! $Registry: ID! $ScalarKind: ID! $Selection: ID! $Slot: ID!
      $StorageKey: ID! $SubscriptionHandle: ID! $SubscriptionOperation: ID! $Transient: ID!
      $TypeID: ID! $Format1: ID!
      # What generated code spells from the standard library and Compose.
      $Any: ID! $Boolean: ID! $Double: ID! $Int: ID! $List: ID! $Long: ID! $Map: ID! $Pair: ID!
      $Result: ID! $String: ID! $Unit: ID! $Stable: ID! $JvmName: ID! $JvmField: ID! $OptIn: ID!
      $run: ID! $let: ID! $takeIf: ID! $map: ID! $lazy: ID! $listOf: ID! $mapOf: ID! $emptyList: ID!
      $emptyMap: ID! $mutableListOf: ID! $getOrThrow: ID! $success: ID! $failure: ID!
    ) @throwOnFieldError {
      charactersByIds(ids: [$as, $break, $class, $continue, $do, $else, $false, $for, $fun, $if, $in, $interface, $is, $null, $object, $package, $return, $super, $this, $throw, $true, $try, $typealias, $typeof, $val, $var, $when, $while, $_, $by, $catch, $constructor, $delegate, $dynamic, $field, $file, $finally, $get, $import, $init, $param, $property, $receiver, $set, $setparam, $value, $where, $abstract, $actual, $annotation, $companion, $const, $crossinline, $data, $enum, $expect, $external, $final, $infix, $inline, $inner, $internal, $lateinit, $noinline, $open, $operator, $out, $override, $private, $protected, $public, $reified, $sealed, $suspend, $tailrec, $vararg, $context, $anchor, $recordID, $satisfied, $missingRequiredField, $fieldErrors, $isPresent, $throwing, $caught, $refetchable, $refetch, $connection, $nodes, $hasNext, $hasPrevious, $isLoadingNext, $isLoadingPrevious, $connectionID, $loadNext, $loadPrevious, $bound, $errors, $child, $missing, $other, $it, $element, $count, $optimistic, $text, $fields, $name, $document, $kind, $errorBehavior, $cacheExpirationSeconds, $throwsOnFieldError, $bubbles, $hasDeferred, $plan, $selection, $selection0, $Action, $OptimisticResponse, $invoke, $commit, $variable, $payload, $copy, $component1, $component2, $javaClass, $of, $scalarText, $Undeclared, $size, $keys, $values, $entries, $Types, $Slots, $AbstractSlots, $Sites, $Guards, $schemaDigest, $format, $transient, $baton, $MappedScalar, $AbstractSlot, $Anchor, $ArgumentSite, $ConnectionCursor, $ConnectionPlan, $ConnectionSlots, $Document, $DynamicKey, $Edit, $ErrorBehavior, $FieldError, $FieldErrors, $Generated, $GeneratedEnum, $Guard, $InputObject, $KeyArgument, $KeyPart, $Lens, $LensList, $Lookup, $Members, $MutationAction, $MutationOperation, $OperationHandle, $OperationKind, $OperationType, $QueryType, $MutationType, $SubscriptionType, $Payload, $Plan, $PlanField, $QueryOperation, $Refetch, $Registry, $ScalarKind, $Selection, $Slot, $StorageKey, $SubscriptionHandle, $SubscriptionOperation, $Transient, $TypeID, $Format1, $Any, $Boolean, $Double, $Int, $List, $Long, $Map, $Pair, $Result, $String, $Unit, $Stable, $JvmName, $JvmField, $OptIn, $run, $let, $takeIf, $map, $lazy, $listOf, $mapOf, $emptyList, $emptyMap, $mutableListOf, $getOrThrow, $success, $failure]) { id name }
    }
    """)
fun KotlinVariables() {}

// Each name as a variable of a mutation: a property of its value and a
// parameter of its action's `invoke`, which the lenses nested in it see
// as they check a caught field's errors.
@Mutation($$"""
    mutation KotlinMutationVariables(
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      $as: Boolean! $break: Boolean! $class: Boolean! $continue: Boolean! $do: Boolean!
      $else: Boolean! $false: Boolean! $for: Boolean! $fun: Boolean! $if: Boolean! $in: Boolean!
      $interface: Boolean! $is: Boolean! $null: Boolean! $object: Boolean! $package: Boolean!
      $return: Boolean! $super: Boolean! $this: Boolean! $throw: Boolean! $true: Boolean!
      $try: Boolean! $typealias: Boolean! $typeof: Boolean! $val: Boolean! $var: Boolean!
      $when: Boolean! $while: Boolean! $_: Boolean!
      # Kotlin's soft and modifier keywords.
      $by: Boolean! $catch: Boolean! $constructor: Boolean! $delegate: Boolean! $dynamic: Boolean!
      $field: Boolean! $file: Boolean! $finally: Boolean! $get: Boolean! $import: Boolean!
      $init: Boolean! $param: Boolean! $property: Boolean! $receiver: Boolean! $set: Boolean!
      $setparam: Boolean! $value: Boolean! $where: Boolean! $abstract: Boolean! $actual: Boolean!
      $annotation: Boolean! $companion: Boolean! $const: Boolean! $crossinline: Boolean!
      $data: Boolean! $enum: Boolean! $expect: Boolean! $external: Boolean! $final: Boolean!
      $infix: Boolean! $inline: Boolean! $inner: Boolean! $internal: Boolean! $lateinit: Boolean!
      $noinline: Boolean! $open: Boolean! $operator: Boolean! $out: Boolean! $override: Boolean!
      $private: Boolean! $protected: Boolean! $public: Boolean! $reified: Boolean! $sealed: Boolean!
      $suspend: Boolean! $tailrec: Boolean! $vararg: Boolean! $context: Boolean!
      # What every lens declares, and what a refetchable fragment and a connection add.
      $anchor: Boolean! $recordID: Boolean! $satisfied: Boolean! $missingRequiredField: Boolean!
      $fieldErrors: Boolean! $isPresent: Boolean! $throwing: Boolean! $caught: Boolean!
      $refetchable: Boolean! $refetch: Boolean! $connection: Boolean! $nodes: Boolean!
      $hasNext: Boolean! $hasPrevious: Boolean! $isLoadingNext: Boolean!
      $isLoadingPrevious: Boolean! $connectionID: Boolean! $loadNext: Boolean!
      $loadPrevious: Boolean!
      # The locals, parameters and lambda parameters of generated bodies.
      $bound: Boolean! $errors: Boolean! $child: Boolean! $missing: Boolean! $other: Boolean!
      $it: Boolean! $element: Boolean! $count: Boolean! $optimistic: Boolean! $text: Boolean!
      $fields: Boolean!
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      $resolution: Boolean! $name: Boolean! $document: Boolean! $kind: Boolean!
      $errorBehavior: Boolean! $cacheExpirationSeconds: Boolean! $throwsOnFieldError: Boolean!
      $bubbles: Boolean! $hasDeferred: Boolean! $plan: Boolean! $selection: Boolean!
      $selection0: Boolean! $Action: Boolean! $invoke: Boolean! $commit: Boolean!
      $variable: Boolean! $payload: Boolean!
      # What a class, a data class, an enum and a collection give.
      $copy: Boolean! $component1: Boolean! $component2: Boolean! $javaClass: Boolean! $of: Boolean!
      $scalarText: Boolean! $Undeclared: Boolean! $size: Boolean! $keys: Boolean! $values: Boolean!
      $entries: Boolean!
      # The shared objects, and what they declare or spell.
      $Types: Boolean! $Slots: Boolean! $AbstractSlots: Boolean! $Sites: Boolean! $Guards: Boolean!
      $schemaDigest: Boolean! $format: Boolean! $transient: Boolean! $baton: Boolean!
      $MappedScalar: Boolean!
      # The runtime's names generated code spells.
      $AbstractSlot: Boolean! $Anchor: Boolean! $ArgumentSite: Boolean! $ConnectionCursor: Boolean!
      $ConnectionPlan: Boolean! $ConnectionSlots: Boolean! $Document: Boolean! $DynamicKey: Boolean!
      $Edit: Boolean! $ErrorBehavior: Boolean! $FieldError: Boolean! $FieldErrors: Boolean!
      $Generated: Boolean! $GeneratedEnum: Boolean! $Guard: Boolean! $InputObject: Boolean!
      $KeyArgument: Boolean! $KeyPart: Boolean! $Lens: Boolean! $LensList: Boolean!
      $Lookup: Boolean! $Members: Boolean! $MutationAction: Boolean! $MutationOperation: Boolean!
      $OperationHandle: Boolean! $OperationKind: Boolean! $OperationType: Boolean! $QueryType: Boolean! $MutationType: Boolean! $SubscriptionType: Boolean!
      $Payload: Boolean! $Plan: Boolean! $PlanField: Boolean! $QueryOperation: Boolean!
      $Refetch: Boolean! $Registry: Boolean! $Resolution: Boolean! $ScalarKind: Boolean!
      $Selection: Boolean! $Slot: Boolean! $StorageKey: Boolean! $SubscriptionHandle: Boolean!
      $SubscriptionOperation: Boolean! $Transient: Boolean! $TypeID: Boolean! $Format1: Boolean!
      # What generated code spells from the standard library and Compose.
      $Any: Boolean! $Boolean: Boolean! $Double: Boolean! $Int: Boolean! $List: Boolean!
      $Long: Boolean! $Map: Boolean! $Pair: Boolean! $Result: Boolean! $String: Boolean!
      $Unit: Boolean! $Stable: Boolean! $JvmName: Boolean! $JvmField: Boolean! $OptIn: Boolean!
      $run: Boolean! $let: Boolean! $takeIf: Boolean! $map: Boolean! $lazy: Boolean!
      $listOf: Boolean! $mapOf: Boolean! $emptyList: Boolean! $emptyMap: Boolean!
      $mutableListOf: Boolean! $getOrThrow: Boolean! $success: Boolean! $failure: Boolean!
    ) {
      setFavorite(id: "1", favorite: true) @catch {
        character {
          id
          # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
          ... @include(if: $as) { name } ... @include(if: $break) { name }
          ... @include(if: $class) { name } ... @include(if: $continue) { name }
          ... @include(if: $do) { name } ... @include(if: $else) { name }
          ... @include(if: $false) { name } ... @include(if: $for) { name }
          ... @include(if: $fun) { name } ... @include(if: $if) { name }
          ... @include(if: $in) { name } ... @include(if: $interface) { name }
          ... @include(if: $is) { name } ... @include(if: $null) { name }
          ... @include(if: $object) { name } ... @include(if: $package) { name }
          ... @include(if: $return) { name } ... @include(if: $super) { name }
          ... @include(if: $this) { name } ... @include(if: $throw) { name }
          ... @include(if: $true) { name } ... @include(if: $try) { name }
          ... @include(if: $typealias) { name } ... @include(if: $typeof) { name }
          ... @include(if: $val) { name } ... @include(if: $var) { name }
          ... @include(if: $when) { name } ... @include(if: $while) { name }
          ... @include(if: $_) { name }
          # Kotlin's soft and modifier keywords.
          ... @include(if: $by) { name } ... @include(if: $catch) { name }
          ... @include(if: $constructor) { name } ... @include(if: $delegate) { name }
          ... @include(if: $dynamic) { name } ... @include(if: $field) { name }
          ... @include(if: $file) { name } ... @include(if: $finally) { name }
          ... @include(if: $get) { name } ... @include(if: $import) { name }
          ... @include(if: $init) { name } ... @include(if: $param) { name }
          ... @include(if: $property) { name } ... @include(if: $receiver) { name }
          ... @include(if: $set) { name } ... @include(if: $setparam) { name }
          ... @include(if: $value) { name } ... @include(if: $where) { name }
          ... @include(if: $abstract) { name } ... @include(if: $actual) { name }
          ... @include(if: $annotation) { name } ... @include(if: $companion) { name }
          ... @include(if: $const) { name } ... @include(if: $crossinline) { name }
          ... @include(if: $data) { name } ... @include(if: $enum) { name }
          ... @include(if: $expect) { name } ... @include(if: $external) { name }
          ... @include(if: $final) { name } ... @include(if: $infix) { name }
          ... @include(if: $inline) { name } ... @include(if: $inner) { name }
          ... @include(if: $internal) { name } ... @include(if: $lateinit) { name }
          ... @include(if: $noinline) { name } ... @include(if: $open) { name }
          ... @include(if: $operator) { name } ... @include(if: $out) { name }
          ... @include(if: $override) { name } ... @include(if: $private) { name }
          ... @include(if: $protected) { name } ... @include(if: $public) { name }
          ... @include(if: $reified) { name } ... @include(if: $sealed) { name }
          ... @include(if: $suspend) { name } ... @include(if: $tailrec) { name }
          ... @include(if: $vararg) { name } ... @include(if: $context) { name }
          # What every lens declares, and what a refetchable fragment and a connection add.
          ... @include(if: $anchor) { name } ... @include(if: $recordID) { name }
          ... @include(if: $satisfied) { name } ... @include(if: $missingRequiredField) { name }
          ... @include(if: $fieldErrors) { name } ... @include(if: $isPresent) { name }
          ... @include(if: $throwing) { name } ... @include(if: $caught) { name }
          ... @include(if: $refetchable) { name } ... @include(if: $refetch) { name }
          ... @include(if: $connection) { name } ... @include(if: $nodes) { name }
          ... @include(if: $hasNext) { name } ... @include(if: $hasPrevious) { name }
          ... @include(if: $isLoadingNext) { name } ... @include(if: $isLoadingPrevious) { name }
          ... @include(if: $connectionID) { name } ... @include(if: $loadNext) { name }
          ... @include(if: $loadPrevious) { name }
          # The locals, parameters and lambda parameters of generated bodies.
          ... @include(if: $bound) { name } ... @include(if: $errors) { name }
          ... @include(if: $child) { name } ... @include(if: $missing) { name }
          ... @include(if: $other) { name } ... @include(if: $it) { name }
          ... @include(if: $element) { name } ... @include(if: $count) { name }
          ... @include(if: $optimistic) { name } ... @include(if: $text) { name }
          ... @include(if: $fields) { name }
          # What an operation value, its companion, a mutation's action and its optimistic response declare.
          ... @include(if: $resolution) { name } ... @include(if: $name) { name }
          ... @include(if: $document) { name } ... @include(if: $kind) { name }
          ... @include(if: $errorBehavior) { name }
          ... @include(if: $cacheExpirationSeconds) { name }
          ... @include(if: $throwsOnFieldError) { name } ... @include(if: $bubbles) { name }
          ... @include(if: $hasDeferred) { name } ... @include(if: $plan) { name }
          ... @include(if: $selection) { name } ... @include(if: $selection0) { name }
          ... @include(if: $Action) { name } ... @include(if: $invoke) { name }
          ... @include(if: $commit) { name } ... @include(if: $variable) { name }
          ... @include(if: $payload) { name }
          # What a class, a data class, an enum and a collection give.
          ... @include(if: $copy) { name } ... @include(if: $component1) { name }
          ... @include(if: $component2) { name } ... @include(if: $javaClass) { name }
          ... @include(if: $of) { name } ... @include(if: $scalarText) { name }
          ... @include(if: $Undeclared) { name } ... @include(if: $size) { name }
          ... @include(if: $keys) { name } ... @include(if: $values) { name }
          ... @include(if: $entries) { name }
          # The shared objects, and what they declare or spell.
          ... @include(if: $Types) { name } ... @include(if: $Slots) { name }
          ... @include(if: $AbstractSlots) { name } ... @include(if: $Sites) { name }
          ... @include(if: $Guards) { name } ... @include(if: $schemaDigest) { name }
          ... @include(if: $format) { name } ... @include(if: $transient) { name }
          ... @include(if: $baton) { name } ... @include(if: $MappedScalar) { name }
          # The runtime's names generated code spells.
          ... @include(if: $AbstractSlot) { name } ... @include(if: $Anchor) { name }
          ... @include(if: $ArgumentSite) { name } ... @include(if: $ConnectionCursor) { name }
          ... @include(if: $ConnectionPlan) { name } ... @include(if: $ConnectionSlots) { name }
          ... @include(if: $Document) { name } ... @include(if: $DynamicKey) { name }
          ... @include(if: $Edit) { name } ... @include(if: $ErrorBehavior) { name }
          ... @include(if: $FieldError) { name } ... @include(if: $FieldErrors) { name }
          ... @include(if: $Generated) { name } ... @include(if: $GeneratedEnum) { name }
          ... @include(if: $Guard) { name } ... @include(if: $InputObject) { name }
          ... @include(if: $KeyArgument) { name } ... @include(if: $KeyPart) { name }
          ... @include(if: $Lens) { name } ... @include(if: $LensList) { name }
          ... @include(if: $Lookup) { name } ... @include(if: $Members) { name }
          ... @include(if: $MutationAction) { name } ... @include(if: $MutationOperation) { name }
          ... @include(if: $OperationHandle) { name } ... @include(if: $OperationKind) { name }
          ... @include(if: $OperationType) { name } ... @include(if: $QueryType) { name } ... @include(if: $MutationType) { name } ... @include(if: $SubscriptionType) { name } ... @include(if: $Payload) { name }
          ... @include(if: $Plan) { name } ... @include(if: $PlanField) { name }
          ... @include(if: $QueryOperation) { name } ... @include(if: $Refetch) { name }
          ... @include(if: $Registry) { name } ... @include(if: $Resolution) { name }
          ... @include(if: $ScalarKind) { name } ... @include(if: $Selection) { name }
          ... @include(if: $Slot) { name } ... @include(if: $StorageKey) { name }
          ... @include(if: $SubscriptionHandle) { name }
          ... @include(if: $SubscriptionOperation) { name } ... @include(if: $Transient) { name }
          ... @include(if: $TypeID) { name } ... @include(if: $Format1) { name }
          # What generated code spells from the standard library and Compose.
          ... @include(if: $Any) { name } ... @include(if: $Boolean) { name }
          ... @include(if: $Double) { name } ... @include(if: $Int) { name }
          ... @include(if: $List) { name } ... @include(if: $Long) { name }
          ... @include(if: $Map) { name } ... @include(if: $Pair) { name }
          ... @include(if: $Result) { name } ... @include(if: $String) { name }
          ... @include(if: $Unit) { name } ... @include(if: $Stable) { name }
          ... @include(if: $JvmName) { name } ... @include(if: $JvmField) { name }
          ... @include(if: $OptIn) { name } ... @include(if: $run) { name }
          ... @include(if: $let) { name } ... @include(if: $takeIf) { name }
          ... @include(if: $map) { name } ... @include(if: $lazy) { name }
          ... @include(if: $listOf) { name } ... @include(if: $mapOf) { name }
          ... @include(if: $emptyList) { name } ... @include(if: $emptyMap) { name }
          ... @include(if: $mutableListOf) { name } ... @include(if: $getOrThrow) { name }
          ... @include(if: $success) { name } ... @include(if: $failure) { name }
        }
      }
    }
    """)
fun KotlinMutationVariables() {}

// A mutation whose variable is named like it, which its action passes
// to the mutation's constructor.
@Mutation($$"""
    mutation KotlinNamesake($KotlinNamesake: ID!) {
      setFavorite(id: $KotlinNamesake, favorite: true) { character { id } }
    }
    """)
fun KotlinNamesake() {}

// Each name as a variable of a subscription, which the lenses nested in it
// see as they check a caught field's errors.
@Subscription($$"""
    subscription KotlinSubscriptionVariables(
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      $as: Boolean! $break: Boolean! $class: Boolean! $continue: Boolean! $do: Boolean!
      $else: Boolean! $false: Boolean! $for: Boolean! $fun: Boolean! $if: Boolean! $in: Boolean!
      $interface: Boolean! $is: Boolean! $null: Boolean! $object: Boolean! $package: Boolean!
      $return: Boolean! $super: Boolean! $this: Boolean! $throw: Boolean! $true: Boolean!
      $try: Boolean! $typealias: Boolean! $typeof: Boolean! $val: Boolean! $var: Boolean!
      $when: Boolean! $while: Boolean! $_: Boolean!
      # Kotlin's soft and modifier keywords.
      $by: Boolean! $catch: Boolean! $constructor: Boolean! $delegate: Boolean! $dynamic: Boolean!
      $field: Boolean! $file: Boolean! $finally: Boolean! $get: Boolean! $import: Boolean!
      $init: Boolean! $param: Boolean! $property: Boolean! $receiver: Boolean! $set: Boolean!
      $setparam: Boolean! $value: Boolean! $where: Boolean! $abstract: Boolean! $actual: Boolean!
      $annotation: Boolean! $companion: Boolean! $const: Boolean! $crossinline: Boolean!
      $data: Boolean! $enum: Boolean! $expect: Boolean! $external: Boolean! $final: Boolean!
      $infix: Boolean! $inline: Boolean! $inner: Boolean! $internal: Boolean! $lateinit: Boolean!
      $noinline: Boolean! $open: Boolean! $operator: Boolean! $out: Boolean! $override: Boolean!
      $private: Boolean! $protected: Boolean! $public: Boolean! $reified: Boolean! $sealed: Boolean!
      $suspend: Boolean! $tailrec: Boolean! $vararg: Boolean! $context: Boolean!
      # What every lens declares, and what a refetchable fragment and a connection add.
      $anchor: Boolean! $recordID: Boolean! $satisfied: Boolean! $missingRequiredField: Boolean!
      $fieldErrors: Boolean! $isPresent: Boolean! $throwing: Boolean! $caught: Boolean!
      $refetchable: Boolean! $refetch: Boolean! $connection: Boolean! $nodes: Boolean!
      $hasNext: Boolean! $hasPrevious: Boolean! $isLoadingNext: Boolean!
      $isLoadingPrevious: Boolean! $connectionID: Boolean! $loadNext: Boolean!
      $loadPrevious: Boolean!
      # The locals, parameters and lambda parameters of generated bodies.
      $bound: Boolean! $errors: Boolean! $child: Boolean! $missing: Boolean! $other: Boolean!
      $it: Boolean! $element: Boolean! $count: Boolean! $optimistic: Boolean! $text: Boolean!
      $fields: Boolean!
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      $name: Boolean! $document: Boolean! $kind: Boolean! $errorBehavior: Boolean!
      $cacheExpirationSeconds: Boolean! $throwsOnFieldError: Boolean! $bubbles: Boolean!
      $hasDeferred: Boolean! $plan: Boolean! $selection: Boolean! $selection0: Boolean!
      $Action: Boolean! $OptimisticResponse: Boolean! $invoke: Boolean! $commit: Boolean!
      $variable: Boolean! $payload: Boolean!
      # What a class, a data class, an enum and a collection give.
      $copy: Boolean! $component1: Boolean! $component2: Boolean! $javaClass: Boolean! $of: Boolean!
      $scalarText: Boolean! $Undeclared: Boolean! $size: Boolean! $keys: Boolean! $values: Boolean!
      $entries: Boolean!
      # The shared objects, and what they declare or spell.
      $Types: Boolean! $Slots: Boolean! $AbstractSlots: Boolean! $Sites: Boolean! $Guards: Boolean!
      $schemaDigest: Boolean! $format: Boolean! $transient: Boolean! $baton: Boolean!
      $MappedScalar: Boolean!
      # The runtime's names generated code spells.
      $AbstractSlot: Boolean! $Anchor: Boolean! $ArgumentSite: Boolean! $ConnectionCursor: Boolean!
      $ConnectionPlan: Boolean! $ConnectionSlots: Boolean! $Document: Boolean! $DynamicKey: Boolean!
      $Edit: Boolean! $ErrorBehavior: Boolean! $FieldError: Boolean! $FieldErrors: Boolean!
      $Generated: Boolean! $GeneratedEnum: Boolean! $Guard: Boolean! $InputObject: Boolean!
      $KeyArgument: Boolean! $KeyPart: Boolean! $Lens: Boolean! $LensList: Boolean!
      $Lookup: Boolean! $Members: Boolean! $MutationAction: Boolean! $MutationOperation: Boolean!
      $OperationHandle: Boolean! $OperationKind: Boolean! $OperationType: Boolean! $QueryType: Boolean! $MutationType: Boolean! $SubscriptionType: Boolean!
      $Payload: Boolean! $Plan: Boolean! $PlanField: Boolean! $QueryOperation: Boolean!
      $Refetch: Boolean! $Registry: Boolean! $ScalarKind: Boolean! $Selection: Boolean!
      $Slot: Boolean! $StorageKey: Boolean! $SubscriptionHandle: Boolean!
      $SubscriptionOperation: Boolean! $Transient: Boolean! $TypeID: Boolean! $Format1: Boolean!
      # What generated code spells from the standard library and Compose.
      $Any: Boolean! $Boolean: Boolean! $Double: Boolean! $Int: Boolean! $List: Boolean!
      $Long: Boolean! $Map: Boolean! $Pair: Boolean! $Result: Boolean! $String: Boolean!
      $Unit: Boolean! $Stable: Boolean! $JvmName: Boolean! $JvmField: Boolean! $OptIn: Boolean!
      $run: Boolean! $let: Boolean! $takeIf: Boolean! $map: Boolean! $lazy: Boolean!
      $listOf: Boolean! $mapOf: Boolean! $emptyList: Boolean! $emptyMap: Boolean!
      $mutableListOf: Boolean! $getOrThrow: Boolean! $success: Boolean! $failure: Boolean!
    ) {
      noteAdded(characterId: "1") @catch {
        noteEdge {
          node { id }
          # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
          ... @include(if: $as) { cursor } ... @include(if: $break) { cursor }
          ... @include(if: $class) { cursor } ... @include(if: $continue) { cursor }
          ... @include(if: $do) { cursor } ... @include(if: $else) { cursor }
          ... @include(if: $false) { cursor } ... @include(if: $for) { cursor }
          ... @include(if: $fun) { cursor } ... @include(if: $if) { cursor }
          ... @include(if: $in) { cursor } ... @include(if: $interface) { cursor }
          ... @include(if: $is) { cursor } ... @include(if: $null) { cursor }
          ... @include(if: $object) { cursor } ... @include(if: $package) { cursor }
          ... @include(if: $return) { cursor } ... @include(if: $super) { cursor }
          ... @include(if: $this) { cursor } ... @include(if: $throw) { cursor }
          ... @include(if: $true) { cursor } ... @include(if: $try) { cursor }
          ... @include(if: $typealias) { cursor } ... @include(if: $typeof) { cursor }
          ... @include(if: $val) { cursor } ... @include(if: $var) { cursor }
          ... @include(if: $when) { cursor } ... @include(if: $while) { cursor }
          ... @include(if: $_) { cursor }
          # Kotlin's soft and modifier keywords.
          ... @include(if: $by) { cursor } ... @include(if: $catch) { cursor }
          ... @include(if: $constructor) { cursor } ... @include(if: $delegate) { cursor }
          ... @include(if: $dynamic) { cursor } ... @include(if: $field) { cursor }
          ... @include(if: $file) { cursor } ... @include(if: $finally) { cursor }
          ... @include(if: $get) { cursor } ... @include(if: $import) { cursor }
          ... @include(if: $init) { cursor } ... @include(if: $param) { cursor }
          ... @include(if: $property) { cursor } ... @include(if: $receiver) { cursor }
          ... @include(if: $set) { cursor } ... @include(if: $setparam) { cursor }
          ... @include(if: $value) { cursor } ... @include(if: $where) { cursor }
          ... @include(if: $abstract) { cursor } ... @include(if: $actual) { cursor }
          ... @include(if: $annotation) { cursor } ... @include(if: $companion) { cursor }
          ... @include(if: $const) { cursor } ... @include(if: $crossinline) { cursor }
          ... @include(if: $data) { cursor } ... @include(if: $enum) { cursor }
          ... @include(if: $expect) { cursor } ... @include(if: $external) { cursor }
          ... @include(if: $final) { cursor } ... @include(if: $infix) { cursor }
          ... @include(if: $inline) { cursor } ... @include(if: $inner) { cursor }
          ... @include(if: $internal) { cursor } ... @include(if: $lateinit) { cursor }
          ... @include(if: $noinline) { cursor } ... @include(if: $open) { cursor }
          ... @include(if: $operator) { cursor } ... @include(if: $out) { cursor }
          ... @include(if: $override) { cursor } ... @include(if: $private) { cursor }
          ... @include(if: $protected) { cursor } ... @include(if: $public) { cursor }
          ... @include(if: $reified) { cursor } ... @include(if: $sealed) { cursor }
          ... @include(if: $suspend) { cursor } ... @include(if: $tailrec) { cursor }
          ... @include(if: $vararg) { cursor } ... @include(if: $context) { cursor }
          # What every lens declares, and what a refetchable fragment and a connection add.
          ... @include(if: $anchor) { cursor } ... @include(if: $recordID) { cursor }
          ... @include(if: $satisfied) { cursor } ... @include(if: $missingRequiredField) { cursor }
          ... @include(if: $fieldErrors) { cursor } ... @include(if: $isPresent) { cursor }
          ... @include(if: $throwing) { cursor } ... @include(if: $caught) { cursor }
          ... @include(if: $refetchable) { cursor } ... @include(if: $refetch) { cursor }
          ... @include(if: $connection) { cursor } ... @include(if: $nodes) { cursor }
          ... @include(if: $hasNext) { cursor } ... @include(if: $hasPrevious) { cursor }
          ... @include(if: $isLoadingNext) { cursor }
          ... @include(if: $isLoadingPrevious) { cursor } ... @include(if: $connectionID) { cursor }
          ... @include(if: $loadNext) { cursor } ... @include(if: $loadPrevious) { cursor }
          # The locals, parameters and lambda parameters of generated bodies.
          ... @include(if: $bound) { cursor } ... @include(if: $errors) { cursor }
          ... @include(if: $child) { cursor } ... @include(if: $missing) { cursor }
          ... @include(if: $other) { cursor } ... @include(if: $it) { cursor }
          ... @include(if: $element) { cursor } ... @include(if: $count) { cursor }
          ... @include(if: $optimistic) { cursor } ... @include(if: $text) { cursor }
          ... @include(if: $fields) { cursor }
          # What an operation value, its companion, a mutation's action and its optimistic response declare.
          ... @include(if: $name) { cursor } ... @include(if: $document) { cursor }
          ... @include(if: $kind) { cursor } ... @include(if: $errorBehavior) { cursor }
          ... @include(if: $cacheExpirationSeconds) { cursor }
          ... @include(if: $throwsOnFieldError) { cursor } ... @include(if: $bubbles) { cursor }
          ... @include(if: $hasDeferred) { cursor } ... @include(if: $plan) { cursor }
          ... @include(if: $selection) { cursor } ... @include(if: $selection0) { cursor }
          ... @include(if: $Action) { cursor } ... @include(if: $OptimisticResponse) { cursor }
          ... @include(if: $invoke) { cursor } ... @include(if: $commit) { cursor }
          ... @include(if: $variable) { cursor } ... @include(if: $payload) { cursor }
          # What a class, a data class, an enum and a collection give.
          ... @include(if: $copy) { cursor } ... @include(if: $component1) { cursor }
          ... @include(if: $component2) { cursor } ... @include(if: $javaClass) { cursor }
          ... @include(if: $of) { cursor } ... @include(if: $scalarText) { cursor }
          ... @include(if: $Undeclared) { cursor } ... @include(if: $size) { cursor }
          ... @include(if: $keys) { cursor } ... @include(if: $values) { cursor }
          ... @include(if: $entries) { cursor }
          # The shared objects, and what they declare or spell.
          ... @include(if: $Types) { cursor } ... @include(if: $Slots) { cursor }
          ... @include(if: $AbstractSlots) { cursor } ... @include(if: $Sites) { cursor }
          ... @include(if: $Guards) { cursor } ... @include(if: $schemaDigest) { cursor }
          ... @include(if: $format) { cursor } ... @include(if: $transient) { cursor }
          ... @include(if: $baton) { cursor } ... @include(if: $MappedScalar) { cursor }
          # The runtime's names generated code spells.
          ... @include(if: $AbstractSlot) { cursor } ... @include(if: $Anchor) { cursor }
          ... @include(if: $ArgumentSite) { cursor } ... @include(if: $ConnectionCursor) { cursor }
          ... @include(if: $ConnectionPlan) { cursor } ... @include(if: $ConnectionSlots) { cursor }
          ... @include(if: $Document) { cursor } ... @include(if: $DynamicKey) { cursor }
          ... @include(if: $Edit) { cursor } ... @include(if: $ErrorBehavior) { cursor }
          ... @include(if: $FieldError) { cursor } ... @include(if: $FieldErrors) { cursor }
          ... @include(if: $Generated) { cursor } ... @include(if: $GeneratedEnum) { cursor }
          ... @include(if: $Guard) { cursor } ... @include(if: $InputObject) { cursor }
          ... @include(if: $KeyArgument) { cursor } ... @include(if: $KeyPart) { cursor }
          ... @include(if: $Lens) { cursor } ... @include(if: $LensList) { cursor }
          ... @include(if: $Lookup) { cursor } ... @include(if: $Members) { cursor }
          ... @include(if: $MutationAction) { cursor }
          ... @include(if: $MutationOperation) { cursor }
          ... @include(if: $OperationHandle) { cursor } ... @include(if: $OperationKind) { cursor }
          ... @include(if: $OperationType) { cursor } ... @include(if: $QueryType) { cursor } ... @include(if: $MutationType) { cursor } ... @include(if: $SubscriptionType) { cursor } ... @include(if: $Payload) { cursor }
          ... @include(if: $Plan) { cursor } ... @include(if: $PlanField) { cursor }
          ... @include(if: $QueryOperation) { cursor } ... @include(if: $Refetch) { cursor }
          ... @include(if: $Registry) { cursor } ... @include(if: $ScalarKind) { cursor }
          ... @include(if: $Selection) { cursor } ... @include(if: $Slot) { cursor }
          ... @include(if: $StorageKey) { cursor } ... @include(if: $SubscriptionHandle) { cursor }
          ... @include(if: $SubscriptionOperation) { cursor }
          ... @include(if: $Transient) { cursor } ... @include(if: $TypeID) { cursor }
          ... @include(if: $Format1) { cursor }
          # What generated code spells from the standard library and Compose.
          ... @include(if: $Any) { cursor } ... @include(if: $Boolean) { cursor }
          ... @include(if: $Double) { cursor } ... @include(if: $Int) { cursor }
          ... @include(if: $List) { cursor } ... @include(if: $Long) { cursor }
          ... @include(if: $Map) { cursor } ... @include(if: $Pair) { cursor }
          ... @include(if: $Result) { cursor } ... @include(if: $String) { cursor }
          ... @include(if: $Unit) { cursor } ... @include(if: $Stable) { cursor }
          ... @include(if: $JvmName) { cursor } ... @include(if: $JvmField) { cursor }
          ... @include(if: $OptIn) { cursor } ... @include(if: $run) { cursor }
          ... @include(if: $let) { cursor } ... @include(if: $takeIf) { cursor }
          ... @include(if: $map) { cursor } ... @include(if: $lazy) { cursor }
          ... @include(if: $listOf) { cursor } ... @include(if: $mapOf) { cursor }
          ... @include(if: $emptyList) { cursor } ... @include(if: $emptyMap) { cursor }
          ... @include(if: $mutableListOf) { cursor } ... @include(if: $getOrThrow) { cursor }
          ... @include(if: $success) { cursor } ... @include(if: $failure) { cursor }
        }
      }
    }
    """)
fun KotlinSubscriptionVariables() {}

// Each name as an argument of a refetchable fragment, a variable of its
// refetch query.
@Fragment($$"""
    fragment KotlinArguments_character on Character
    @argumentDefinitions(
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: {type: "Boolean", defaultValue: true} break: {type: "Boolean", defaultValue: true}
      class: {type: "Boolean", defaultValue: true} continue: {type: "Boolean", defaultValue: true}
      do: {type: "Boolean", defaultValue: true} else: {type: "Boolean", defaultValue: true}
      false: {type: "Boolean", defaultValue: true} for: {type: "Boolean", defaultValue: true}
      fun: {type: "Boolean", defaultValue: true} if: {type: "Boolean", defaultValue: true}
      in: {type: "Boolean", defaultValue: true} interface: {type: "Boolean", defaultValue: true}
      is: {type: "Boolean", defaultValue: true} null: {type: "Boolean", defaultValue: true}
      object: {type: "Boolean", defaultValue: true} package: {type: "Boolean", defaultValue: true}
      return: {type: "Boolean", defaultValue: true} super: {type: "Boolean", defaultValue: true}
      this: {type: "Boolean", defaultValue: true} throw: {type: "Boolean", defaultValue: true}
      true: {type: "Boolean", defaultValue: true} try: {type: "Boolean", defaultValue: true}
      typealias: {type: "Boolean", defaultValue: true} typeof: {type: "Boolean", defaultValue: true}
      val: {type: "Boolean", defaultValue: true} var: {type: "Boolean", defaultValue: true}
      when: {type: "Boolean", defaultValue: true} while: {type: "Boolean", defaultValue: true}
      _: {type: "Boolean", defaultValue: true}
      # Kotlin's soft and modifier keywords.
      by: {type: "Boolean", defaultValue: true} catch: {type: "Boolean", defaultValue: true}
      constructor: {type: "Boolean", defaultValue: true}
      delegate: {type: "Boolean", defaultValue: true} dynamic: {type: "Boolean", defaultValue: true}
      field: {type: "Boolean", defaultValue: true} file: {type: "Boolean", defaultValue: true}
      finally: {type: "Boolean", defaultValue: true} get: {type: "Boolean", defaultValue: true}
      import: {type: "Boolean", defaultValue: true} init: {type: "Boolean", defaultValue: true}
      param: {type: "Boolean", defaultValue: true} property: {type: "Boolean", defaultValue: true}
      receiver: {type: "Boolean", defaultValue: true} set: {type: "Boolean", defaultValue: true}
      setparam: {type: "Boolean", defaultValue: true} value: {type: "Boolean", defaultValue: true}
      where: {type: "Boolean", defaultValue: true} abstract: {type: "Boolean", defaultValue: true}
      actual: {type: "Boolean", defaultValue: true}
      annotation: {type: "Boolean", defaultValue: true}
      companion: {type: "Boolean", defaultValue: true} const: {type: "Boolean", defaultValue: true}
      crossinline: {type: "Boolean", defaultValue: true} data: {type: "Boolean", defaultValue: true}
      enum: {type: "Boolean", defaultValue: true} expect: {type: "Boolean", defaultValue: true}
      external: {type: "Boolean", defaultValue: true} final: {type: "Boolean", defaultValue: true}
      infix: {type: "Boolean", defaultValue: true} inline: {type: "Boolean", defaultValue: true}
      inner: {type: "Boolean", defaultValue: true} internal: {type: "Boolean", defaultValue: true}
      lateinit: {type: "Boolean", defaultValue: true}
      noinline: {type: "Boolean", defaultValue: true} open: {type: "Boolean", defaultValue: true}
      operator: {type: "Boolean", defaultValue: true} out: {type: "Boolean", defaultValue: true}
      override: {type: "Boolean", defaultValue: true} private: {type: "Boolean", defaultValue: true}
      protected: {type: "Boolean", defaultValue: true} public: {type: "Boolean", defaultValue: true}
      reified: {type: "Boolean", defaultValue: true} sealed: {type: "Boolean", defaultValue: true}
      suspend: {type: "Boolean", defaultValue: true} tailrec: {type: "Boolean", defaultValue: true}
      vararg: {type: "Boolean", defaultValue: true} context: {type: "Boolean", defaultValue: true}
      # What every lens declares, and what a refetchable fragment and a connection add.
      anchor: {type: "Boolean", defaultValue: true} recordID: {type: "Boolean", defaultValue: true}
      satisfied: {type: "Boolean", defaultValue: true}
      missingRequiredField: {type: "Boolean", defaultValue: true}
      fieldErrors: {type: "Boolean", defaultValue: true}
      isPresent: {type: "Boolean", defaultValue: true}
      throwing: {type: "Boolean", defaultValue: true} caught: {type: "Boolean", defaultValue: true}
      refetchable: {type: "Boolean", defaultValue: true}
      refetch: {type: "Boolean", defaultValue: true}
      connection: {type: "Boolean", defaultValue: true} nodes: {type: "Boolean", defaultValue: true}
      hasNext: {type: "Boolean", defaultValue: true}
      hasPrevious: {type: "Boolean", defaultValue: true}
      isLoadingNext: {type: "Boolean", defaultValue: true}
      isLoadingPrevious: {type: "Boolean", defaultValue: true}
      connectionID: {type: "Boolean", defaultValue: true}
      loadNext: {type: "Boolean", defaultValue: true}
      loadPrevious: {type: "Boolean", defaultValue: true}
      # The locals, parameters and lambda parameters of generated bodies.
      bound: {type: "Boolean", defaultValue: true} errors: {type: "Boolean", defaultValue: true}
      child: {type: "Boolean", defaultValue: true} missing: {type: "Boolean", defaultValue: true}
      other: {type: "Boolean", defaultValue: true} it: {type: "Boolean", defaultValue: true}
      element: {type: "Boolean", defaultValue: true} count: {type: "Boolean", defaultValue: true}
      optimistic: {type: "Boolean", defaultValue: true} text: {type: "Boolean", defaultValue: true}
      fields: {type: "Boolean", defaultValue: true}
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      name: {type: "Boolean", defaultValue: true} document: {type: "Boolean", defaultValue: true}
      kind: {type: "Boolean", defaultValue: true}
      errorBehavior: {type: "Boolean", defaultValue: true}
      cacheExpirationSeconds: {type: "Boolean", defaultValue: true}
      throwsOnFieldError: {type: "Boolean", defaultValue: true}
      bubbles: {type: "Boolean", defaultValue: true}
      hasDeferred: {type: "Boolean", defaultValue: true} plan: {type: "Boolean", defaultValue: true}
      selection: {type: "Boolean", defaultValue: true}
      selection0: {type: "Boolean", defaultValue: true}
      Action: {type: "Boolean", defaultValue: true}
      OptimisticResponse: {type: "Boolean", defaultValue: true}
      invoke: {type: "Boolean", defaultValue: true} commit: {type: "Boolean", defaultValue: true}
      variable: {type: "Boolean", defaultValue: true} payload: {type: "Boolean", defaultValue: true}
      # What a class, a data class, an enum and a collection give.
      copy: {type: "Boolean", defaultValue: true} component1: {type: "Boolean", defaultValue: true}
      component2: {type: "Boolean", defaultValue: true}
      javaClass: {type: "Boolean", defaultValue: true} of: {type: "Boolean", defaultValue: true}
      scalarText: {type: "Boolean", defaultValue: true}
      Undeclared: {type: "Boolean", defaultValue: true} size: {type: "Boolean", defaultValue: true}
      keys: {type: "Boolean", defaultValue: true} values: {type: "Boolean", defaultValue: true}
      entries: {type: "Boolean", defaultValue: true}
      # The shared objects, and what they declare or spell.
      Types: {type: "Boolean", defaultValue: true} Slots: {type: "Boolean", defaultValue: true}
      AbstractSlots: {type: "Boolean", defaultValue: true}
      Sites: {type: "Boolean", defaultValue: true} Guards: {type: "Boolean", defaultValue: true}
      schemaDigest: {type: "Boolean", defaultValue: true}
      format: {type: "Boolean", defaultValue: true} transient: {type: "Boolean", defaultValue: true}
      baton: {type: "Boolean", defaultValue: true}
      MappedScalar: {type: "Boolean", defaultValue: true}
      # The runtime's names generated code spells.
      AbstractSlot: {type: "Boolean", defaultValue: true}
      Anchor: {type: "Boolean", defaultValue: true}
      ArgumentSite: {type: "Boolean", defaultValue: true}
      ConnectionCursor: {type: "Boolean", defaultValue: true}
      ConnectionPlan: {type: "Boolean", defaultValue: true}
      ConnectionSlots: {type: "Boolean", defaultValue: true}
      Document: {type: "Boolean", defaultValue: true}
      DynamicKey: {type: "Boolean", defaultValue: true} Edit: {type: "Boolean", defaultValue: true}
      ErrorBehavior: {type: "Boolean", defaultValue: true}
      FieldError: {type: "Boolean", defaultValue: true}
      FieldErrors: {type: "Boolean", defaultValue: true}
      Generated: {type: "Boolean", defaultValue: true}
      GeneratedEnum: {type: "Boolean", defaultValue: true}
      Guard: {type: "Boolean", defaultValue: true}
      InputObject: {type: "Boolean", defaultValue: true}
      KeyArgument: {type: "Boolean", defaultValue: true}
      KeyPart: {type: "Boolean", defaultValue: true} Lens: {type: "Boolean", defaultValue: true}
      LensList: {type: "Boolean", defaultValue: true} Lookup: {type: "Boolean", defaultValue: true}
      Members: {type: "Boolean", defaultValue: true}
      MutationAction: {type: "Boolean", defaultValue: true}
      MutationOperation: {type: "Boolean", defaultValue: true}
      OperationHandle: {type: "Boolean", defaultValue: true}
      OperationKind: {type: "Boolean", defaultValue: true}
      OperationType: {type: "Boolean", defaultValue: true} QueryType: {type: "Boolean", defaultValue: true} MutationType: {type: "Boolean", defaultValue: true} SubscriptionType: {type: "Boolean", defaultValue: true}
      Payload: {type: "Boolean", defaultValue: true} Plan: {type: "Boolean", defaultValue: true}
      PlanField: {type: "Boolean", defaultValue: true}
      QueryOperation: {type: "Boolean", defaultValue: true}
      Refetch: {type: "Boolean", defaultValue: true} Registry: {type: "Boolean", defaultValue: true}
      ScalarKind: {type: "Boolean", defaultValue: true}
      Selection: {type: "Boolean", defaultValue: true} Slot: {type: "Boolean", defaultValue: true}
      StorageKey: {type: "Boolean", defaultValue: true}
      SubscriptionHandle: {type: "Boolean", defaultValue: true}
      SubscriptionOperation: {type: "Boolean", defaultValue: true}
      Transient: {type: "Boolean", defaultValue: true} TypeID: {type: "Boolean", defaultValue: true}
      Format1: {type: "Boolean", defaultValue: true}
      # What generated code spells from the standard library and Compose.
      Any: {type: "Boolean", defaultValue: true} Boolean: {type: "Boolean", defaultValue: true}
      Double: {type: "Boolean", defaultValue: true} Int: {type: "Boolean", defaultValue: true}
      List: {type: "Boolean", defaultValue: true} Long: {type: "Boolean", defaultValue: true}
      Map: {type: "Boolean", defaultValue: true} Pair: {type: "Boolean", defaultValue: true}
      Result: {type: "Boolean", defaultValue: true} String: {type: "Boolean", defaultValue: true}
      Unit: {type: "Boolean", defaultValue: true} Stable: {type: "Boolean", defaultValue: true}
      JvmName: {type: "Boolean", defaultValue: true} JvmField: {type: "Boolean", defaultValue: true}
      OptIn: {type: "Boolean", defaultValue: true} run: {type: "Boolean", defaultValue: true}
      let: {type: "Boolean", defaultValue: true} takeIf: {type: "Boolean", defaultValue: true}
      map: {type: "Boolean", defaultValue: true} lazy: {type: "Boolean", defaultValue: true}
      listOf: {type: "Boolean", defaultValue: true} mapOf: {type: "Boolean", defaultValue: true}
      emptyList: {type: "Boolean", defaultValue: true}
      emptyMap: {type: "Boolean", defaultValue: true}
      mutableListOf: {type: "Boolean", defaultValue: true}
      getOrThrow: {type: "Boolean", defaultValue: true}
      success: {type: "Boolean", defaultValue: true} failure: {type: "Boolean", defaultValue: true}
    )
    @refetchable(queryName: "KotlinArgumentsRefetchQuery") {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      ... @include(if: $as) { name } ... @include(if: $break) { name }
      ... @include(if: $class) { name } ... @include(if: $continue) { name }
      ... @include(if: $do) { name } ... @include(if: $else) { name }
      ... @include(if: $false) { name } ... @include(if: $for) { name }
      ... @include(if: $fun) { name } ... @include(if: $if) { name } ... @include(if: $in) { name }
      ... @include(if: $interface) { name } ... @include(if: $is) { name }
      ... @include(if: $null) { name } ... @include(if: $object) { name }
      ... @include(if: $package) { name } ... @include(if: $return) { name }
      ... @include(if: $super) { name } ... @include(if: $this) { name }
      ... @include(if: $throw) { name } ... @include(if: $true) { name }
      ... @include(if: $try) { name } ... @include(if: $typealias) { name }
      ... @include(if: $typeof) { name } ... @include(if: $val) { name }
      ... @include(if: $var) { name } ... @include(if: $when) { name }
      ... @include(if: $while) { name } ... @include(if: $_) { name }
      # Kotlin's soft and modifier keywords.
      ... @include(if: $by) { name } ... @include(if: $catch) { name }
      ... @include(if: $constructor) { name } ... @include(if: $delegate) { name }
      ... @include(if: $dynamic) { name } ... @include(if: $field) { name }
      ... @include(if: $file) { name } ... @include(if: $finally) { name }
      ... @include(if: $get) { name } ... @include(if: $import) { name }
      ... @include(if: $init) { name } ... @include(if: $param) { name }
      ... @include(if: $property) { name } ... @include(if: $receiver) { name }
      ... @include(if: $set) { name } ... @include(if: $setparam) { name }
      ... @include(if: $value) { name } ... @include(if: $where) { name }
      ... @include(if: $abstract) { name } ... @include(if: $actual) { name }
      ... @include(if: $annotation) { name } ... @include(if: $companion) { name }
      ... @include(if: $const) { name } ... @include(if: $crossinline) { name }
      ... @include(if: $data) { name } ... @include(if: $enum) { name }
      ... @include(if: $expect) { name } ... @include(if: $external) { name }
      ... @include(if: $final) { name } ... @include(if: $infix) { name }
      ... @include(if: $inline) { name } ... @include(if: $inner) { name }
      ... @include(if: $internal) { name } ... @include(if: $lateinit) { name }
      ... @include(if: $noinline) { name } ... @include(if: $open) { name }
      ... @include(if: $operator) { name } ... @include(if: $out) { name }
      ... @include(if: $override) { name } ... @include(if: $private) { name }
      ... @include(if: $protected) { name } ... @include(if: $public) { name }
      ... @include(if: $reified) { name } ... @include(if: $sealed) { name }
      ... @include(if: $suspend) { name } ... @include(if: $tailrec) { name }
      ... @include(if: $vararg) { name } ... @include(if: $context) { name }
      # What every lens declares, and what a refetchable fragment and a connection add.
      ... @include(if: $anchor) { name } ... @include(if: $recordID) { name }
      ... @include(if: $satisfied) { name } ... @include(if: $missingRequiredField) { name }
      ... @include(if: $fieldErrors) { name } ... @include(if: $isPresent) { name }
      ... @include(if: $throwing) { name } ... @include(if: $caught) { name }
      ... @include(if: $refetchable) { name } ... @include(if: $refetch) { name }
      ... @include(if: $connection) { name } ... @include(if: $nodes) { name }
      ... @include(if: $hasNext) { name } ... @include(if: $hasPrevious) { name }
      ... @include(if: $isLoadingNext) { name } ... @include(if: $isLoadingPrevious) { name }
      ... @include(if: $connectionID) { name } ... @include(if: $loadNext) { name }
      ... @include(if: $loadPrevious) { name }
      # The locals, parameters and lambda parameters of generated bodies.
      ... @include(if: $bound) { name } ... @include(if: $errors) { name }
      ... @include(if: $child) { name } ... @include(if: $missing) { name }
      ... @include(if: $other) { name } ... @include(if: $it) { name }
      ... @include(if: $element) { name } ... @include(if: $count) { name }
      ... @include(if: $optimistic) { name } ... @include(if: $text) { name }
      ... @include(if: $fields) { name }
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      ... @include(if: $name) { name } ... @include(if: $document) { name }
      ... @include(if: $kind) { name } ... @include(if: $errorBehavior) { name }
      ... @include(if: $cacheExpirationSeconds) { name }
      ... @include(if: $throwsOnFieldError) { name } ... @include(if: $bubbles) { name }
      ... @include(if: $hasDeferred) { name } ... @include(if: $plan) { name }
      ... @include(if: $selection) { name } ... @include(if: $selection0) { name }
      ... @include(if: $Action) { name } ... @include(if: $OptimisticResponse) { name }
      ... @include(if: $invoke) { name } ... @include(if: $commit) { name }
      ... @include(if: $variable) { name } ... @include(if: $payload) { name }
      # What a class, a data class, an enum and a collection give.
      ... @include(if: $copy) { name } ... @include(if: $component1) { name }
      ... @include(if: $component2) { name } ... @include(if: $javaClass) { name }
      ... @include(if: $of) { name } ... @include(if: $scalarText) { name }
      ... @include(if: $Undeclared) { name } ... @include(if: $size) { name }
      ... @include(if: $keys) { name } ... @include(if: $values) { name }
      ... @include(if: $entries) { name }
      # The shared objects, and what they declare or spell.
      ... @include(if: $Types) { name } ... @include(if: $Slots) { name }
      ... @include(if: $AbstractSlots) { name } ... @include(if: $Sites) { name }
      ... @include(if: $Guards) { name } ... @include(if: $schemaDigest) { name }
      ... @include(if: $format) { name } ... @include(if: $transient) { name }
      ... @include(if: $baton) { name } ... @include(if: $MappedScalar) { name }
      # The runtime's names generated code spells.
      ... @include(if: $AbstractSlot) { name } ... @include(if: $Anchor) { name }
      ... @include(if: $ArgumentSite) { name } ... @include(if: $ConnectionCursor) { name }
      ... @include(if: $ConnectionPlan) { name } ... @include(if: $ConnectionSlots) { name }
      ... @include(if: $Document) { name } ... @include(if: $DynamicKey) { name }
      ... @include(if: $Edit) { name } ... @include(if: $ErrorBehavior) { name }
      ... @include(if: $FieldError) { name } ... @include(if: $FieldErrors) { name }
      ... @include(if: $Generated) { name } ... @include(if: $GeneratedEnum) { name }
      ... @include(if: $Guard) { name } ... @include(if: $InputObject) { name }
      ... @include(if: $KeyArgument) { name } ... @include(if: $KeyPart) { name }
      ... @include(if: $Lens) { name } ... @include(if: $LensList) { name }
      ... @include(if: $Lookup) { name } ... @include(if: $Members) { name }
      ... @include(if: $MutationAction) { name } ... @include(if: $MutationOperation) { name }
      ... @include(if: $OperationHandle) { name } ... @include(if: $OperationKind) { name }
      ... @include(if: $OperationType) { name } ... @include(if: $QueryType) { name } ... @include(if: $MutationType) { name } ... @include(if: $SubscriptionType) { name } ... @include(if: $Payload) { name }
      ... @include(if: $Plan) { name } ... @include(if: $PlanField) { name }
      ... @include(if: $QueryOperation) { name } ... @include(if: $Refetch) { name }
      ... @include(if: $Registry) { name } ... @include(if: $ScalarKind) { name }
      ... @include(if: $Selection) { name } ... @include(if: $Slot) { name }
      ... @include(if: $StorageKey) { name } ... @include(if: $SubscriptionHandle) { name }
      ... @include(if: $SubscriptionOperation) { name } ... @include(if: $Transient) { name }
      ... @include(if: $TypeID) { name } ... @include(if: $Format1) { name }
      # What generated code spells from the standard library and Compose.
      ... @include(if: $Any) { name } ... @include(if: $Boolean) { name }
      ... @include(if: $Double) { name } ... @include(if: $Int) { name }
      ... @include(if: $List) { name } ... @include(if: $Long) { name }
      ... @include(if: $Map) { name } ... @include(if: $Pair) { name }
      ... @include(if: $Result) { name } ... @include(if: $String) { name }
      ... @include(if: $Unit) { name } ... @include(if: $Stable) { name }
      ... @include(if: $JvmName) { name } ... @include(if: $JvmField) { name }
      ... @include(if: $OptIn) { name } ... @include(if: $run) { name }
      ... @include(if: $let) { name } ... @include(if: $takeIf) { name }
      ... @include(if: $map) { name } ... @include(if: $lazy) { name }
      ... @include(if: $listOf) { name } ... @include(if: $mapOf) { name }
      ... @include(if: $emptyList) { name } ... @include(if: $emptyMap) { name }
      ... @include(if: $mutableListOf) { name } ... @include(if: $getOrThrow) { name }
      ... @include(if: $success) { name } ... @include(if: $failure) { name }
    }
    """)
fun KotlinArguments() {}

// Each name as an argument a spread passes with `@arguments`, which the
// spread's binding names as text.
@Fragment($$"""
    fragment KotlinArgumentSpread_character on Character {
      ...KotlinArguments_character @arguments(
        # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
        as: false break: false class: false continue: false do: false else: false false: false
        for: false fun: false if: false in: false interface: false is: false null: false
        object: false package: false return: false super: false this: false throw: false true: false
        try: false typealias: false typeof: false val: false var: false when: false while: false
        _: false
        # Kotlin's soft and modifier keywords.
        by: false catch: false constructor: false delegate: false dynamic: false field: false
        file: false finally: false get: false import: false init: false param: false property: false
        receiver: false set: false setparam: false value: false where: false abstract: false
        actual: false annotation: false companion: false const: false crossinline: false data: false
        enum: false expect: false external: false final: false infix: false inline: false
        inner: false internal: false lateinit: false noinline: false open: false operator: false
        out: false override: false private: false protected: false public: false reified: false
        sealed: false suspend: false tailrec: false vararg: false context: false
        # What every lens declares, and what a refetchable fragment and a connection add.
        anchor: false recordID: false satisfied: false missingRequiredField: false
        fieldErrors: false isPresent: false throwing: false caught: false refetchable: false
        refetch: false connection: false nodes: false hasNext: false hasPrevious: false
        isLoadingNext: false isLoadingPrevious: false connectionID: false loadNext: false
        loadPrevious: false
        # The locals, parameters and lambda parameters of generated bodies.
        bound: false errors: false child: false missing: false other: false it: false element: false
        count: false optimistic: false text: false fields: false
        # What an operation value, its companion, a mutation's action and its optimistic response declare.
        name: false document: false kind: false errorBehavior: false cacheExpirationSeconds: false
        throwsOnFieldError: false bubbles: false hasDeferred: false plan: false selection: false
        selection0: false Action: false OptimisticResponse: false invoke: false commit: false
        variable: false payload: false
        # What a class, a data class, an enum and a collection give.
        copy: false component1: false component2: false javaClass: false of: false scalarText: false
        Undeclared: false size: false keys: false values: false entries: false
        # The shared objects, and what they declare or spell.
        Types: false Slots: false AbstractSlots: false Sites: false Guards: false
        schemaDigest: false format: false transient: false baton: false MappedScalar: false
        # The runtime's names generated code spells.
        AbstractSlot: false Anchor: false ArgumentSite: false ConnectionCursor: false
        ConnectionPlan: false ConnectionSlots: false Document: false DynamicKey: false Edit: false
        ErrorBehavior: false FieldError: false FieldErrors: false Generated: false
        GeneratedEnum: false Guard: false InputObject: false KeyArgument: false KeyPart: false
        Lens: false LensList: false Lookup: false Members: false MutationAction: false
        MutationOperation: false OperationHandle: false OperationKind: false OperationType: false QueryType: false MutationType: false SubscriptionType: false
        Payload: false Plan: false PlanField: false QueryOperation: false Refetch: false
        Registry: false ScalarKind: false Selection: false Slot: false StorageKey: false
        SubscriptionHandle: false SubscriptionOperation: false Transient: false TypeID: false
        Format1: false
        # What generated code spells from the standard library and Compose.
        Any: false Boolean: false Double: false Int: false List: false Long: false Map: false
        Pair: false Result: false String: false Unit: false Stable: false JvmName: false
        JvmField: false OptIn: false run: false let: false takeIf: false map: false lazy: false
        listOf: false mapOf: false emptyList: false emptyMap: false mutableListOf: false
        getOrThrow: false success: false failure: false
      )
    }
    """)
fun KotlinArgumentSpread() {}

// Each name as a scalar, a linked and a plural linked field of a mutation's
// payload: a property and a constructor parameter of the optimistic
// response's builder, and a nested builder of the name capitalized.
@Mutation($$"""
    mutation KotlinPayload {
      setFavorite(id: "1", favorite: true) {
        character {
          # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
          as: name break: name class: name continue: name do: name else: name false: name for: name
          fun: name if: name in: name interface: name is: name null: name object: name package: name
          return: name super: name this: name throw: name true: name try: name typealias: name
          typeof: name val: name var: name when: name while: name _: name
          # Kotlin's soft and modifier keywords.
          by: name catch: name constructor: name delegate: name dynamic: name field: name file: name
          finally: name get: name import: name init: name param: name property: name receiver: name
          set: name setparam: name value: name where: name abstract: name actual: name
          annotation: name companion: name const: name crossinline: name data: name enum: name
          expect: name external: name final: name infix: name inline: name inner: name
          internal: name lateinit: name noinline: name open: name operator: name out: name
          override: name private: name protected: name public: name reified: name sealed: name
          suspend: name tailrec: name vararg: name context: name
          # What every lens declares, and what a refetchable fragment and a connection add.
          satisfied: name missingRequiredField: name fieldErrors: name isPresent: name
          throwing: name caught: name refetchable: name refetch: name connection: name nodes: name
          hasNext: name hasPrevious: name isLoadingNext: name isLoadingPrevious: name
          connectionID: name loadNext: name loadPrevious: name
          # The locals, parameters and lambda parameters of generated bodies.
          bound: name errors: name child: name missing: name other: name it: name element: name
          count: name optimistic: name text: name fields: name
          # What an operation value, its companion, a mutation's action and its optimistic response declare.
          variables: name type: name resolution: name name: name document: name kind: name
          errorBehavior: name cacheExpirationSeconds: name throwsOnFieldError: name bubbles: name
          hasDeferred: name plan: name selection: name selection0: name Data: name Action: name
          OptimisticResponse: name invoke: name commit: name payload: name
          # What a class, a data class, an enum and a collection give.
          copy: name component1: name component2: name javaClass: name of: name scalarText: name
          Undeclared: name size: name keys: name values: name entries: name
          # The shared objects, and what they declare or spell.
          Types: name AbstractSlots: name Sites: name Guards: name schemaDigest: name format: name
          transient: name baton: name MappedScalar: name
          # The runtime's names generated code spells.
          AbstractSlot: name Anchor: name ArgumentSite: name ConnectionCursor: name
          ConnectionPlan: name ConnectionSlots: name Document: name DynamicKey: name Edit: name
          ErrorBehavior: name FieldError: name FieldErrors: name Generated: name GeneratedEnum: name
          Guard: name InputObject: name KeyArgument: name KeyPart: name Lens: name LensList: name
          Lookup: name Members: name MutationAction: name MutationOperation: name
          OperationHandle: name OperationKind: name OperationType: name QueryType: name MutationType: name SubscriptionType: name Payload: name Plan: name
          PlanField: name QueryOperation: name Refetch: name Registry: name Resolution: name
          ScalarKind: name Selection: name Slot: name StorageKey: name SubscriptionHandle: name
          SubscriptionOperation: name Transient: name TypeID: name Format1: name
          # What generated code spells from the standard library and Compose.
          Any: name Boolean: name Double: name Int: name List: name Long: name Map: name Pair: name
          Result: name String: name Unit: name Stable: name JvmName: name JvmField: name OptIn: name
          run: name let: name takeIf: name map: name lazy: name listOf: name mapOf: name
          emptyList: name emptyMap: name mutableListOf: name getOrThrow: name success: name
          failure: name
        }
      }
      addNote(characterId: "1", text: "hostile") {
        # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
        as: note { id } break: note { id } class: note { id } continue: note { id } do: note { id }
        else: note { id } false: note { id } for: note { id } fun: note { id } if: note { id }
        in: note { id } interface: note { id } is: note { id } null: note { id } object: note { id }
        package: note { id } return: note { id } super: note { id } this: note { id }
        throw: note { id } true: note { id } try: note { id } typealias: note { id }
        typeof: note { id } val: note { id } var: note { id } when: note { id } while: note { id }
        _: note { id }
        # Kotlin's soft and modifier keywords.
        by: note { id } catch: note { id } constructor: note { id } delegate: note { id }
        dynamic: note { id } field: note { id } file: note { id } finally: note { id }
        get: note { id } import: note { id } init: note { id } param: note { id }
        property: note { id } receiver: note { id } set: note { id } setparam: note { id }
        value: note { id } where: note { id } abstract: note { id } actual: note { id }
        annotation: note { id } companion: note { id } const: note { id } crossinline: note { id }
        data: note { id } enum: note { id } expect: note { id } external: note { id }
        final: note { id } infix: note { id } inline: note { id } inner: note { id }
        internal: note { id } lateinit: note { id } noinline: note { id } open: note { id }
        operator: note { id } out: note { id } override: note { id } private: note { id }
        protected: note { id } public: note { id } reified: note { id } sealed: note { id }
        suspend: note { id } tailrec: note { id } vararg: note { id } context: note { id }
        # What every lens declares, and what a refetchable fragment and a connection add.
        satisfied: note { id } missingRequiredField: note { id } fieldErrors: note { id }
        isPresent: note { id } throwing: note { id } caught: note { id } refetchable: note { id }
        refetch: note { id } connection: note { id } nodes: note { id } hasNext: note { id }
        hasPrevious: note { id } isLoadingNext: note { id } isLoadingPrevious: note { id }
        connectionID: note { id } loadNext: note { id } loadPrevious: note { id }
        # The locals, parameters and lambda parameters of generated bodies.
        bound: note { id } errors: note { id } child: note { id } missing: note { id }
        other: note { id } it: note { id } element: note { id } count: note { id }
        optimistic: note { id } text: note { id } fields: note { id }
        # What an operation value, its companion, a mutation's action and its optimistic response declare.
        variables: note { id } type: note { id } resolution: note { id } name: note { id }
        document: note { id } kind: note { id } errorBehavior: note { id }
        cacheExpirationSeconds: note { id } throwsOnFieldError: note { id } bubbles: note { id }
        hasDeferred: note { id } plan: note { id } selection: note { id } selection0: note { id }
        Data: note { id } Action: note { id } OptimisticResponse: note { id } invoke: note { id }
        commit: note { id } payload: note { id }
        # What a class, a data class, an enum and a collection give.
        copy: note { id } component1: note { id } component2: note { id } javaClass: note { id }
        of: note { id } scalarText: note { id } Undeclared: note { id } size: note { id }
        keys: note { id } values: note { id } entries: note { id }
        # The shared objects, and what they declare or spell.
        Types: note { id } AbstractSlots: note { id } Sites: note { id } Guards: note { id }
        schemaDigest: note { id } format: note { id } transient: note { id } baton: note { id }
        MappedScalar: note { id }
        # The runtime's names generated code spells.
        AbstractSlot: note { id } Anchor: note { id } ArgumentSite: note { id }
        ConnectionCursor: note { id } ConnectionPlan: note { id } ConnectionSlots: note { id }
        Document: note { id } DynamicKey: note { id } Edit: note { id } ErrorBehavior: note { id }
        FieldError: note { id } FieldErrors: note { id } Generated: note { id }
        GeneratedEnum: note { id } Guard: note { id } InputObject: note { id }
        KeyArgument: note { id } KeyPart: note { id } Lens: note { id } LensList: note { id }
        Lookup: note { id } Members: note { id } MutationAction: note { id }
        MutationOperation: note { id } OperationHandle: note { id } OperationKind: note { id }
        OperationType: note { id } QueryType: note { id } MutationType: note { id } SubscriptionType: note { id } Payload: note { id } Plan: note { id } PlanField: note { id }
        QueryOperation: note { id } Refetch: note { id } Registry: note { id }
        Resolution: note { id } ScalarKind: note { id } Selection: note { id } Slot: note { id }
        StorageKey: note { id } SubscriptionHandle: note { id } SubscriptionOperation: note { id }
        Transient: note { id } TypeID: note { id } Format1: note { id }
        # What generated code spells from the standard library and Compose.
        Any: note { id } Boolean: note { id } Double: note { id } Int: note { id } List: note { id }
        Long: note { id } Map: note { id } Pair: note { id } Result: note { id } String: note { id }
        Unit: note { id } Stable: note { id } JvmName: note { id } JvmField: note { id }
        OptIn: note { id } run: note { id } let: note { id } takeIf: note { id } map: note { id }
        lazy: note { id } listOf: note { id } mapOf: note { id } emptyList: note { id }
        emptyMap: note { id } mutableListOf: note { id } getOrThrow: note { id }
        success: note { id } failure: note { id }
      }
      rename(id: "1", name: "hostile") {
        character {
          # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
          as: episode { id } break: episode { id } class: episode { id } continue: episode { id }
          do: episode { id } else: episode { id } false: episode { id } for: episode { id }
          fun: episode { id } if: episode { id } in: episode { id } interface: episode { id }
          is: episode { id } null: episode { id } object: episode { id } package: episode { id }
          return: episode { id } super: episode { id } this: episode { id } throw: episode { id }
          true: episode { id } try: episode { id } typealias: episode { id } typeof: episode { id }
          val: episode { id } var: episode { id } when: episode { id } while: episode { id }
          _: episode { id }
          # Kotlin's soft and modifier keywords.
          by: episode { id } catch: episode { id } constructor: episode { id }
          delegate: episode { id } dynamic: episode { id } field: episode { id }
          file: episode { id } finally: episode { id } get: episode { id } import: episode { id }
          init: episode { id } param: episode { id } property: episode { id }
          receiver: episode { id } set: episode { id } setparam: episode { id }
          value: episode { id } where: episode { id } abstract: episode { id }
          actual: episode { id } annotation: episode { id } companion: episode { id }
          const: episode { id } crossinline: episode { id } data: episode { id }
          enum: episode { id } expect: episode { id } external: episode { id } final: episode { id }
          infix: episode { id } inline: episode { id } inner: episode { id }
          internal: episode { id } lateinit: episode { id } noinline: episode { id }
          open: episode { id } operator: episode { id } out: episode { id } override: episode { id }
          private: episode { id } protected: episode { id } public: episode { id }
          reified: episode { id } sealed: episode { id } suspend: episode { id }
          tailrec: episode { id } vararg: episode { id } context: episode { id }
          # What every lens declares, and what a refetchable fragment and a connection add.
          satisfied: episode { id } missingRequiredField: episode { id } fieldErrors: episode { id }
          isPresent: episode { id } throwing: episode { id } caught: episode { id }
          refetchable: episode { id } refetch: episode { id } connection: episode { id }
          nodes: episode { id } hasNext: episode { id } hasPrevious: episode { id }
          isLoadingNext: episode { id } isLoadingPrevious: episode { id }
          connectionID: episode { id } loadNext: episode { id } loadPrevious: episode { id }
          # The locals, parameters and lambda parameters of generated bodies.
          bound: episode { id } errors: episode { id } child: episode { id } missing: episode { id }
          other: episode { id } it: episode { id } element: episode { id } count: episode { id }
          optimistic: episode { id } text: episode { id } fields: episode { id }
          # What an operation value, its companion, a mutation's action and its optimistic response declare.
          variables: episode { id } type: episode { id } resolution: episode { id }
          name: episode { id } document: episode { id } kind: episode { id }
          errorBehavior: episode { id } cacheExpirationSeconds: episode { id }
          throwsOnFieldError: episode { id } bubbles: episode { id } hasDeferred: episode { id }
          plan: episode { id } selection: episode { id } selection0: episode { id }
          Data: episode { id } Action: episode { id } OptimisticResponse: episode { id }
          invoke: episode { id } commit: episode { id } payload: episode { id }
          # What a class, a data class, an enum and a collection give.
          copy: episode { id } component1: episode { id } component2: episode { id }
          javaClass: episode { id } of: episode { id } scalarText: episode { id }
          Undeclared: episode { id } size: episode { id } keys: episode { id }
          values: episode { id } entries: episode { id }
          # The shared objects, and what they declare or spell.
          Types: episode { id } AbstractSlots: episode { id } Sites: episode { id }
          Guards: episode { id } schemaDigest: episode { id } format: episode { id }
          transient: episode { id } baton: episode { id } MappedScalar: episode { id }
          # The runtime's names generated code spells.
          AbstractSlot: episode { id } Anchor: episode { id } ArgumentSite: episode { id }
          ConnectionCursor: episode { id } ConnectionPlan: episode { id }
          ConnectionSlots: episode { id } Document: episode { id } DynamicKey: episode { id }
          Edit: episode { id } ErrorBehavior: episode { id } FieldError: episode { id }
          FieldErrors: episode { id } Generated: episode { id } GeneratedEnum: episode { id }
          Guard: episode { id } InputObject: episode { id } KeyArgument: episode { id }
          KeyPart: episode { id } Lens: episode { id } LensList: episode { id }
          Lookup: episode { id } Members: episode { id } MutationAction: episode { id }
          MutationOperation: episode { id } OperationHandle: episode { id }
          OperationKind: episode { id } OperationType: episode { id } QueryType: episode { id } MutationType: episode { id } SubscriptionType: episode { id } Payload: episode { id }
          Plan: episode { id } PlanField: episode { id } QueryOperation: episode { id }
          Refetch: episode { id } Registry: episode { id } Resolution: episode { id }
          ScalarKind: episode { id } Selection: episode { id } Slot: episode { id }
          StorageKey: episode { id } SubscriptionHandle: episode { id }
          SubscriptionOperation: episode { id } Transient: episode { id } TypeID: episode { id }
          Format1: episode { id }
          # What generated code spells from the standard library and Compose.
          Any: episode { id } Boolean: episode { id } Double: episode { id } Int: episode { id }
          List: episode { id } Long: episode { id } Map: episode { id } Pair: episode { id }
          Result: episode { id } String: episode { id } Unit: episode { id } Stable: episode { id }
          JvmName: episode { id } JvmField: episode { id } OptIn: episode { id } run: episode { id }
          let: episode { id } takeIf: episode { id } map: episode { id } lazy: episode { id }
          listOf: episode { id } mapOf: episode { id } emptyList: episode { id }
          emptyMap: episode { id } mutableListOf: episode { id } getOrThrow: episode { id }
          success: episode { id } failure: episode { id }
        }
      }
    }
    """)
fun KotlinPayload() {}

// Each name as a property of an `@inline` fragment's value and a parameter
// of its constructor, beside every body a value can have. Each position's
// names are split across three values, which kept a constructor that read
// every field in place under the 64 KiB the JVM allows a method; a value
// reads each field through a function of its own now, so the size no
// longer needs the split, which stays ahead of the JVM's 255 parameters.
@Fragment($$"""
    fragment KotlinInlineScalars_character on Character @inline @throwOnFieldError {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: name break: name class: name continue: name do: name else: name false: name for: name
      fun: name if: name in: name interface: name is: name null: name object: name package: name
      return: name super: name this: name throw: name true: name try: name typealias: name
      typeof: name val: name var: name when: name while: name _: name
      # Kotlin's soft and modifier keywords.
      by: name catch: name constructor: name delegate: name dynamic: name field: name file: name
      finally: name get: name import: name init: name param: name property: name receiver: name
      set: name setparam: name value: name where: name abstract: name actual: name annotation: name
      companion: name const: name crossinline: name data: name enum: name expect: name
      external: name final: name infix: name inline: name inner: name internal: name lateinit: name
      noinline: name open: name operator: name out: name override: name private: name
      protected: name public: name reified: name sealed: name suspend: name tailrec: name
      vararg: name context: name
    }
    """)
fun KotlinInlineScalars() {}

// Reaches the value deferred and caught, so it has `isPresent` and
// `caught`.
@Query($$"""
    query KotlinInlineScalarsReach {
      character(id: 1) {
        ...KotlinInlineScalars_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlineScalars_character }
      }
    }
    """)
fun KotlinInlineScalarsReach() {}

@Fragment($$"""
    fragment KotlinInlineScalars2_character on Character @inline @throwOnFieldError {
      # What every lens declares, and what a refetchable fragment and a connection add.
      satisfied: name missingRequiredField: name fieldErrors: name isPresent: name throwing: name
      caught: name refetchable: name refetch: name connection: name nodes: name hasNext: name
      hasPrevious: name isLoadingNext: name isLoadingPrevious: name connectionID: name
      loadNext: name loadPrevious: name
      # The locals, parameters and lambda parameters of generated bodies.
      bound: name errors: name child: name missing: name other: name it: name element: name
      count: name optimistic: name text: name fields: name
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      variables: name type: name resolution: name name: name document: name kind: name
      errorBehavior: name cacheExpirationSeconds: name throwsOnFieldError: name bubbles: name
      hasDeferred: name plan: name selection: name selection0: name Data: name Action: name
      OptimisticResponse: name invoke: name commit: name variable: name payload: name
      # What a class, a data class, an enum and a collection give.
      copy: name component1: name component2: name javaClass: name of: name scalarText: name
      Undeclared: name size: name keys: name values: name entries: name
      # The shared objects, and what they declare or spell.
      Types: name AbstractSlots: name Sites: name Guards: name schemaDigest: name format: name
      transient: name baton: name MappedScalar: name
    }
    """)
fun KotlinInlineScalars2() {}

@Query($$"""
    query KotlinInlineScalars2Reach {
      character(id: 1) {
        ...KotlinInlineScalars2_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlineScalars2_character }
      }
    }
    """)
fun KotlinInlineScalars2Reach() {}

@Fragment($$"""
    fragment KotlinInlineScalars3_character on Character @inline @throwOnFieldError {
      # The runtime's names generated code spells.
      AbstractSlot: name Anchor: name ArgumentSite: name ConnectionCursor: name ConnectionPlan: name
      ConnectionSlots: name Document: name DynamicKey: name Edit: name ErrorBehavior: name
      FieldError: name FieldErrors: name Generated: name GeneratedEnum: name Guard: name
      InputObject: name KeyArgument: name KeyPart: name Lens: name LensList: name Lookup: name
      Members: name MutationAction: name MutationOperation: name OperationHandle: name
      OperationKind: name OperationType: name QueryType: name MutationType: name SubscriptionType: name Payload: name Plan: name PlanField: name
      QueryOperation: name Refetch: name Registry: name Resolution: name ScalarKind: name
      Selection: name Slot: name StorageKey: name SubscriptionHandle: name
      SubscriptionOperation: name Transient: name TypeID: name Format1: name
      # What generated code spells from the standard library and Compose.
      Any: name Boolean: name Double: name Int: name List: name Long: name Map: name Pair: name
      Result: name String: name Unit: name Stable: name JvmName: name JvmField: name OptIn: name
      run: name let: name takeIf: name map: name lazy: name listOf: name mapOf: name emptyList: name
      emptyMap: name mutableListOf: name getOrThrow: name success: name failure: name
    }
    """)
fun KotlinInlineScalars3() {}

@Query($$"""
    query KotlinInlineScalars3Reach {
      character(id: 1) {
        ...KotlinInlineScalars3_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlineScalars3_character }
      }
    }
    """)
fun KotlinInlineScalars3Reach() {}

// Each name as a linked field of a value, a property of a nested value
// class that takes the name capitalized.
@Fragment($$"""
    fragment KotlinInlineLinks_character on Character @inline @throwOnFieldError {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: origin { id } break: origin { id } class: origin { id } continue: origin { id }
      do: origin { id } else: origin { id } false: origin { id } for: origin { id }
      fun: origin { id } if: origin { id } in: origin { id } interface: origin { id }
      is: origin { id } null: origin { id } object: origin { id } package: origin { id }
      return: origin { id } super: origin { id } this: origin { id } throw: origin { id }
      true: origin { id } try: origin { id } typealias: origin { id } typeof: origin { id }
      val: origin { id } var: origin { id } when: origin { id } while: origin { id }
      _: origin { id }
      # Kotlin's soft and modifier keywords.
      by: origin { id } catch: origin { id } constructor: origin { id } delegate: origin { id }
      dynamic: origin { id } field: origin { id } file: origin { id } finally: origin { id }
      get: origin { id } import: origin { id } init: origin { id } param: origin { id }
      property: origin { id } receiver: origin { id } set: origin { id } setparam: origin { id }
      value: origin { id } where: origin { id } abstract: origin { id } actual: origin { id }
      annotation: origin { id } companion: origin { id } const: origin { id }
      crossinline: origin { id } data: origin { id } enum: origin { id } expect: origin { id }
      external: origin { id } final: origin { id } infix: origin { id } inline: origin { id }
      inner: origin { id } internal: origin { id } lateinit: origin { id } noinline: origin { id }
      open: origin { id } operator: origin { id } out: origin { id } override: origin { id }
      private: origin { id } protected: origin { id } public: origin { id } reified: origin { id }
      sealed: origin { id } suspend: origin { id } tailrec: origin { id } vararg: origin { id }
      context: origin { id }
    }
    """)
fun KotlinInlineLinks() {}

// Reaches the value deferred and caught, so it has `isPresent` and
// `caught`.
@Query($$"""
    query KotlinInlineLinksReach {
      character(id: 1) {
        ...KotlinInlineLinks_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlineLinks_character }
      }
    }
    """)
fun KotlinInlineLinksReach() {}

@Fragment($$"""
    fragment KotlinInlineLinks2_character on Character @inline @throwOnFieldError {
      # What every lens declares, and what a refetchable fragment and a connection add.
      satisfied: origin { id } missingRequiredField: origin { id } fieldErrors: origin { id }
      isPresent: origin { id } throwing: origin { id } caught: origin { id }
      refetchable: origin { id } refetch: origin { id } connection: origin { id }
      nodes: origin { id } hasNext: origin { id } hasPrevious: origin { id }
      isLoadingNext: origin { id } isLoadingPrevious: origin { id } connectionID: origin { id }
      loadNext: origin { id } loadPrevious: origin { id }
      # The locals, parameters and lambda parameters of generated bodies.
      bound: origin { id } errors: origin { id } child: origin { id } missing: origin { id }
      other: origin { id } it: origin { id } element: origin { id } count: origin { id }
      optimistic: origin { id } text: origin { id } fields: origin { id }
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      variables: origin { id } type: origin { id } resolution: origin { id } name: origin { id }
      document: origin { id } kind: origin { id } errorBehavior: origin { id }
      cacheExpirationSeconds: origin { id } throwsOnFieldError: origin { id } bubbles: origin { id }
      hasDeferred: origin { id } plan: origin { id } selection: origin { id }
      selection0: origin { id } Data: origin { id } Action: origin { id }
      OptimisticResponse: origin { id } invoke: origin { id } commit: origin { id }
      variable: origin { id } payload: origin { id }
      # What a class, a data class, an enum and a collection give.
      copy: origin { id } component1: origin { id } component2: origin { id }
      javaClass: origin { id } of: origin { id } scalarText: origin { id } Undeclared: origin { id }
      size: origin { id } keys: origin { id } values: origin { id } entries: origin { id }
      # The shared objects, and what they declare or spell.
      Types: origin { id } AbstractSlots: origin { id } Sites: origin { id } Guards: origin { id }
      schemaDigest: origin { id } format: origin { id } transient: origin { id }
      baton: origin { id } MappedScalar: origin { id }
    }
    """)
fun KotlinInlineLinks2() {}

@Query($$"""
    query KotlinInlineLinks2Reach {
      character(id: 1) {
        ...KotlinInlineLinks2_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlineLinks2_character }
      }
    }
    """)
fun KotlinInlineLinks2Reach() {}

@Fragment($$"""
    fragment KotlinInlineLinks3_character on Character @inline @throwOnFieldError {
      # The runtime's names generated code spells.
      AbstractSlot: origin { id } Anchor: origin { id } ArgumentSite: origin { id }
      ConnectionCursor: origin { id } ConnectionPlan: origin { id } ConnectionSlots: origin { id }
      Document: origin { id } DynamicKey: origin { id } Edit: origin { id }
      ErrorBehavior: origin { id } FieldError: origin { id } FieldErrors: origin { id }
      Generated: origin { id } GeneratedEnum: origin { id } Guard: origin { id }
      InputObject: origin { id } KeyArgument: origin { id } KeyPart: origin { id }
      Lens: origin { id } LensList: origin { id } Lookup: origin { id } Members: origin { id }
      MutationAction: origin { id } MutationOperation: origin { id } OperationHandle: origin { id }
      OperationKind: origin { id } OperationType: origin { id } QueryType: origin { id } MutationType: origin { id } SubscriptionType: origin { id } Payload: origin { id }
      Plan: origin { id } PlanField: origin { id } QueryOperation: origin { id }
      Refetch: origin { id } Registry: origin { id } Resolution: origin { id }
      ScalarKind: origin { id } Selection: origin { id } Slot: origin { id }
      StorageKey: origin { id } SubscriptionHandle: origin { id }
      SubscriptionOperation: origin { id } Transient: origin { id } TypeID: origin { id }
      Format1: origin { id }
      # What generated code spells from the standard library and Compose.
      Any: origin { id } Boolean: origin { id } Double: origin { id } Int: origin { id }
      List: origin { id } Long: origin { id } Map: origin { id } Pair: origin { id }
      Result: origin { id } String: origin { id } Unit: origin { id } Stable: origin { id }
      JvmName: origin { id } JvmField: origin { id } OptIn: origin { id } run: origin { id }
      let: origin { id } takeIf: origin { id } map: origin { id } lazy: origin { id }
      listOf: origin { id } mapOf: origin { id } emptyList: origin { id } emptyMap: origin { id }
      mutableListOf: origin { id } getOrThrow: origin { id } success: origin { id }
      failure: origin { id }
    }
    """)
fun KotlinInlineLinks3() {}

@Query($$"""
    query KotlinInlineLinks3Reach {
      character(id: 1) {
        ...KotlinInlineLinks3_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlineLinks3_character }
      }
    }
    """)
fun KotlinInlineLinks3Reach() {}

// Each name as a plural linked field of a value, a list of a nested
// value class.
@Fragment($$"""
    fragment KotlinInlinePlurals_character on Character @inline @throwOnFieldError {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      as: episode { id } break: episode { id } class: episode { id } continue: episode { id }
      do: episode { id } else: episode { id } false: episode { id } for: episode { id }
      fun: episode { id } if: episode { id } in: episode { id } interface: episode { id }
      is: episode { id } null: episode { id } object: episode { id } package: episode { id }
      return: episode { id } super: episode { id } this: episode { id } throw: episode { id }
      true: episode { id } try: episode { id } typealias: episode { id } typeof: episode { id }
      val: episode { id } var: episode { id } when: episode { id } while: episode { id }
      _: episode { id }
      # Kotlin's soft and modifier keywords.
      by: episode { id } catch: episode { id } constructor: episode { id } delegate: episode { id }
      dynamic: episode { id } field: episode { id } file: episode { id } finally: episode { id }
      get: episode { id } import: episode { id } init: episode { id } param: episode { id }
      property: episode { id } receiver: episode { id } set: episode { id } setparam: episode { id }
      value: episode { id } where: episode { id } abstract: episode { id } actual: episode { id }
      annotation: episode { id } companion: episode { id } const: episode { id }
      crossinline: episode { id } data: episode { id } enum: episode { id } expect: episode { id }
      external: episode { id } final: episode { id } infix: episode { id } inline: episode { id }
      inner: episode { id } internal: episode { id } lateinit: episode { id }
      noinline: episode { id } open: episode { id } operator: episode { id } out: episode { id }
      override: episode { id } private: episode { id } protected: episode { id }
      public: episode { id } reified: episode { id } sealed: episode { id } suspend: episode { id }
      tailrec: episode { id } vararg: episode { id } context: episode { id }
    }
    """)
fun KotlinInlinePlurals() {}

// Reaches the value deferred and caught, so it has `isPresent` and
// `caught`.
@Query($$"""
    query KotlinInlinePluralsReach {
      character(id: 1) {
        ...KotlinInlinePlurals_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlinePlurals_character }
      }
    }
    """)
fun KotlinInlinePluralsReach() {}

@Fragment($$"""
    fragment KotlinInlinePlurals2_character on Character @inline @throwOnFieldError {
      # What every lens declares, and what a refetchable fragment and a connection add.
      satisfied: episode { id } missingRequiredField: episode { id } fieldErrors: episode { id }
      isPresent: episode { id } throwing: episode { id } caught: episode { id }
      refetchable: episode { id } refetch: episode { id } connection: episode { id }
      nodes: episode { id } hasNext: episode { id } hasPrevious: episode { id }
      isLoadingNext: episode { id } isLoadingPrevious: episode { id } connectionID: episode { id }
      loadNext: episode { id } loadPrevious: episode { id }
      # The locals, parameters and lambda parameters of generated bodies.
      bound: episode { id } errors: episode { id } child: episode { id } missing: episode { id }
      other: episode { id } it: episode { id } element: episode { id } count: episode { id }
      optimistic: episode { id } text: episode { id } fields: episode { id }
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      variables: episode { id } type: episode { id } resolution: episode { id } name: episode { id }
      document: episode { id } kind: episode { id } errorBehavior: episode { id }
      cacheExpirationSeconds: episode { id } throwsOnFieldError: episode { id }
      bubbles: episode { id } hasDeferred: episode { id } plan: episode { id }
      selection: episode { id } selection0: episode { id } Data: episode { id }
      Action: episode { id } OptimisticResponse: episode { id } invoke: episode { id }
      commit: episode { id } variable: episode { id } payload: episode { id }
      # What a class, a data class, an enum and a collection give.
      copy: episode { id } component1: episode { id } component2: episode { id }
      javaClass: episode { id } of: episode { id } scalarText: episode { id }
      Undeclared: episode { id } size: episode { id } keys: episode { id } values: episode { id }
      entries: episode { id }
      # The shared objects, and what they declare or spell.
      Types: episode { id } AbstractSlots: episode { id } Sites: episode { id }
      Guards: episode { id } schemaDigest: episode { id } format: episode { id }
      transient: episode { id } baton: episode { id } MappedScalar: episode { id }
    }
    """)
fun KotlinInlinePlurals2() {}

@Query($$"""
    query KotlinInlinePlurals2Reach {
      character(id: 1) {
        ...KotlinInlinePlurals2_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlinePlurals2_character }
      }
    }
    """)
fun KotlinInlinePlurals2Reach() {}

@Fragment($$"""
    fragment KotlinInlinePlurals3_character on Character @inline @throwOnFieldError {
      # The runtime's names generated code spells.
      AbstractSlot: episode { id } Anchor: episode { id } ArgumentSite: episode { id }
      ConnectionCursor: episode { id } ConnectionPlan: episode { id }
      ConnectionSlots: episode { id } Document: episode { id } DynamicKey: episode { id }
      Edit: episode { id } ErrorBehavior: episode { id } FieldError: episode { id }
      FieldErrors: episode { id } Generated: episode { id } GeneratedEnum: episode { id }
      Guard: episode { id } InputObject: episode { id } KeyArgument: episode { id }
      KeyPart: episode { id } Lens: episode { id } LensList: episode { id } Lookup: episode { id }
      Members: episode { id } MutationAction: episode { id } MutationOperation: episode { id }
      OperationHandle: episode { id } OperationKind: episode { id } OperationType: episode { id } QueryType: episode { id } MutationType: episode { id } SubscriptionType: episode { id }
      Payload: episode { id } Plan: episode { id } PlanField: episode { id }
      QueryOperation: episode { id } Refetch: episode { id } Registry: episode { id }
      Resolution: episode { id } ScalarKind: episode { id } Selection: episode { id }
      Slot: episode { id } StorageKey: episode { id } SubscriptionHandle: episode { id }
      SubscriptionOperation: episode { id } Transient: episode { id } TypeID: episode { id }
      Format1: episode { id }
      # What generated code spells from the standard library and Compose.
      Any: episode { id } Boolean: episode { id } Double: episode { id } Int: episode { id }
      List: episode { id } Long: episode { id } Map: episode { id } Pair: episode { id }
      Result: episode { id } String: episode { id } Unit: episode { id } Stable: episode { id }
      JvmName: episode { id } JvmField: episode { id } OptIn: episode { id } run: episode { id }
      let: episode { id } takeIf: episode { id } map: episode { id } lazy: episode { id }
      listOf: episode { id } mapOf: episode { id } emptyList: episode { id }
      emptyMap: episode { id } mutableListOf: episode { id } getOrThrow: episode { id }
      success: episode { id } failure: episode { id }
    }
    """)
fun KotlinInlinePlurals3() {}

@Query($$"""
    query KotlinInlinePlurals3Reach {
      character(id: 1) {
        ...KotlinInlinePlurals3_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlinePlurals3_character }
      }
    }
    """)
fun KotlinInlinePlurals3Reach() {}

// The value the values' aliased spreads spread.
@Fragment($$"""
    fragment KotlinInlineSpreadTarget_character on Character @inline {
      name
    }
    """)
fun KotlinInlineSpreadTarget() {}

// Each name as an aliased spread of a value inside a value.
@Fragment($$"""
    fragment KotlinInlineSpreads_character on Character @inline @throwOnFieldError {
      # Kotlin's hard keywords, as `escape` lists them, and a name of underscores alone.
      ... @alias(as: "as") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "break") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "class") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "continue") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "do") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "else") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "false") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "for") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "fun") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "if") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "in") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "interface") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "is") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "null") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "object") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "package") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "return") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "super") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "this") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "throw") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "true") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "try") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "typealias") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "typeof") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "val") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "var") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "when") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "while") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "_") { ...KotlinInlineSpreadTarget_character }
      # Kotlin's soft and modifier keywords.
      ... @alias(as: "by") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "catch") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "constructor") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "delegate") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "dynamic") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "field") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "file") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "finally") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "get") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "import") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "init") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "param") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "property") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "receiver") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "set") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "setparam") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "value") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "where") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "abstract") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "actual") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "annotation") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "companion") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "const") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "crossinline") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "data") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "enum") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "expect") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "external") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "final") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "infix") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "inline") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "inner") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "internal") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "lateinit") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "noinline") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "open") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "operator") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "out") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "override") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "private") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "protected") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "public") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "reified") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "sealed") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "suspend") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "tailrec") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "vararg") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "context") { ...KotlinInlineSpreadTarget_character }
    }
    """)
fun KotlinInlineSpreads() {}

// Reaches the value deferred and caught, so it has `isPresent` and
// `caught`.
@Query($$"""
    query KotlinInlineSpreadsReach {
      character(id: 1) {
        ...KotlinInlineSpreads_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlineSpreads_character }
      }
    }
    """)
fun KotlinInlineSpreadsReach() {}

@Fragment($$"""
    fragment KotlinInlineSpreads2_character on Character @inline @throwOnFieldError {
      # What every lens declares, and what a refetchable fragment and a connection add.
      ... @alias(as: "satisfied") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "missingRequiredField") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "fieldErrors") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "isPresent") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "throwing") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "caught") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "refetchable") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "refetch") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "connection") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "nodes") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "hasNext") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "hasPrevious") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "isLoadingNext") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "isLoadingPrevious") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "connectionID") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "loadNext") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "loadPrevious") { ...KotlinInlineSpreadTarget_character }
      # The locals, parameters and lambda parameters of generated bodies.
      ... @alias(as: "bound") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "errors") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "child") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "missing") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "other") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "it") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "element") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "count") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "optimistic") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "text") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "fields") { ...KotlinInlineSpreadTarget_character }
      # What an operation value, its companion, a mutation's action and its optimistic response declare.
      ... @alias(as: "variables") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "type") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "resolution") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "name") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "document") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "kind") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "errorBehavior") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "cacheExpirationSeconds") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "throwsOnFieldError") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "bubbles") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "hasDeferred") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "plan") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "selection") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "selection0") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Data") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Action") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "OptimisticResponse") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "invoke") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "commit") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "variable") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "payload") { ...KotlinInlineSpreadTarget_character }
      # What a class, a data class, an enum and a collection give.
      ... @alias(as: "copy") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "component1") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "component2") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "javaClass") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "of") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "scalarText") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Undeclared") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "size") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "keys") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "values") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "entries") { ...KotlinInlineSpreadTarget_character }
      # The shared objects, and what they declare or spell.
      ... @alias(as: "Types") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Slots") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "AbstractSlots") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Sites") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Guards") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "schemaDigest") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "format") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "transient") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "baton") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "MappedScalar") { ...KotlinInlineSpreadTarget_character }
    }
    """)
fun KotlinInlineSpreads2() {}

@Query($$"""
    query KotlinInlineSpreads2Reach {
      character(id: 1) {
        ...KotlinInlineSpreads2_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlineSpreads2_character }
      }
    }
    """)
fun KotlinInlineSpreads2Reach() {}

@Fragment($$"""
    fragment KotlinInlineSpreads3_character on Character @inline @throwOnFieldError {
      # The runtime's names generated code spells.
      ... @alias(as: "AbstractSlot") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Anchor") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "ArgumentSite") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "ConnectionCursor") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "ConnectionPlan") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "ConnectionSlots") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Document") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "DynamicKey") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Edit") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "ErrorBehavior") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "FieldError") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "FieldErrors") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Generated") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "GeneratedEnum") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Guard") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "InputObject") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "KeyArgument") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "KeyPart") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Lens") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "LensList") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Lookup") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Members") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "MutationAction") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "MutationOperation") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "OperationHandle") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "OperationKind") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "OperationType") { ...KotlinInlineSpreadTarget_character } ... @alias(as: "QueryType") { ...KotlinInlineSpreadTarget_character } ... @alias(as: "MutationType") { ...KotlinInlineSpreadTarget_character } ... @alias(as: "SubscriptionType") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Payload") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Plan") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "PlanField") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "QueryOperation") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Refetch") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Registry") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Resolution") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "ScalarKind") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Selection") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Slot") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "StorageKey") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "SubscriptionHandle") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "SubscriptionOperation") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Transient") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "TypeID") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Format1") { ...KotlinInlineSpreadTarget_character }
      # What generated code spells from the standard library and Compose.
      ... @alias(as: "Any") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Boolean") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Double") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Int") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "List") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Long") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Map") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Pair") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Result") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "String") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Unit") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "Stable") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "JvmName") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "JvmField") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "OptIn") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "run") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "let") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "takeIf") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "map") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "lazy") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "listOf") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "mapOf") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "emptyList") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "emptyMap") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "mutableListOf") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "getOrThrow") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "success") { ...KotlinInlineSpreadTarget_character }
      ... @alias(as: "failure") { ...KotlinInlineSpreadTarget_character }
    }
    """)
fun KotlinInlineSpreads3() {}

@Query($$"""
    query KotlinInlineSpreads3Reach {
      character(id: 1) {
        ...KotlinInlineSpreads3_character @defer
        ... @alias(as: "caughtValue") @catch { ...KotlinInlineSpreads3_character }
      }
    }
    """)
fun KotlinInlineSpreads3Reach() {}

// A lens whose field is named like its class.
@Fragment($$"""
    fragment KotlinNamesakeField_character on Character {
      KotlinNamesakeField_character: name
    }
    """)
fun KotlinNamesakeField() {}

// A fragment and an inline fragment named like the declarations that hold an
// operation's plan selections, spread in every form by a lens and by queries
// whose plans hold as many selections: no lens sees the selections, so each
// spread reads the fragment's class.
@Fragment($$"""
    fragment selection0 on Character
      @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) @throwOnFieldError {
      name @include(if: $flag)
    }
    """)
fun KotlinSelectionNamedFragment() {}

@Fragment($$"""
    fragment KotlinSelectionSpreader_character on Character {
      ... @alias(as: "boundSpread") { ...selection0 @arguments(flag: false) }
      ...selection0
      ... @alias(as: "caughtSpread") @catch { ...selection0 }
    }
    """)
fun KotlinSelectionSpreader() {}

@Query($$"""
    query KotlinSelectionDeferring { character(id: 1) { ...selection0 @defer } }
    """)
fun KotlinSelectionDeferring() {}

@Fragment($$"""
    fragment selection1 on Character @inline
      @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) @throwOnFieldError {
      name @include(if: $flag)
    }
    """)
fun KotlinSelectionNamedValue() {}

@Query($$"""
    query KotlinSelectionValues($flag: Boolean!) {
      character(id: 1) {
        ...selection1
        ...selection1 @arguments(flag: false) @alias(as: "boundValue")
        ...selection1 @include(if: $flag) @alias(as: "conditionalValue")
        ... @alias(as: "caughtValue") @catch { ...selection1 }
      }
    }
    """)
fun KotlinSelectionValues() {}

@Query($$"""
    query KotlinSelectionValueDeferring { character(id: 1) { ...selection1 @defer } }
    """)
fun KotlinSelectionValueDeferring() {}

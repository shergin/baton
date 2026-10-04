/// Marks a property as holding a fragment's lens and carries the fragment's
/// GraphQL. The compiler reads the text from source; the macro only keeps the
/// property a plain stored property so the memberwise initializer takes the lens.
@attached(peer)
public macro Fragment(_ document: StaticString) = #externalMacro(module: "BatonMacros", type: "FragmentMacro")

/// Marks a property as an operation value and carries the operation's GraphQL.
/// The parent passes the variables; the body reads the resolved handle. The
/// fetch policy decides what the store may answer and when the network is asked.
@attached(accessor, names: named(init), named(get))
@attached(peer, names: prefixed(_))
public macro Query(_ document: StaticString, fetchPolicy: FetchPolicy = .default) = #externalMacro(module: "BatonMacros", type: "QueryMacro")

/// Marks a mutation and carries its GraphQL. The property's type is the
/// operation's `Action`; calling it commits the mutation.
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(_))
public macro Mutation(_ document: StaticString) = #externalMacro(module: "BatonMacros", type: "MutationMacro")

/// Marks a property as a subscription value and carries its GraphQL. The
/// parent passes the variables; the storage subscribes while the view lives
/// and the body reads the resolved handle: its events, latest data and error.
@attached(accessor, names: named(init), named(get))
@attached(peer, names: prefixed(_))
public macro Subscription(_ document: StaticString) = #externalMacro(module: "BatonMacros", type: "SubscriptionMacro")

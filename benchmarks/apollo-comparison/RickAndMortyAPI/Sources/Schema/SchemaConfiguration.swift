// @generated
// This file was automatically generated and can be edited to
// provide custom configuration for a generated GraphQL schema.
//
// Any changes to this file will not be overwritten by future
// code generation execution.

import ApolloAPI

nonisolated public enum SchemaConfiguration: ApolloAPI.SchemaConfiguration {
  public static func cacheKeyInfo(for type: ApolloAPI.Object, object: ApolloAPI.ObjectData) -> CacheKeyInfo? {
    // Entities are keyed by typename and id, as Baton keys them; objects without an id
    // (Characters, Info) stay path-keyed, as they do in Baton.
    try? CacheKeyInfo(jsonValue: object["id"])
  }
}

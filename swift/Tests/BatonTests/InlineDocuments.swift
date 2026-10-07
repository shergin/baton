import Baton

/// The documents that prove `@inline`: a value of scalars, a link and a
/// plural link that spreads another value; a lens that spreads a value, as
/// a row does for the sheet it opens; a value with arguments; a value under
/// `@throwOnFieldError` with mapped scalars and a caught field; a value on
/// a union, read through its type conditions; and the spread forms a query
/// gives a value: plain, conditional, deferred and caught under an alias.
@MainActor
struct InlineDocuments {
    @Fragment("""
        fragment TestOriginValue_location on Location @inline {
          id
          name
          dimension
        }
        """)
    var originValue: TestOriginValue_location

    @Fragment("""
        fragment TestCharacterValue_character on Character @inline {
          id
          name
          status
          origin { ...TestOriginValue_location }
          episode { id name }
        }
        """)
    var characterValue: TestCharacterValue_character

    @Fragment("""
        fragment TestCard_character on Character {
          name
          ...TestCharacterValue_character
        }
        """)
    var card: TestCard_character

    @Fragment("""
        fragment TestNotesValue_character on Character
          @inline
          @argumentDefinitions(count: { type: "Int", defaultValue: 2 }) {
          notes(first: $count) { totalCount }
        }
        """)
    var notesValue: TestNotesValue_character

    @Fragment("""
        fragment TestAssetValue_asset on Asset @inline @throwOnFieldError {
          uuid
          name
          price
          listedAt
          page
          prices
          caughtSize: size @catch
        }
        """)
    var assetValue: TestAssetValue_asset

    @Fragment("""
        fragment TestResultValue_searchResult on SearchResult @inline {
          ... on Character { name status }
          ... on Location { name dimension }
        }
        """)
    var resultValue: TestResultValue_searchResult

    @Query("""
        query TestInlineQuery($id: ID!, $withNotes: Boolean!) {
          character(id: $id) {
            ...TestCard_character
            ...TestNotesValue_character @arguments(count: 1) @include(if: $withNotes) @alias(as: "notesValue")
          }
        }
        """)
    var inlineQuery: TestInlineQuery

    @Query("""
        query TestDeferredValueQuery($id: ID!) {
          character(id: $id) {
            id
            ...TestCharacterValue_character @defer
          }
        }
        """)
    var deferredValueQuery: TestDeferredValueQuery

    @Query("""
        query TestCaughtValueQuery($id: ID!) {
          character(id: $id) {
            id
            ... @alias(as: "caughtValue") @catch { ...TestCharacterValue_character }
          }
        }
        """)
    var caughtValueQuery: TestCaughtValueQuery

    @Query("""
        query TestAssetValuesQuery {
          assets { ...TestAssetValue_asset }
        }
        """)
    var assetValuesQuery: TestAssetValuesQuery

    @Query("""
        query TestResultValuesQuery($name: String!) {
          search(name: $name) { ...TestResultValue_searchResult }
        }
        """)
    var resultValuesQuery: TestResultValuesQuery
}

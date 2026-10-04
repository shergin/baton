import Baton

/// The document behind the tokenizer fixture in `spec/tokenizer/`: every
/// scalar kind, alone and in a list.
@MainActor
struct TokenizerDocuments {
    @Query("""
        query TestTokenizerQuery {
          tokenizer {
            id
            text
            strings
            count
            counts
            ratio
            ratios
            flag
            flags
            json
            jsons
          }
        }
        """)
    var tokenizer: TestTokenizerQuery
}

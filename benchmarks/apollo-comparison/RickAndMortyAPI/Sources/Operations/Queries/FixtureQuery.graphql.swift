// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct FixtureQuery: GraphQLQuery {
  public static let operationName: String = "Fixture"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query Fixture($page: Int) { characters(page: $page) { __typename info { __typename count pages next prev } results { __typename id name status species type gender image created origin { __typename id name type dimension created } location { __typename id name type dimension created } episode { __typename id name air_date episode created characters { __typename id name image } } } } }"#
    ))

  public var page: GraphQLNullable<Int32>

  public init(page: GraphQLNullable<Int32>) {
    self.page = page
  }

  @_spi(Unsafe) public var __variables: Variables? { ["page": page] }

  nonisolated public struct Data: RickAndMortyAPI.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { RickAndMortyAPI.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("characters", Characters?.self, arguments: ["page": .variable("page")]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      FixtureQuery.Data.self
    ] }

    public var characters: Characters? { __data["characters"] }

    /// Characters
    ///
    /// Parent Type: `Characters`
    nonisolated public struct Characters: RickAndMortyAPI.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { RickAndMortyAPI.Objects.Characters }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("info", Info?.self),
        .field("results", [Result?]?.self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        FixtureQuery.Data.Characters.self
      ] }

      public var info: Info? { __data["info"] }
      public var results: [Result?]? { __data["results"] }

      /// Characters.Info
      ///
      /// Parent Type: `Info`
      nonisolated public struct Info: RickAndMortyAPI.SelectionSet {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { RickAndMortyAPI.Objects.Info }
        @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("count", Int?.self),
          .field("pages", Int?.self),
          .field("next", Int?.self),
          .field("prev", Int?.self),
        ] }
        @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          FixtureQuery.Data.Characters.Info.self
        ] }

        public var count: Int? { __data["count"] }
        public var pages: Int? { __data["pages"] }
        public var next: Int? { __data["next"] }
        public var prev: Int? { __data["prev"] }
      }

      /// Characters.Result
      ///
      /// Parent Type: `Character`
      nonisolated public struct Result: RickAndMortyAPI.SelectionSet {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { RickAndMortyAPI.Objects.Character }
        @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("id", RickAndMortyAPI.ID?.self),
          .field("name", String?.self),
          .field("status", String?.self),
          .field("species", String?.self),
          .field("type", String?.self),
          .field("gender", String?.self),
          .field("image", String?.self),
          .field("created", String?.self),
          .field("origin", Origin?.self),
          .field("location", Location?.self),
          .field("episode", [Episode?].self),
        ] }
        @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          FixtureQuery.Data.Characters.Result.self
        ] }

        public var id: RickAndMortyAPI.ID? { __data["id"] }
        public var name: String? { __data["name"] }
        public var status: String? { __data["status"] }
        public var species: String? { __data["species"] }
        public var type: String? { __data["type"] }
        public var gender: String? { __data["gender"] }
        public var image: String? { __data["image"] }
        public var created: String? { __data["created"] }
        public var origin: Origin? { __data["origin"] }
        public var location: Location? { __data["location"] }
        public var episode: [Episode?] { __data["episode"] }

        /// Characters.Result.Origin
        ///
        /// Parent Type: `Location`
        nonisolated public struct Origin: RickAndMortyAPI.SelectionSet {
          @_spi(Unsafe) public let __data: DataDict
          @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

          @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { RickAndMortyAPI.Objects.Location }
          @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", RickAndMortyAPI.ID?.self),
            .field("name", String?.self),
            .field("type", String?.self),
            .field("dimension", String?.self),
            .field("created", String?.self),
          ] }
          @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            FixtureQuery.Data.Characters.Result.Origin.self
          ] }

          public var id: RickAndMortyAPI.ID? { __data["id"] }
          public var name: String? { __data["name"] }
          public var type: String? { __data["type"] }
          public var dimension: String? { __data["dimension"] }
          public var created: String? { __data["created"] }
        }

        /// Characters.Result.Location
        ///
        /// Parent Type: `Location`
        nonisolated public struct Location: RickAndMortyAPI.SelectionSet {
          @_spi(Unsafe) public let __data: DataDict
          @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

          @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { RickAndMortyAPI.Objects.Location }
          @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", RickAndMortyAPI.ID?.self),
            .field("name", String?.self),
            .field("type", String?.self),
            .field("dimension", String?.self),
            .field("created", String?.self),
          ] }
          @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            FixtureQuery.Data.Characters.Result.Location.self
          ] }

          public var id: RickAndMortyAPI.ID? { __data["id"] }
          public var name: String? { __data["name"] }
          public var type: String? { __data["type"] }
          public var dimension: String? { __data["dimension"] }
          public var created: String? { __data["created"] }
        }

        /// Characters.Result.Episode
        ///
        /// Parent Type: `Episode`
        nonisolated public struct Episode: RickAndMortyAPI.SelectionSet {
          @_spi(Unsafe) public let __data: DataDict
          @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

          @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { RickAndMortyAPI.Objects.Episode }
          @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", RickAndMortyAPI.ID?.self),
            .field("name", String?.self),
            .field("air_date", String?.self),
            .field("episode", String?.self),
            .field("created", String?.self),
            .field("characters", [Character?].self),
          ] }
          @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            FixtureQuery.Data.Characters.Result.Episode.self
          ] }

          public var id: RickAndMortyAPI.ID? { __data["id"] }
          public var name: String? { __data["name"] }
          public var air_date: String? { __data["air_date"] }
          public var episode: String? { __data["episode"] }
          public var created: String? { __data["created"] }
          public var characters: [Character?] { __data["characters"] }

          /// Characters.Result.Episode.Character
          ///
          /// Parent Type: `Character`
          nonisolated public struct Character: RickAndMortyAPI.SelectionSet {
            @_spi(Unsafe) public let __data: DataDict
            @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

            @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { RickAndMortyAPI.Objects.Character }
            @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("id", RickAndMortyAPI.ID?.self),
              .field("name", String?.self),
              .field("image", String?.self),
            ] }
            @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              FixtureQuery.Data.Characters.Result.Episode.Character.self
            ] }

            public var id: RickAndMortyAPI.ID? { __data["id"] }
            public var name: String? { __data["name"] }
            public var image: String? { __data["image"] }
          }
        }
      }
    }
  }
}

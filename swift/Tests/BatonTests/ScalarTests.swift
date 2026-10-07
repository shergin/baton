@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

/// Custom scalars the tests' `baton.json` maps to `Foundation.Decimal`,
/// `Foundation.Date` and `Foundation.URL`, read from `spec/tests/asset-prices`:
/// a1 holds values every type converts, b2 and c3 values some cannot hold.
@MainActor
@Suite("Mapped scalars", .timeLimit(.minutes(1)))
struct ScalarTests {
    /// What a store reported while lenses read it, by storage key.
    final class Reports: @unchecked Sendable {
        var missing: [String] = []
        var unexpected: [String] = []
    }

    /// A store that has committed the three assets, from `response` or the
    /// fixture.
    func store(_ reports: Reports, response: Data = fixture("asset-prices")) throws -> Store {
        let store = Store()
        store.log = { event in
            switch event {
            case .missing(let type, let field): reports.missing.append(type + "." + field)
            case .unexpected(let type, let field): reports.unexpected.append(type + "." + field)
            default: break
            }
        }
        let query = TestAssetPricesQuery()
        store.commit(try Ingest.normalize(response, plan: TestAssetPricesQuery.plan.resolve(query.variables, in: store.keys)))
        return store
    }

    /// The asset at `index` of the query's list.
    func asset(_ index: Int, in store: Store) throws -> TestAssetPricesQuery.Data.Assets {
        let data = TestAssetPricesQuery.Data(anchor: Anchor(record: store.root, variables: TestAssetPricesQuery().variables, store: store))
        return try #require(data.assets?.element(index))
    }

    /// The asset `uuid` as an element of `TestPricedAssetsQuery`, which
    /// spreads the three fragments.
    func pricedAsset(_ uuid: String, in store: Store) throws -> TestPricedAssetsQuery.Data.AssetsPricedAbove {
        let record = try #require(store.existing("Asset:\(uuid)"))
        let query = TestPricedAssetsQuery(price: 1)
        return TestPricedAssetsQuery.Data.AssetsPricedAbove(anchor: Anchor(record: record, variables: query.variables, store: store))
    }

    @Test("a decimal of twenty-nine digits reads back exactly, not as the Double nearest to it")
    func anExactDecimalRoundTrips() throws {
        let reports = Reports()
        let store = try store(reports)
        let price = try #require(try asset(0, in: store).price)
        let text = "12345678901234567890.123456789"
        #expect(price == Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")))
        #expect(price.scalarText == text)
        #expect(price != Decimal(Double(text)!), "a Double holds about seventeen digits")
        #expect(reports.unexpected.isEmpty)
    }

    @Test("a date with fractional seconds and one without both read as dates, and a date is written with fractional seconds")
    func datesReadWithAndWithoutFractions() throws {
        let reports = Reports()
        let store = try store(reports)
        let fractional = try #require(try asset(0, in: store).listedAt)
        let whole = try #require(try asset(1, in: store).listedAt)
        #expect(fractional.timeIntervalSince(whole) == 0.25)
        #expect(fractional.scalarText == "2026-10-11T09:30:00.250Z")
        #expect(whole.scalarText == "2026-10-11T09:30:00.000Z")
        #expect(Date(scalarText: whole.scalarText) == whole)
        #expect(reports.unexpected.isEmpty)
    }

    @Test("a URL reads, and an empty page reads as nil and is reported as unexpected once")
    func anEmptyURLReadsAsNil() throws {
        let reports = Reports()
        let store = try store(reports)
        #expect(try asset(0, in: store).page == URL(string: "https://example.com/assets/a1"))
        #expect(reports.unexpected.isEmpty)
        #expect(try asset(1, in: store).page == nil)
        #expect(reports.unexpected == ["Asset.page"])
        #expect(try asset(2, in: store).page == nil, "a null page is a null, not a failure")
        #expect(reports.unexpected == ["Asset.page"])
        #expect(reports.missing.isEmpty)
    }

    @Test("a price that does not convert reads as nil and is reported as unexpected once, never as missing")
    func anUnconvertiblePriceReadsAsNil() throws {
        let reports = Reports()
        let store = try store(reports)
        #expect(try asset(1, in: store).price == nil)
        #expect(reports.unexpected == ["Asset.price"])
        #expect(reports.missing.isEmpty, "a refetch would bring the same text")
        #expect(try asset(2, in: store).listedAt == nil)
        #expect(reports.unexpected == ["Asset.price", "Asset.listedAt"])
    }

    @Test("a list of decimals reads each one, and an element that does not convert reads as nil beside the null, reported once")
    func listsOfDecimals() throws {
        let reports = Reports()
        let store = try store(reports)
        let prices = try #require(try asset(0, in: store).prices)
        #expect(prices == [Decimal(string: "1.5"), Decimal(2), Decimal(string: "0.001")])
        #expect(reports.unexpected.isEmpty)
        let mixed = try #require(try asset(1, in: store).prices)
        #expect(mixed == [Decimal(string: "3.25"), nil, nil], "the elements are nullable, so `many` reads as nil as the null does")
        #expect(reports.unexpected == ["Asset.prices"])
        #expect(try asset(2, in: store).prices == nil)
    }

    @Test("a UUID is written as its text and read back as the same UUID")
    func aUUIDRoundTrips() throws {
        let uuid = UUID()
        #expect(UUID(scalarText: uuid.scalarText) == uuid)
        #expect(UUID(scalarText: uuid.uuidString.lowercased()) == uuid)
        #expect(UUID(scalarText: "a1") == nil)
    }

    @Test("@catch on a nullable decimal fails with the conversion's error at its path, succeeds with the value, and reads a null as nil")
    func caughtPrice() throws {
        let reports = Reports()
        let store = try store(reports)
        let converted = try pricedAsset("a1", in: store).testCaughtPrices.price
        #expect(try converted.get() == Decimal(string: "12345678901234567890.123456789", locale: Locale(identifier: "en_US_POSIX")))
        guard case .failure(let failure) = try pricedAsset("b2", in: store).testCaughtPrices.price else {
            Issue.record("b2's price does not convert")
            return
        }
        #expect(failure.errors == [FieldError.conversion(path: "price", to: Decimal.self)])
        #expect(failure.errors.first?.path == "price")
        #expect(try pricedAsset("c3", in: store).testCaughtPrices.price.get() == nil)
    }

    @Test("@catch on a non-null date fails with the conversion's error when the text does not convert and with the null's when it is null")
    func caughtListedAt() throws {
        let reports = Reports()
        let store = try store(reports)
        #expect(try pricedAsset("b2", in: store).testCaughtPrices.listedAt.get().scalarText == "2026-10-11T09:30:00.000Z")
        guard case .failure(let conversion) = try pricedAsset("c3", in: store).testCaughtPrices.listedAt else {
            Issue.record("c3's listedAt is `yesterday`, which does not convert")
            return
        }
        #expect(conversion.errors == [FieldError.conversion(path: "listedAt", to: Date.self)])

        let nulled = try Oracle.replacing("assets.2.listedAt", with: .null, in: fixture("asset-prices"))
        let nullStore = try self.store(Reports(), response: nulled)
        guard case .failure(let null) = try pricedAsset("c3", in: nullStore).testCaughtPrices.listedAt else {
            Issue.record("a null in a non-null mapped field has no value to read")
            return
        }
        #expect(null.errors == [FieldError.null(path: "listedAt")])
    }

    @Test("@catch(to: NULL) on a URL reads a text that does not convert as nil")
    func caughtToNullPage() throws {
        let store = try store(Reports())
        #expect(try pricedAsset("a1", in: store).testCaughtPrices.page == URL(string: "https://example.com/assets/a1"))
        #expect(try pricedAsset("b2", in: store).testCaughtPrices.page == nil)
    }

    @Test("a @throwOnFieldError fragment throws the conversion's error where a price does not convert and reads where it does")
    func throwingPrices() throws {
        let store = try store(Reports())
        let fragment = try pricedAsset("a1", in: store).testThrowingPrices
        #expect(fragment.price == Decimal(string: "12345678901234567890.123456789", locale: Locale(identifier: "en_US_POSIX")))
        #expect(fragment.prices == [Decimal(string: "1.5"), Decimal(2), Decimal(string: "0.001")])
        do {
            _ = try pricedAsset("b2", in: store).testThrowingPrices
            Issue.record("b2's price does not convert, so the fragment throws")
        } catch let error as FieldErrors {
            #expect(error.errors == [FieldError.conversion(path: "price", to: Decimal.self)])
        }
    }

    @Test("a @throwOnFieldError fragment reads a schema-nullable price and list that are null as nil, without throwing or reporting")
    func throwingPricesReadNullsAsNil() throws {
        let reports = Reports()
        let store = try store(reports)
        let fragment = try pricedAsset("c3", in: store).testThrowingPrices
        #expect(fragment.price == nil)
        #expect(fragment.prices == nil)
        #expect(reports.unexpected.isEmpty, "a null is data, not a value the type cannot hold")
        #expect(reports.missing.isEmpty)
    }

    @Test("a @required(action: NONE) decimal leaves its fragment unsatisfied where the price does not convert or is null, and satisfied where it converts")
    func requiredPrice() throws {
        let reports = Reports()
        let store = try store(reports)
        let satisfied = try #require(try pricedAsset("a1", in: store).testRequiredPrice)
        #expect(try satisfied.price.scalarText == "12345678901234567890.123456789")
        #expect(try pricedAsset("b2", in: store).testRequiredPrice == nil)
        #expect(reports.unexpected == ["Asset.price"])
        #expect(try pricedAsset("c3", in: store).testRequiredPrice == nil)
        #expect(reports.unexpected == ["Asset.price"], "a null is not unexpected")
        #expect(reports.missing.isEmpty)
    }

    @Test("a mapped variable and a list of them are sent as their text")
    func mappedVariablesAreSentAsText() throws {
        let query = TestPricedAssetsQuery(price: try #require(Decimal(string: "1.50")), among: [try #require(Decimal(string: "2.25")), try #require(Decimal(string: "0.001"))])
        #expect(query.variables.json == #"{"among":["2.25","0.001"],"price":"1.5"}"#)
        #expect(TestPricedAssetsQuery(price: 2).variables.json == #"{"price":"2"}"#)
    }
}

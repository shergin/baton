import Baton

/// Documents over the custom scalars `baton.json` maps to Foundation types:
/// `Decimal`, `DateTime` and `Url` on `Asset`. One query reads each mapped
/// field plainly and a list of them; three fragments read them under
/// `@catch` on a nullable and on a non-null field, under
/// `@throwOnFieldError` and under `@required(action: NONE)`; and an
/// operation takes a mapped variable and a list of them, which it sends as
/// their text.
@MainActor
struct ScalarDocuments {
    @Query("""
        query TestAssetPricesQuery { assets { uuid price listedAt page prices } }
        """)
    var assetPrices: TestAssetPricesQuery

    @Fragment("""
        fragment TestCaughtPrices_asset on Asset { price @catch listedAt @catch page @catch(to: NULL) }
        """)
    var caughtPrices: TestCaughtPrices_asset

    @Fragment("""
        fragment TestThrowingPrices_asset on Asset @throwOnFieldError { price prices }
        """)
    var throwingPrices: TestThrowingPrices_asset

    @Fragment("""
        fragment TestRequiredPrice_asset on Asset { price @required(action: NONE) }
        """)
    var requiredPrice: TestRequiredPrice_asset

    @Query("""
        query TestPricedAssetsQuery($price: Decimal!, $among: [Decimal!]) {
          assetsPricedAbove(price: $price, among: $among) {
            uuid
            ...TestCaughtPrices_asset
            ...TestThrowingPrices_asset
            ...TestRequiredPrice_asset
          }
        }
        """)
    var pricedAssets: TestPricedAssetsQuery
}

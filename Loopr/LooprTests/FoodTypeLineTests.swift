import FoodKit
import Foundation
import Testing
@testable import Loopr

/// Food ICP round 2: typed and spoken lines split into foods only when every part is a food Loopr knows.
struct FoodTypeLineTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test(arguments: [
        ("2 eggs and toast", ["2 eggs", "toast"]),
        ("toast with butter", ["toast", "butter"]),
        ("two eggs, a banana", ["two eggs", "a banana"]),
        ("fish and chips", ["fish and chips"]),
        ("mac and cheese", ["mac and cheese"]),
        ("greek yoghurt", ["greek yoghurt"]),
        ("150 g chicken\nbanana", ["150 g chicken", "banana"]),
    ])
    func linesSplitOnlyIntoKnownFoods(text: String, expected: [String]) {
        #expect(FoodCaptureModel.expanded(text, reference: FoodReference.shared, now: now) == expected)
    }
}

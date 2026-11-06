import CoreFoundation
import Foundation

public enum FoodBarcodeError: Error, Equatable, Sendable, LocalizedError {
    case invalidCode, notFound, malformed, offline, rateLimited(Date), unsupported, storage, unstubbedTest
    public var errorDescription: String? {
        switch self {
        case .invalidCode: "Enter the digits printed below the barcode."
        case .notFound: "This product is not in Open Food Facts. Scan its label or enter it yourself."
        case .malformed: "The product data could not be read. Scan the label or try again later."
        case .offline: "Connect to look up this barcode. Saved products still work offline."
        case .rateLimited: "Product lookups are paused. Try again later or scan the label."
        case .unsupported: "This code does not resolve to a food product."
        case .storage: "The product cache could not be read or saved. Try again."
        case .unstubbedTest: "A test attempted an unstubbed product lookup."
        }
    }
}

public enum FoodBarcode {
    /// Complete UPC-E payload only. Seven-digit payloads have two possible layouts.
    /// Expansion and vectors: ZXing UPCEReader and Zint test_upcean.c.
    public static func expandedUPCE(_ input: String) throws -> String {
        let digits = Array(input)
        guard digits.count == 8, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits[0] == "0" || digits[0] == "1" else { throw FoodBarcodeError.invalidCode }
        let n = String(digits[0]); let body = Array(digits[1...6])
        let expanded: String
        switch body[5] {
        case "0", "1", "2": expanded = n + String(body[0...1]) + String(body[5]) + "0000" + String(body[2...4])
        case "3": expanded = n + String(body[0...2]) + "00000" + String(body[3...4])
        case "4": expanded = n + String(body[0...3]) + "00000" + String(body[4])
        default: expanded = n + String(body[0...4]) + "0000" + String(body[5])
        }
        let sum = expanded.enumerated().reduce(0) { $0 + ($1.element.wholeNumberValue ?? 0) * ($1.offset.isMultiple(of: 2) ? 3 : 1) }
        let check = (10 - sum % 10) % 10
        guard digits[7].wholeNumberValue == check else { throw FoodBarcodeError.invalidCode }
        return expanded + String(check)
    }

    /// OFF's numeric normalization, independent of GTIN checksum validation.
    public static func normalized(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 64, text.utf8.allSatisfy({ (48...57).contains($0) }) else { throw FoodBarcodeError.invalidCode }
        let significant = String(text.drop(while: { $0 == "0" }))
        guard (4...40).contains(significant.count) else { throw FoodBarcodeError.invalidCode }
        let width = significant.count <= 8 ? 8 : significant.count < 13 ? 13 : significant.count
        return String(repeating: "0", count: width - significant.count) + significant
    }
}

public struct FoodProductSource: Codable, Equatable, Sendable {
    public let barcode: String
    public let fetchedAt: Date
    public let apiVersion: String
    public let sourceURL: URL
    public let rawResponse: Data
    public let estimated: Bool
    public let databaseLicenseURL: URL
    public let contentsLicenseURL: URL
    public let attributionText: String
    init(barcode: String, fetchedAt: Date, apiVersion: String, sourceURL: URL, rawResponse: Data, estimated: Bool) {
        self.barcode = barcode; self.fetchedAt = fetchedAt; self.apiVersion = apiVersion
        self.sourceURL = sourceURL; self.rawResponse = rawResponse; self.estimated = estimated
        databaseLicenseURL = Self.databaseLicense; contentsLicenseURL = Self.contentsLicense; attributionText = Self.attribution
    }
    public func validate() throws {
        guard (try? FoodBarcode.normalized(barcode)) == barcode, fetchedAt.timeIntervalSince1970.isFinite,
              apiVersion == FoodProductDecoder.apiVersion, rawResponse.count <= 1_048_576,
              sourceURL.absoluteString == "https://world.openfoodfacts.org/product/\(barcode)",
              databaseLicenseURL == Self.databaseLicense, contentsLicenseURL == Self.contentsLicense,
              attributionText == Self.attribution else { throw FoodError.invalidRecord }
    }
    public static let attribution = "Product data from Open Food Facts contributors, available under the Open Database License."
    public static let databaseLicense = URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!
    public static let contentsLicense = URL(string: "https://opendatacommons.org/licenses/dbcl/1-0/")!
}

public struct FoodProduct: Codable, Equatable, Sendable {
    public let name: String
    public let brand: String?
    public let basis: FoodUnit
    public let basisAmount: Double
    public let preparation: String
    public let nutrients: FoodNutrients
    public let source: FoodProductSource
    public let warnings: [String]
    /// Open Food Facts `nova_group`, 1 to 4. Nil when the product has none or the response predates the field.
    public let novaGroup: Int?
    /// Open Food Facts `ingredients_tags`. Nil when the response has none, which includes cached responses
    /// recorded before Loopr asked for the field.
    public let ingredientTags: [String]?

    public func item(amount: Double, at date: Date) throws -> FoodItem {
        let value = FoodItem(name: name, amount: amount, unit: basis,
            nutrients: try nutrients.scaled(by: amount / basisAmount),
            provenance: [.init(source: .barcode, recordedAt: date, barcode: source.barcode, product: source)],
            novaGroup: novaGroup, ingredientTags: ingredientTags)
        try value.validate()
        return value
    }
}

public enum FoodProductDecoder {
    public static let apiVersion = "3.6"
    /// The unchanged response remains part of the item's provenance and export.
    public static func decode(_ data: Data, barcode: String, fetchedAt: Date) throws -> FoodProduct {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "success",
              let errors = root["errors"] as? [Any], errors.isEmpty,
              let product = root["product"] as? [String: Any],
              let returnedCode = product["code"] as? String,
              try FoodBarcode.normalized(returnedCode) == barcode,
              let name = product["product_name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 500,
              let nutrition = product["nutrition"] as? [String: Any],
              let aggregate = nutrition["aggregated_set"] as? [String: Any],
              let preparation = aggregate["preparation"] as? String, ["as_sold", "prepared"].contains(preparation),
              let per = aggregate["per"] as? String, ["100g", "100ml"].contains(per),
              let sourceNutrients = aggregate["nutrients"] as? [String: Any] else { throw FoodBarcodeError.malformed }
        var nutrients = FoodNutrients()
        var warnings: [String] = []
        let mapping: [(String, FoodNutrient, String)] = [
            ("energy-kcal", .energy, "kcal"), ("proteins", .protein, "g"), ("carbohydrates", .carbs, "g"),
            ("fat", .fat, "g"), ("fiber", .fibre, "g"), ("sugars", .sugar, "g"), ("salt", .salt, "g"), ("caffeine", .caffeine, "mg")
        ]
        for (key, nutrient, expectedUnit) in mapping {
            guard let entry = sourceNutrients[key] as? [String: Any] else { continue }
            guard let raw = entry["value"] else { continue }
            guard let number = number(raw), number >= 0, let unit = entry["unit"] as? String else { throw FoodBarcodeError.malformed }
            let modifier = entry["modifier"] as? String
            guard modifier == nil || modifier == "" || modifier == "=" || modifier == "~" else {
                warnings.append("\(key) has a range or limit. Check the label."); continue
            }
            if unit == expectedUnit { nutrients[nutrient] = number }
            else if nutrient == .caffeine && unit == "g" { nutrients[nutrient] = number * 1_000 }
            else if expectedUnit == "g" && unit == "mg" { nutrients[nutrient] = number / 1_000 }
            else { warnings.append("\(key) uses an unsupported unit. Check the label."); continue }
            if modifier == "~" || entry["source"] as? String == "estimate" { warnings.append("\(key) is estimated.") }
        }
        if nutrients[.energy] == nil, let entry = sourceNutrients["energy-kj"] as? [String: Any],
           entry["unit"] as? String == "kJ", let raw = entry["value"], let value = number(raw), value >= 0,
           entry["modifier"] == nil {
            nutrients[.energy] = value / 4.184
        }
        if sourceNutrients["carbohydrates-total"] != nil && nutrients[.carbs] == nil {
            warnings.append("Total carbohydrate includes fibre. Enter carbs after checking the label.")
        }
        if !(root["warnings"] as? [Any] ?? []).isEmpty { warnings.append("Open Food Facts flagged this product. Check its label.") }
        try nutrients.validate()
        let source = FoodProductSource(barcode: barcode, fetchedAt: fetchedAt, apiVersion: apiVersion,
            sourceURL: URL(string: "https://world.openfoodfacts.org/product/\(barcode)")!, rawResponse: data, estimated: warnings.contains { $0.hasSuffix("is estimated.") })
        return FoodProduct(name: name, brand: product["brands"] as? String, basis: per == "100g" ? .grams : .millilitres,
            basisAmount: 100, preparation: preparation, nutrients: nutrients, source: source, warnings: warnings,
            novaGroup: novaGroup(product["nova_group"]), ingredientTags: ingredientTags(product["ingredients_tags"]))
    }
    /// `nova_group` is an integer from 1 to 4 in the API v3 schema; a numeric string is accepted too. Anything else is
    /// not a classification.
    private static func novaGroup(_ raw: Any?) -> Int? {
        guard let raw, let value = number(raw), value.rounded() == value, (1...4).contains(value) else { return nil }
        return Int(value)
    }
    /// `ingredients_tags` is an array of taxonomy ids such as `en:spinach`. Entries are lowercased, and a field that
    /// is not an array of strings counts as absent.
    private static func ingredientTags(_ raw: Any?) -> [String]? {
        guard let tags = raw as? [Any] else { return nil }
        let strings = tags.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 120 }
        return Array(strings.prefix(500))
    }
    private static func number(_ raw: Any) -> Double? {
        // JSON booleans bridge to NSNumber too; they are not nutrient readings.
        if let value = raw as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        guard let text = raw as? String, let value = Double(text), value.isFinite else { return nil }
        return value
    }
}

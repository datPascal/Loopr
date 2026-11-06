import FoodKit
import Foundation
import ImageIO
import StorageKit
import Testing
import UIKit
@testable import Loopr

@MainActor struct FoodCaptureIntegrationTests {
    private func environment() -> AppEnvironment { .make(arguments: ["--loopr-launch-mode=populated"], environment: [:]) }
    @Test func textCaptureAndBarcodeLookupLeaveMealsUnchangedUntilConfirmation() async throws {
        let environment = environment()
        let repository = ProductRepositoryContainer(environment: environment).fixtureFoodRepository
        let original = try await repository.overview(from: "2023-11-14", through: "2023-11-14")
        let now = try #require(ISO8601DateFormatter().date(from: "2023-11-14T05:30:00Z"))
        let draft = FoodMealDraft(slot: .snack, occurredAt: now, timeZoneIdentifier: "Australia/Perth")
        let text = FoodCaptureModel(draft: draft, repository: repository, fixture: true, now: now)
        text.text = "150 g chicken\n180 g rice"; text.reviewText(source: .voice)
        #expect(text.review?.items.count == 2)
        #expect(try await repository.overview(from: "2023-11-14", through: "2023-11-14").meals == original.meals)
        text.review = nil
        let lens = FoodLensModel(draft: draft, repository: repository, fixture: true, now: now)
        lens.typed("4000000000010")
        #expect(lens.stage == .reading && lens.kind == .barcode && lens.subject != nil)
        try await waitUntil { lens.stage != .reading }
        #expect(lens.stage == .result && lens.title == "Almond drink")
        // A drink starts at a glass; the amount scales the label's per-100 ml values.
        #expect(lens.totals.energy == 60)
        lens.setAmount(100, for: try #require(lens.items.first).id)
        let reviewed = lens.finalDraft()
        #expect(reviewed.items[0].unit == .millilitres && reviewed.items[0].amount == 100 && reviewed.items[0].nutrients[.energy] == 24)
        #expect(try await repository.overview(from: "2023-11-14", through: "2023-11-14").meals == original.meals)
        try await repository.confirm(reviewed, at: now)
        #expect(try await repository.overview(from: "2023-11-14", through: "2023-11-14").meals.count == original.meals.count + 1)
    }
    @Test func dismissedCaptureIgnoresLateBarcodeFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodCaptureCancellation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close() }
        let store = FoodStore(database: database)
        let transport = SuspendedFoodCaptureTransport()
        let repository = AppFoodRepository(store: store, environment: environment(),
            productClient: FoodProductClient(transport: transport, cache: store))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let model = FoodLensModel(draft: .init(slot: .snack, occurredAt: now, timeZoneIdentifier: "Australia/Perth"),
            repository: repository, fixture: true, now: now)
        model.typed("12345678")
        await transport.waitUntilStarted()
        await model.stop()
        await transport.finish()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.problem == nil && model.items.isEmpty && model.stage != .result)
        #expect(try store.meals().isEmpty)
    }
    @Test func labelOCRRunsOnSelectedBytesWithoutAProvider() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 700, height: 600))
        let image = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 700, height: 600))
            let label = "Nutrition per 100 g\nEnergy 200 kcal\nProtein 12.5 g\nCarbohydrates 20 g\nFat 4 g\nSalt 0 g" as NSString
            label.draw(in: CGRect(x: 30, y: 30, width: 640, height: 540), withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
        }
        let data = try #require(image.pngData())
        let recognized = try await FoodLabelOCR.text(from: data)
        let label = FoodLabelParser.parse(recognized)
        #expect(label.basis == .grams)
        #expect(label.nutrients[.energy] == 200 && label.nutrients[.protein] == 12.5 && label.nutrients[.salt] == 0)
    }
    @Test func selectedPhotoMetadataAndTimeSurviveConfirmationAndExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodCaptureTime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close() }
        let store = FoodStore(database: database)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let image = renderer.image { context in UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:01:02 00:30:00", kCGImagePropertyExifOffsetTimeOriginal: "+08:00"
        ]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let imported = try FoodPhotoImport.read(bytes as Data, assumedZone: .gmt, now: Date())
        #expect(imported.time.source == .exif)
        var draft = try FoodMealDraft(slot: .snack, occurredAt: imported.photo.reference.capturedAt,
            timeZoneIdentifier: "Australia/Perth", items: FoodTextCapture.items("1 piece apple", source: .typed, at: imported.photo.reference.capturedAt),
            photos: [imported.photo], photoTime: imported.time)
        #expect(try store.meals().isEmpty)
        // The reviewed meal time can be corrected without rewriting the photo's original time.
        draft.occurredAt = draft.occurredAt.addingTimeInterval(3_600)
        let saved = try store.confirm(draft, at: draft.occurredAt)
        #expect(saved.localDay == "2026-01-02" && saved.photoTime == imported.time)
        let restored = try JSONDecoder().decode(FoodArchive.self, from: JSONEncoder().encode(store.exportArchive()))
        #expect(restored.meals[0].photos[0].capturedAt == imported.photo.reference.capturedAt)
        #expect(try store.editDraft(id: saved.id).photoTime == imported.time)
    }
}

@MainActor private func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { Issue.record("Timed out"); return }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private actor SuspendedFoodCaptureTransport: FoodProductTransport {
    private var response: CheckedContinuation<FoodProductHTTPResponse, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func send(_ request: URLRequest) async throws -> FoodProductHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            response = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if response != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { response?.resume(throwing: FoodBarcodeError.notFound); response = nil }
}

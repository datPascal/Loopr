import AIKit
import AVFoundation
import Combine
import FoodKit
import Foundation
import Photos
import PhotosUI
import SwiftUI

/// The food camera. One viewfinder reads both: a barcode it sees is lifted out and looked up at once,
/// and a photo of a plate becomes a sticker that is estimated straight away. Nothing is saved until
/// the person adds the result.
@MainActor
final class FoodLensModel: ObservableObject {
    enum Stage: Equatable { case live, reading, result, problem, burst }
    /// What the camera looks for. A label keeps its photo whole and is read on the phone. A lab report is read on
    /// the phone too, by `FoodLabModel`, and never reaches the estimate path.
    enum Lens: String, CaseIterable { case food, label, lab
        var title: String { rawValue.capitalized }
    }
    enum Kind: Equatable { case photo, barcode, label }
    enum Problem: Equatable {
        /// The provider has not been allowed to see food photos yet.
        case consent(String)
        /// No provider key, or the person chose not to send the photo.
        case manual(declined: Bool)
        case failed(title: String, message: String)
    }

    @Published var stage: Stage = .live
    @Published var lens: Lens = .food
    @Published var draft: FoodMealDraft
    @Published var cameraReady = false
    @Published var cameraMessage: String?
    @Published var labels: [String] = []
    @Published var torch = false
    @Published var kind: Kind?
    /// The picture that leaves the frame: a barcode crop or the plate's sticker.
    @Published var subject: UIImage?
    /// The barcode redrawn clean. It fades in over the crop once the crop has flown out.
    @Published var card: UIImage?
    /// Where `subject` sat in the source, as fractions from its top left, and the source's width over height.
    @Published var region: CGRect?
    @Published var sourceAspect: CGFloat = 3 / 4
    @Published var backdrop: UIImage?
    @Published var status: String?
    @Published var code: String?
    /// Items as read. Amounts change through `amounts` until the meal is added.
    @Published var items: [FoodItem] = []
    @Published var amounts: [UUID: Double] = [:]
    @Published var title = ""
    @Published var detail: String?
    @Published var problem: Problem?
    @Published var busy = false
    @Published var fixturePhoto: FoodPhoto?
    /// True while Lab mode shows a read report over the camera.
    @Published private(set) var labActive = false
    let camera = FoodCamera()
    /// Lab mode: blood test reports read on this iPhone (DEC-12.6).
    let lab: FoodLabModel
    let repository: AppFoodRepository
    let runtime: LooprAISettingsRuntime
    let fixture: Bool
    let now: Date
    private var provider: CoachProviderConfiguration?
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var captureDate: Date { fixture ? now : Date() }

    #if DEBUG
    /// The Lab report a fixture launch reads instead of the camera.
    let labFixture: FoodLabFixture.Report?
    #endif

    /// - Parameter labReader: how Lab mode reads a photo. Vision on this iPhone unless a test or fixture passes one.
    init(draft: FoodMealDraft, repository: AppFoodRepository, runtime: LooprAISettingsRuntime = .shared, fixture: Bool, now: Date,
         labReader: FoodLabReader? = nil) {
        self.draft = draft; self.repository = repository; self.fixture = fixture; self.now = now
        let zone = TimeZone(identifier: draft.timeZoneIdentifier) ?? .current
        #if DEBUG
        self.runtime = fixture ? FoodProviderFixtures.runtime() : runtime
        let labFixture = fixture ? FoodLabFixture.requested() : nil
        self.labFixture = labFixture
        lab = FoodLabModel(timeZone: zone, reader: labReader ?? labFixture.map(FoodLabFixture.reader) ?? .vision)
        #else
        self.runtime = runtime
        lab = FoodLabModel(timeZone: zone, reader: labReader ?? .vision)
        #endif
        lab.onActiveChange = { [weak self] active in self?.labActive = active }
    }

    // MARK: Camera

    func prepare() async {
        let id = UUID(); generation = id
        cameraReady = false; cameraMessage = nil; torch = false
        await camera.stop()
        guard generation == id, stage == .live, !Task.isCancelled else { return }
        #if DEBUG
        if fixture {
            do {
                if lens == .lab, let labFixture { fixturePhoto = try FoodLabFixture.photo(labFixture, at: now); cameraReady = true; labels = [] }
                else { fixturePhoto = try FoodCaptureFixtures.photo(at: now); cameraReady = true; labels = ["Chicken", "Rice", "Avocado"] }
            }
            catch { cameraMessage = error.localizedDescription }
            return
        }
        #endif
        do {
            let reads = lens == .food
            try await camera.start(labels: { @MainActor @Sendable [weak self] values in
                guard let self, self.generation == id else { return }; self.labels = values
            }, barcode: reads ? { @MainActor @Sendable [weak self] hit in
                guard let self, self.generation == id, self.stage == .live, self.lens == .food else { return }
                self.found(hit)
            } : nil, failure: { @MainActor @Sendable [weak self] text in
                guard let self, self.generation == id else { return }; self.cameraMessage = text; self.cameraReady = false
            })
            guard generation == id, !Task.isCancelled else { await camera.stop(); return }
            cameraReady = true
        } catch { if generation == id, !Task.isCancelled { cameraMessage = error.localizedDescription } }
    }

    func stop() async {
        generation = UUID(); work?.cancel(); work = nil
        cameraReady = false; torch = false
        await camera.stop()
    }

    func switchLens(_ value: Lens) async {
        guard stage == .live, lens != value else { return }
        lens = value; labels = []
        await prepare()
    }

    func toggleTorch() async {
        let next = !torch
        if await camera.setTorch(next) { torch = next }
    }

    /// Back to the viewfinder, dropping whatever was read.
    func retake() async {
        work?.cancel(); work = nil
        stage = .live; kind = nil; subject = nil; card = nil; region = nil; backdrop = nil
        status = nil; code = nil; items = []; amounts = [:]; title = ""; detail = nil; problem = nil; busy = false
        draft.items = []; draft.photos = []; draft.photoTime = nil
        await prepare()
    }

    func shoot() async {
        guard cameraReady, stage == .live, !busy else { return }
        busy = true
        let id = generation
        do {
            let photo: FoodPhoto
            #if DEBUG
            if fixture, let fixturePhoto { photo = fixturePhoto } else { photo = try await camera.capture(at: captureDate) }
            #else
            photo = try await camera.capture(at: captureDate)
            #endif
            guard generation == id else { busy = false; return }
            if lens == .lab { busy = false; lab.queue(pages: []); readLab(photo); return }
            draft.photoTime = .init(source: .camera, originalLocalTime: nil, originalOffset: nil, assumedTimeZone: nil)
            draft.occurredAt = photo.reference.capturedAt
            read(photo)
        } catch {
            busy = false
            if generation == id, !Task.isCancelled { cameraMessage = error.localizedDescription }
        }
    }

    func importPhoto(_ item: PhotosPickerItem) async {
        guard stage == .live, !busy else { return }
        busy = true
        let id = generation
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw FoodError.invalidPhoto }
            var assetDate: Date?
            let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if [.authorized, .limited].contains(permission), let identifier = item.itemIdentifier {
                assetDate = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject?.creationDate
            }
            let date = assetDate, zone = TimeZone(identifier: draft.timeZoneIdentifier) ?? .current, now = captureDate
            let imported = try await Task.detached(priority: .userInitiated) {
                try FoodPhotoImport.read(data, assetDate: date, assumedZone: zone, now: now)
            }.value
            guard generation == id else { busy = false; return }
            if lens == .lab { busy = false; lab.queue(pages: []); readLab(imported.photo); return }
            draft.occurredAt = imported.photo.reference.capturedAt; draft.photoTime = imported.time
            read(imported.photo)
        } catch {
            busy = false
            if generation == id, !Task.isCancelled { cameraMessage = error.localizedDescription }
        }
    }

    // MARK: Lab

    /// A lab report photo goes to Lab mode, which reads it on this iPhone. It is never attached to the meal and never
    /// reaches the estimate, the provider or the photo consent.
    @discardableResult
    func readLab(_ photo: FoodPhoto) -> Task<Void, Never> {
        generation = UUID()
        Task { await camera.stop() }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.lab.read(photo)
        }
        work = task
        return task
    }

    /// Reads a PDF of a lab report, page by page: the first page now, the rest when the person asks for them after
    /// saving. The pages are rendered on this iPhone.
    func importLabPDF(_ url: URL) async {
        guard lens == .lab, !busy else { return }
        busy = true
        let id = generation, date = captureDate
        do {
            let pages = try await Task.detached(priority: .userInitiated) { () throws -> [FoodPhoto] in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try FoodLabPDF.pages(at: url, capturedAt: date)
            }.value
            busy = false
            guard generation == id, let first = pages.first else { return }
            lab.queue(pages: pages)
            readLab(first)
        } catch {
            busy = false
            if generation == id, !Task.isCancelled { cameraMessage = "Loopr could not open that PDF. Try another file, or a photo of the page." }
        }
    }

    /// Back to the viewfinder from Lab mode, dropping the read.
    func retakeLab() async {
        work?.cancel(); work = nil
        lab.reset()
        busy = false
        await prepare()
    }

    // MARK: Reading

    /// A barcode the live camera locked onto.
    func found(_ hit: FoodLensBarcodeHit) {
        guard stage == .live else { return }
        generation = UUID()
        let id = generation
        kind = .barcode; subject = hit.crop; card = nil; region = hit.region; backdrop = hit.frame
        sourceAspect = hit.frame.size.width / max(hit.frame.size.height, 1)
        draft.photos = []; draft.photoTime = nil
        Task { await camera.stop() }
        lookUp(hit.code, generation: id)
    }

    /// A code typed from the digits under the bars.
    func typed(_ text: String) {
        let digits = text.filter(\.isNumber)
        guard stage == .live, !digits.isEmpty else { return }
        generation = UUID()
        let id = generation
        kind = .barcode; subject = FoodLensArt.barcodeCard(digits); card = nil; region = nil; backdrop = nil
        draft.photos = []; draft.photoTime = nil
        Task { await camera.stop() }
        lookUp(digits, generation: id)
    }

    private func lookUp(_ code: String, generation id: UUID) {
        self.code = code; status = "Finding your product"; stage = .reading; busy = true
        work = Task { [weak self] in
            guard let self else { return }
            let clean = await Task.detached(priority: .userInitiated) { FoodLensArt.barcodeCard(code) }.value
            // Let the crop land before the clean code fades over it.
            try? await Task.sleep(for: .milliseconds(560))
            guard self.generation == id else { return }
            self.card = clean
            let started = Date()
            do {
                let result = try await self.repository.lookupBarcode(code)
                try await Self.hold(since: started, seconds: 0.9)
                guard self.generation == id else { return }
                let item = try result.product.item(amount: result.product.basis == .millilitres ? 250 : 100, at: self.now)
                self.items = [item]; self.amounts = [item.id: item.amount]
                self.title = result.product.name
                self.detail = ([result.product.brand].compactMap { $0 } + (result.isStale ? ["Saved product. Check its current label."] : []) + result.product.warnings)
                    .joined(separator: " · ").nilIfEmpty
                self.status = nil; self.busy = false; self.stage = .result
            } catch is CancellationError {
            } catch {
                guard self.generation == id else { return }
                try? await Self.hold(since: started, seconds: 0.7)
                self.fail(title: "Couldn't find this product", message: error.localizedDescription)
            }
        }
    }

    private func read(_ photo: FoodPhoto) {
        generation = UUID()
        let id = generation, label = lens == .label
        kind = label ? .label : .photo
        draft.photos = [photo]
        subject = nil; card = nil; region = nil; backdrop = nil
        status = label ? "Reading the label" : "Scanning"; stage = .reading
        Task { await camera.stop() }
        work = Task { [weak self] in
            guard let self else { return }
            let bytes = photo.bytes
            let result = await Task.detached(priority: .userInitiated) { FoodLensArt.read(photo: bytes, label: label) }.value
            guard self.generation == id else { return }
            switch result {
            case .barcode(let hit):
                // A photo of a pack: the barcode beats a guess at the food.
                self.kind = .barcode; self.subject = hit.crop; self.region = hit.region; self.backdrop = hit.frame
                self.sourceAspect = hit.frame.size.width / max(hit.frame.size.height, 1)
                self.draft.photos = []; self.draft.photoTime = nil
                self.lookUp(hit.code, generation: id)
                return
            case .cutout(let cutout):
                self.subject = cutout.image; self.region = cutout.region; self.backdrop = cutout.backdrop
                self.sourceAspect = cutout.backdrop.size.width / max(cutout.backdrop.size.height, 1)
            case nil:
                self.subject = UIImage(data: bytes); self.region = nil; self.backdrop = nil
            }
            if label { await self.readLabel(photo, generation: id) } else { await self.estimate(generation: id) }
        }
    }

    private func readLabel(_ photo: FoodPhoto, generation id: UUID) async {
        let started = Date()
        do {
            let text = try await FoodLabelOCR.text(from: photo.bytes)
            try await Self.hold(since: started, seconds: 1.1)
            guard generation == id else { return }
            let result = FoodLabelParser.parse(text)
            guard result.basis != nil else {
                fail(title: "Couldn't read this label", message: "Hold the phone closer so one nutrition column fills the frame, or add the values yourself.")
                return
            }
            let item = try result.item(name: "Food from label", at: now)
            items = [item]; amounts = [item.id: item.amount]
            title = "Nutrition label"; detail = result.issues.joined(separator: " ").nilIfEmpty
            status = nil; busy = false; stage = .result
        } catch is CancellationError {
        } catch {
            guard generation == id else { return }
            fail(title: "Couldn't read this label", message: "Try another photo, or add the values yourself.")
        }
    }

    /// Estimates the photo with the person's own provider. The first photo for a provider asks first.
    private func estimate(generation id: UUID) async {
        let started = Date()
        do {
            provider = try await runtime.selectedConfiguration()
            guard let provider, await runtime.credentialAvailable(provider) else {
                try await Self.hold(since: started, seconds: 1.2)
                guard generation == id else { return }
                status = nil; busy = false; problem = .manual(declined: false); stage = .problem
                return
            }
            guard try await runtime.hasFoodPhotoConsent(provider) else {
                try await Self.hold(since: started, seconds: 1.0)
                guard generation == id else { return }
                status = nil; busy = false; problem = .consent(provider.provider.name); stage = .problem
                return
            }
            guard let photo = draft.photos.first else { throw FoodError.invalidPhoto }
            let image = try await Task.detached(priority: .userInitiated) { try FoodProviderImage.jpeg(photo) }.value
            let request = try CoachStructuredRequest(configuration: provider, instructions: FoodEstimate.instructions,
                text: "Estimate the food in this photo. Food note:\n" + draft.note, imageJPEG: image, schema: FoodEstimate.schema)
            let data = try await runtime.structured(request)
            let estimate = try FoodEstimate.decode(data, provider: provider.provider == .openAI ? "openai" : "anthropic", model: provider.model, at: now)
            try await Self.hold(since: started, seconds: 1.6)
            guard generation == id else { return }
            guard !estimate.items.isEmpty else {
                fail(title: "No food found", message: estimate.uncertainty.nilIfEmpty ?? "Try another photo, or add the foods yourself.")
                return
            }
            items = estimate.items; amounts = Dictionary(uniqueKeysWithValues: estimate.items.map { ($0.id, $0.amount) })
            title = "Your \(draft.slot.rawValue)"
            detail = "\(provider.provider.name) estimated this from your photo. \(estimate.uncertainty.nilIfEmpty ?? "Check the portions before you add it.")"
            status = nil; busy = false; stage = .result
        } catch is CancellationError {
        } catch {
            guard generation == id, !Task.isCancelled else { return }
            fail(title: "Couldn't estimate this photo", message: error.localizedDescription)
        }
    }

    /// The person allowed photos for this provider from the problem card.
    func allowAndEstimate() async {
        guard let provider, case .consent = problem else { return }
        do { try await runtime.grantFoodPhotoConsent(provider) }
        catch { fail(title: "Couldn't estimate this photo", message: error.localizedDescription); return }
        let id = generation
        problem = nil; status = "Scanning"; busy = true; stage = .reading
        work = Task { [weak self] in await self?.estimate(generation: id) }
    }

    func decline() { problem = .manual(declined: true) }

    private func fail(title: String, message: String) {
        status = nil; busy = false; problem = .failed(title: title, message: message); stage = .problem
    }

    /// Keeps a reading on screen long enough to be seen, even when the answer comes back at once.
    private static func hold(since start: Date, seconds: Double) async throws {
        let left = seconds - Date().timeIntervalSince(start)
        if left > 0 { try await Task.sleep(for: .seconds(left)) }
    }

    // MARK: Result

    var shownItems: [FoodItem] {
        items.map { item in
            guard let amount = amounts[item.id], amount != item.amount, item.amount > 0,
                  let nutrients = try? item.nutrients.scaled(by: amount / item.amount) else { return item }
            var copy = item; copy.amount = amount; copy.nutrients = nutrients
            return copy
        }
    }

    var totals: FoodBurstNumbers { FoodBurstNumbers(items: shownItems) }

    /// The ruler starts at zero so its labels fall on round numbers; an amount never goes below one step.
    func setAmount(_ value: Double, for id: UUID) {
        guard value.isFinite, let item = items.first(where: { $0.id == id }) else { return }
        let step = item.unit == .grams || item.unit == .millilitres ? 5.0 : 0.25
        amounts[id] = max(value, step)
    }

    /// The meal as it will be saved. A changed amount is recorded as the person's edit.
    func finalDraft() -> FoodMealDraft {
        var result = draft
        result.items = items.map { item in
            var copy = item
            if let amount = amounts[item.id], amount != item.amount { try? copy.changeAmount(to: amount, at: now) }
            return copy
        }
        return result
    }

    /// Takes the meal back from the full review screen, where the person may have changed anything.
    func adopt(_ reviewed: FoodMealDraft) {
        draft = reviewed
        items = reviewed.items
        amounts = Dictionary(uniqueKeysWithValues: reviewed.items.map { ($0.id, $0.amount) })
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

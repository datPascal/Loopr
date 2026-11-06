import Foundation
import Observation

/// The state behind the picker: what can be picked, what is picked, and the preview built from the picks.
@MainActor @Observable
final class PublishDashboardModel {
    struct Preview: Equatable {
        let html: String
        let htmlBytes: Int
        let jsonBytes: Int
        let files: PublishedFiles
        let metricCount: Int
    }

    /// What a preview depends on. The screen rebuilds the preview when it changes.
    struct PreviewKey: Hashable {
        let picked: [String]
        let period: PublishPeriod
        let includeBloodTests: Bool
    }

    private(set) var candidates: [PublishMetricDescriptor] = []
    private(set) var isLoading = true
    private(set) var isBuilding = false
    private(set) var preview: Preview?
    private(set) var error: String?
    private(set) var picked: Set<String> = []
    var period: PublishPeriod = .days30
    var includeBloodTests = false {
        didSet {
            guard !includeBloodTests else { return }
            let blood = Set(candidates.filter { $0.group == .bloodTests }.map(\.key))
            picked.subtract(blood)
        }
    }

    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let loadCandidates: @Sendable () async -> [PublishMetricDescriptor]
    private let loadSeries: @Sendable ([String], PublishPeriod) async -> [PublishMetricSeries]
    private let directory: URL

    init(timeZone: TimeZone, now: @escaping @Sendable () -> Date,
         loadCandidates: @escaping @Sendable () async -> [PublishMetricDescriptor],
         loadSeries: @escaping @Sendable ([String], PublishPeriod) async -> [PublishMetricSeries],
         directory: URL = FileManager.default.temporaryDirectory) {
        self.timeZone = timeZone
        self.now = now
        self.loadCandidates = loadCandidates
        self.loadSeries = loadSeries
        self.directory = directory
    }

    var previewKey: PreviewKey { PreviewKey(picked: picked.sorted(), period: period, includeBloodTests: includeBloodTests) }
    var hasAnyData: Bool { candidates.contains(where: \.hasData) }

    func groups() -> [(group: PublishGroup, metrics: [PublishMetricDescriptor])] {
        PublishGroup.allCases.compactMap { group in
            // Metrics with data first, so the rows that cannot be picked sit together at the bottom of each group.
            let metrics = candidates.filter { $0.group == group && $0.hasData } + candidates.filter { $0.group == group && !$0.hasData }
            return metrics.isEmpty ? nil : (group, metrics)
        }
    }

    func canPick(_ metric: PublishMetricDescriptor) -> Bool {
        metric.hasData && (metric.group != .bloodTests || includeBloodTests)
    }

    func isPicked(_ metric: PublishMetricDescriptor) -> Bool { picked.contains(metric.key) }

    /// True when at least one blood test marker has a stored value to add.
    var hasBloodTests: Bool { candidates.contains { $0.group == .bloodTests && $0.hasData } }

    /// The picked blood markers by name, in picker order.
    var pickedBloodNames: [String] {
        candidates.filter { $0.group == .bloodTests && picked.contains($0.key) }.map(\.name)
    }

    /// Whether every metric of the group that can be picked is picked. False when none can be.
    func allPicked(_ group: PublishGroup) -> Bool {
        let pickable = candidates.filter { $0.group == group && canPick($0) }
        return !pickable.isEmpty && pickable.allSatisfy { picked.contains($0.key) }
    }

    func canPickAny(_ group: PublishGroup) -> Bool { candidates.contains { $0.group == group && canPick($0) } }

    /// Picks every metric of the group that can be picked, or clears them all when they already are.
    func toggleAll(_ group: PublishGroup) {
        let keys = candidates.filter { $0.group == group && canPick($0) }.map(\.key)
        if allPicked(group) { picked.subtract(keys) } else { picked.formUnion(keys) }
    }

    func toggle(_ metric: PublishMetricDescriptor) {
        guard canPick(metric) else { return }
        if picked.contains(metric.key) { picked.remove(metric.key) } else { picked.insert(metric.key) }
    }

    func load() async {
        PublishFileWriter.removeStale(in: directory)
        isLoading = true
        let found = await loadCandidates()
        candidates = found
        isLoading = false
    }

    /// Builds both files for the current picks and keeps them in a temporary folder for the share sheet.
    func refreshPreview() async {
        let keys = picked.sorted()
        guard !keys.isEmpty else {
            discardFiles()
            return
        }
        isBuilding = true
        defer { isBuilding = false }
        let series = await loadSeries(keys, period)
        guard !Task.isCancelled else { return }
        let dashboard = PublishDashboard.make(series: series, period: period, exportedAt: now(),
                                              timeZone: timeZone, includeBloodTests: includeBloodTests)
        do {
            let html = PublishHTMLRenderer.render(dashboard)
            let json = try PublishJSONRenderer.render(dashboard)
            let files = try PublishFileWriter.write(html: html, json: json, in: directory)
            discardFiles()
            preview = Preview(html: html, htmlBytes: html.utf8.count, jsonBytes: json.count, files: files,
                              metricCount: dashboard.metrics.count)
            error = nil
        } catch {
            discardFiles()
            self.error = "Loopr could not build the page. Try again."
        }
    }

    /// Removes the temporary files. The screen calls this when it goes away.
    func discardFiles() {
        if let files = preview?.files { PublishFileWriter.remove(files) }
        preview = nil
    }
}

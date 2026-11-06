import AIKit
import Foundation

/// A chart the app could draw from data a read tool returned. The model can ask to show one by id.
/// The values are the app's own, taken from the same read, never numbers the model wrote.
typealias AgentChartCandidate = AgentChartSnapshot

/// Everything one answer produced besides its text.
nonisolated struct AgentTurnArtifacts: Equatable, Sendable {
    var sources: [AgentSource] = []
    /// Charts the model asked to show, in order.
    var charts: [AgentChartCandidate] = []
    var proposalIDs: [UUID] = []
    var isEmpty: Bool { sources.isEmpty && charts.isEmpty && proposalIDs.isEmpty }

    /// What the message keeps, in the order the row shows it under the answer: charts, the source
    /// strip, then the confirmation cards (mockup 16).
    var attachments: [AgentAttachment] {
        charts.map(AgentAttachment.chart) + (sources.isEmpty ? [] : [.sources(sources)]) + proposalIDs.map(AgentAttachment.proposal)
    }
}

/// Collects artifacts while a tool loop runs. One session per answer.
actor AgentToolSession {
    private(set) var artifacts = AgentTurnArtifacts()
    private var candidates: [String: AgentChartCandidate] = [:]
    static let maxCharts = 3

    func add(source: AgentSource) {
        guard !artifacts.sources.contains(where: { $0.id == source.id }) else { return }
        artifacts.sources.append(source)
    }
    func offer(_ chart: AgentChartCandidate) { candidates[chart.id] = chart }
    func candidate(_ id: String) -> AgentChartCandidate? { candidates[id] }
    /// Returns false when the chart limit is reached.
    func show(_ chart: AgentChartCandidate) -> Bool {
        if artifacts.charts.contains(where: { $0.id == chart.id }) { return true }
        guard artifacts.charts.count < Self.maxCharts else { return false }
        artifacts.charts.append(chart)
        return true
    }
    func add(proposalID: UUID) { artifacts.proposalIDs.append(proposalID) }
}

import Foundation

/// The Your data domains Ask can read. The raw value is what `AgentToolSpec.domain` carries and what
/// the device-wide switches are stored under. The app adds the display titles. `supplements` and `labs`
/// are the two switches added in LV-09; they start off.
public enum AgentDataDomain: String, CaseIterable, Codable, Sendable {
    case metrics, food, training, journalAnswers, journalNotes, cycle, supplements, labs
}

/// Where a source chip sends the person. The app turns each case into a screen.
public enum AgentSourceLink: Codable, Equatable, Sendable {
    case metric(key: String, day: String)
    case sleep(day: String)
    case foodDay(day: String)
    case workout(id: String)
    /// A finished strength session. Its summary is a Train screen, not a recorded workout.
    case trainSession(id: String)
    case habitCheckIn(day: String)
    case habitHistory
    case patterns
}

public struct AgentDayRange: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// What one tool call read, built from the records it returned and nothing else.
public struct AgentSource: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let domain: AgentDataDomain
    public let label: String
    public let count: Int
    public let range: AgentDayRange?
    public let recordIDs: [String]
    public let link: AgentSourceLink?
    public init(id: String, domain: AgentDataDomain, label: String, count: Int, range: AgentDayRange?, recordIDs: [String], link: AgentSourceLink?) {
        self.id = id; self.domain = domain; self.label = label; self.count = count
        self.range = range; self.recordIDs = recordIDs; self.link = link
    }
}

public struct AgentChartPoint: Codable, Equatable, Sendable {
    public let day: String
    public let value: Double
    public init(day: String, value: Double) { self.day = day; self.value = value }
}

/// How a chart is drawn. Daily bars suit totals (steps, energy). A line suits a reading that moves
/// (heart rate variability, resting heart rate).
public enum AgentChartKind: String, Codable, Sendable {
    case bars, line
}

/// A chart as the app read it. Both the candidates a read tool offers and the chart saved under an
/// answer use this type. The values are the app's own, taken from the same read, never numbers the
/// model wrote. The model can only name a chart by its id.
public struct AgentChartSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let unit: String
    public let domain: AgentDataDomain
    public let points: [AgentChartPoint]
    public let kind: AgentChartKind
    /// Days (yyyy-MM-dd) drawn brighter than the rest. The app sets these from its own records.
    public let highlightedDays: [String]
    /// One line under the title, such as "Brighter bars had dinner after 21:00".
    public let caption: String?

    public init(id: String, title: String, unit: String, domain: AgentDataDomain, points: [AgentChartPoint],
                kind: AgentChartKind = .bars, highlightedDays: [String] = [], caption: String? = nil) {
        self.id = id; self.title = title; self.unit = unit; self.domain = domain; self.points = points
        self.kind = kind; self.highlightedDays = highlightedDays; self.caption = caption
    }

    private enum CodingKeys: String, CodingKey { case id, title, unit, domain, points, kind, highlightedDays, caption }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  unit: try c.decode(String.self, forKey: .unit), domain: try c.decode(AgentDataDomain.self, forKey: .domain),
                  points: try c.decode([AgentChartPoint].self, forKey: .points),
                  kind: try c.decodeIfPresent(AgentChartKind.self, forKey: .kind) ?? .bars,
                  highlightedDays: try c.decodeIfPresent([String].self, forKey: .highlightedDays) ?? [],
                  caption: try c.decodeIfPresent(String.self, forKey: .caption))
    }
}

/// Everything under an answer besides its text. Saved with the message, so it survives a relaunch.
/// The proposal case holds only the id. The card's state lives with the stored proposal.
public enum AgentAttachment: Codable, Equatable, Sendable {
    case sources([AgentSource])
    case chart(AgentChartSnapshot)
    case proposal(UUID)

    private enum CodingKeys: String, CodingKey { case kind, sources, chart, proposal }
    private enum Kind: String, Codable { case sources, chart, proposal }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .sources: self = .sources(try c.decode([AgentSource].self, forKey: .sources))
        case .chart: self = .chart(try c.decode(AgentChartSnapshot.self, forKey: .chart))
        case .proposal: self = .proposal(try c.decode(UUID.self, forKey: .proposal))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sources(let value): try c.encode(Kind.sources, forKey: .kind); try c.encode(value, forKey: .sources)
        case .chart(let value): try c.encode(Kind.chart, forKey: .kind); try c.encode(value, forKey: .chart)
        case .proposal(let value): try c.encode(Kind.proposal, forKey: .kind); try c.encode(value, forKey: .proposal)
        }
    }
}

/// Decodes one attachment, or nothing. A chat saved by a newer build may hold an attachment this
/// build does not know. Dropping it keeps the chat readable instead of failing the whole file.
struct AgentLossyAttachment: Decodable {
    let value: AgentAttachment?
    init(from decoder: Decoder) throws { value = try? AgentAttachment(from: decoder) }
}

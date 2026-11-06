import Foundation

/// Why a provider request was sent. Stored with every request record.
public enum AIRequestPurpose: String, Codable, CaseIterable, Sendable {
    case chat, toolRound, briefing, weeklyReview, foodEstimate
}

/// Caller-supplied metadata that travels with a request so the transport can describe it in the log.
/// It never reaches the provider.
public struct AIRequestContext: Equatable, Sendable {
    public var purpose: AIRequestPurpose
    public var conversationID: UUID?
    /// Where the person was when they asked, for example "Sleep, Tue 13 Oct".
    public var origin: String?
    public init(purpose: AIRequestPurpose, conversationID: UUID? = nil, origin: String? = nil) {
        self.purpose = purpose; self.conversationID = conversationID; self.origin = origin
    }
}

public enum AIRequestStatus: String, Codable, Sendable {
    /// Recorded before the request left the device. No outcome yet.
    case sent
    case succeeded, failed, refused, cancelled
}

/// One tool call that is part of a recorded request, with the bytes of the result that was sent back.
public struct AIRecordedToolCall: Codable, Equatable, Sendable {
    public var name: String
    public var domain: String
    public var resultBytes: Int
    public var isError: Bool
    public var denied: Bool
    public init(name: String, domain: String, resultBytes: Int, isError: Bool, denied: Bool) {
        self.name = name; self.domain = domain; self.resultBytes = resultBytes; self.isError = isError; self.denied = denied
    }
}

/// A read that the access gate refused. The model saw `message` as the tool result.
public struct AIRecordedDenial: Codable, Equatable, Sendable {
    public var toolName: String
    public var domain: String
    public var message: String
    public init(toolName: String, domain: String, message: String) {
        self.toolName = toolName; self.domain = domain; self.message = message
    }
}

/// What was sent to a provider. `body` is the exact `httpBody` of the URLRequest, byte for byte.
public struct AIRequestRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var provider: CoachProvider
    public var model: String
    public var conversationID: UUID?
    public var origin: String?
    public var purpose: AIRequestPurpose
    public var body: Data
    public var bodyBytes: Int { body.count }
    /// Tool calls from earlier rounds whose results are inside `body`.
    public var toolCalls: [AIRecordedToolCall]
    public var denials: [AIRecordedDenial]
    public var status: AIRequestStatus
    public var httpStatus: Int?
    public init(id: UUID = UUID(), date: Date = Date(), provider: CoachProvider, model: String, conversationID: UUID? = nil,
                origin: String? = nil, purpose: AIRequestPurpose, body: Data, toolCalls: [AIRecordedToolCall] = [],
                denials: [AIRecordedDenial] = [], status: AIRequestStatus = .sent, httpStatus: Int? = nil) {
        self.id = id; self.date = date; self.provider = provider; self.model = model; self.conversationID = conversationID
        self.origin = origin; self.purpose = purpose; self.body = body; self.toolCalls = toolCalls
        self.denials = denials; self.status = status; self.httpStatus = httpStatus
    }
}

/// The request-log seam. `willSend` runs with the exact body before every provider send in `stream`,
/// `structured` and `turn`, on the sending task. Keep it quick and do not throw. A store that must
/// persist before the bytes leave should do that work synchronously inside `willSend`.
public protocol AIRequestRecording: Sendable {
    func willSend(_ record: AIRequestRecord)
    /// Called once per `willSend` when the request ends. `httpStatus` is nil when no response arrived.
    func didFinish(id: UUID, status: AIRequestStatus, httpStatus: Int?)
}

public extension AIRequestRecording {
    func didFinish(id: UUID, status: AIRequestStatus, httpStatus: Int?) {}
}

/// Closure form of the seam, for tests and small hosts.
public struct AIRequestRecorderClosure: AIRequestRecording {
    private let onSend: @Sendable (AIRequestRecord) -> Void
    private let onFinish: @Sendable (UUID, AIRequestStatus, Int?) -> Void
    public init(willSend: @escaping @Sendable (AIRequestRecord) -> Void,
                didFinish: @escaping @Sendable (UUID, AIRequestStatus, Int?) -> Void = { _, _, _ in }) {
        onSend = willSend; onFinish = didFinish
    }
    public func willSend(_ record: AIRequestRecord) { onSend(record) }
    public func didFinish(id: UUID, status: AIRequestStatus, httpStatus: Int?) { onFinish(id, status, httpStatus) }
}

/// Wraps one recorded send so every exit path reports a status exactly once.
struct AIRequestRecordingScope: Sendable {
    private let recorder: AIRequestRecording?
    private let id: UUID
    init(recorder: AIRequestRecording?, provider: CoachProvider, model: String, context: AIRequestContext, body: Data,
         toolCalls: [AIRecordedToolCall] = [], denials: [AIRecordedDenial] = []) {
        self.recorder = recorder
        let record = AIRequestRecord(provider: provider, model: model, conversationID: context.conversationID,
                                     origin: context.origin, purpose: context.purpose, body: body,
                                     toolCalls: toolCalls, denials: denials)
        id = record.id
        recorder?.willSend(record)
    }
    func finish(_ status: AIRequestStatus, httpStatus: Int? = nil) { recorder?.didFinish(id: id, status: status, httpStatus: httpStatus) }
    func finish(error: Error, httpStatus: Int? = nil) {
        let normalized = CoachProviderError.normalize(error)
        let status: AIRequestStatus
        if normalized == .cancelled { status = .cancelled }
        else if (error as? CoachStructuredError) == .refused { status = .refused }
        else { status = .failed }
        finish(status, httpStatus: httpStatus)
    }
}

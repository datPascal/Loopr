import AIKit
import Foundation

/// Something the chat could not do, with the one or two actions that fix it.
/// The chat shows it as a card above the composer.
struct CoachProblem: Equatable, Identifiable {
    enum Kind: Equatable {
        case offline, interrupted, credentials, quota, busy, server, timeout, secureConnection
        case storage, tooLong, unfinishedReply, full, input, other, reconnect
    }
    enum Action: Equatable {
        case retry
        case openProviders(String)
        case newChat
        case billing(URL)
        case dismiss

        var title: String {
            switch self {
            case .retry: "Retry reply"
            case .openProviders(let title): title
            case .newChat: "New chat"
            case .billing: "Check billing"
            case .dismiss: "Dismiss"
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let message: String
    let actions: [Action]

    var symbol: String {
        switch kind {
        case .offline: "wifi.slash"
        case .interrupted, .timeout: "bolt.horizontal"
        case .credentials, .reconnect: "key"
        case .quota: "creditcard"
        case .busy, .server, .other: "exclamationmark.triangle"
        case .secureConnection: "lock.slash"
        case .storage: "externaldrive.badge.exclamationmark"
        case .tooLong, .input: "text.badge.minus"
        case .unfinishedReply: "arrow.clockwise"
        case .full: "bubble.left.and.exclamationmark.bubble.right"
        }
    }

    var hasRetry: Bool { actions.contains(.retry) }
    /// Spoken once when the card appears.
    var announcement: String { "\(title). \(message)" }

    init(id: String = UUID().uuidString, kind: Kind, title: String, message: String, actions: [Action]) {
        self.id = id; self.kind = kind; self.title = title; self.message = message; self.actions = actions
    }

    /// Builds the card for a provider failure. `hadPartialReply` is true when text had already
    /// streamed in, so a dropped connection reads as an interruption, not as being offline.
    /// Returns nil for a cancellation, which the person asked for.
    static func make(_ error: CoachProviderError, provider: CoachProvider, hadPartialReply: Bool) -> CoachProblem? {
        var error = error
        if hadPartialReply, error == .offline || error == .timeout { error = .connectionLost }
        let text = error.localizedDescription
        switch error {
        case .cancelled:
            return nil
        case .missingKey:
            return .init(kind: .credentials, title: "Add an API key", message: text, actions: [.openProviders("Add API key")])
        case .invalidKey:
            return .init(kind: .credentials, title: "API key rejected", message: text, actions: [.openProviders("Review key")])
        case .permission:
            return .init(kind: .credentials, title: "Key not allowed", message: text, actions: [.openProviders("Open AI providers")])
        case .modelUnavailable:
            return .init(kind: .credentials, title: "Model unavailable", message: text, actions: [.openProviders("Open AI providers")])
        case .configurationChanged:
            return .init(kind: .credentials, title: "Provider settings changed", message: text, actions: [.openProviders("Review settings")])
        case .quota:
            return .init(kind: .quota, title: "No credit left", message: text, actions: [.billing(provider.billingURL), .openProviders("Open AI providers")])
        case .rateLimited:
            return .init(kind: .busy, title: "\(provider.name) is busy", message: text, actions: [.retry])
        case .server:
            return .init(kind: .server, title: "\(provider.name) is unavailable", message: text, actions: [.retry])
        case .timeout:
            return .init(kind: .timeout, title: "No answer in time", message: text, actions: [.retry])
        case .offline:
            return .init(kind: .offline, title: "No connection", message: text, actions: [.retry])
        case .connectionLost:
            let detail = hadPartialReply ? text : "The connection dropped before a reply arrived. Retry sends your question again."
            return .init(kind: .interrupted, title: "Connection dropped", message: detail, actions: [.retry])
        case .secureConnection:
            return .init(kind: .secureConnection, title: "Secure connection failed", message: text, actions: [.retry])
        case .malformedResponse, .incomplete, .http:
            return .init(kind: .other, title: "Reply did not finish", message: text, actions: [.retry])
        case .storage:
            return .init(kind: .storage, title: "Could not save this chat", message: text, actions: [.dismiss])
        case .conversationFull:
            return .init(kind: .full, title: "This chat is full", message: text, actions: [.newChat])
        case .emptyMessage:
            return .init(kind: .input, title: "Nothing to send", message: text, actions: [.dismiss])
        }
    }

    /// The card for any error. Provider and network failures get their own copy. Anything else,
    /// such as a Keychain or storage failure, says so plainly instead of blaming the provider.
    /// Returns nil for a cancellation.
    static func make(_ error: Error, provider: CoachProvider, hadPartialReply: Bool) -> CoachProblem? {
        if error is CoachProviderError || error is CancellationError || error is URLError {
            return make(CoachProviderError.normalize(error), provider: provider, hadPartialReply: hadPartialReply)
        }
        if let message = (error as? LocalizedError)?.errorDescription {
            return .init(kind: .other, title: "Something went wrong", message: message, actions: [.dismiss])
        }
        return .init(kind: .other, title: "Something went wrong",
                     message: "Loopr hit a problem on this iPhone. Nothing was sent. Try again.", actions: [.dismiss])
    }

    static func unfinishedReply() -> CoachProblem {
        .init(kind: .unfinishedReply, title: "Finish the last reply first",
              message: "Retry the unfinished reply, or start a new chat.", actions: [.retry, .newChat])
    }
    static func tooLong(limit: Int) -> CoachProblem {
        .init(kind: .tooLong, title: "Message too long",
              message: "Keep your message under \(limit.formatted()) characters.", actions: [.dismiss])
    }
    static func other(title: String, message: String) -> CoachProblem {
        .init(kind: .other, title: title, message: message, actions: [.dismiss])
    }
    static func reconnect(provider: CoachProvider) -> CoachProblem {
        .init(id: "reconnect-\(provider.rawValue)", kind: .reconnect, title: "Reconnect \(provider.name)",
              message: "This chat's key is gone from this iPhone. Add it again to keep chatting here, or start a new chat with another provider.",
              actions: [.openProviders("Open AI providers")])
    }
}

/// A short confirmation shown above the composer for a few seconds.
struct CoachInfo: Equatable, Identifiable {
    let id = UUID()
    let message: String
}

/// Things the screen answers with a haptic or a VoiceOver announcement.
struct CoachEvent: Equatable {
    enum Kind: Equatable { case replyStarted, replyFinished, consentAllowed, journalSaved, chatDeleted, startedFreshChat }
    let id = UUID()
    let kind: Kind
}

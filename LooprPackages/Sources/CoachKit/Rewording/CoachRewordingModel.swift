import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The seam between the rewriter and a language model. The app uses `SystemCoachRewordingModel`, which runs Apple's
/// model on this iPhone. Tests use a fake that returns fixed strings, fails or never answers. Nothing behind this
/// protocol may reach the network.
public protocol CoachRewordingModel: Sendable {
    /// True when the model can answer now. A model that is off, still downloading or not supported says false.
    var isAvailable: Bool { get }
    /// The reworded text for `text`. Throws when the model fails. The rewriter checks what comes back, so a model
    /// is never trusted.
    func reword(_ text: String, instructions: String) async throws -> String
}

/// The model of a device that has none: always unavailable, so every note keeps its rule text.
public struct UnavailableCoachRewordingModel: CoachRewordingModel {
    public init() {}
    public var isAvailable: Bool { false }
    public func reword(_ text: String, instructions: String) async throws -> String {
        throw CoachRewordingModelError.unavailable
    }
}

public enum CoachRewordingModelError: Error, Equatable, Sendable {
    case unavailable
}

#if canImport(FoundationModels)
/// Apple's on-device model (`SystemLanguageModel.default`). It runs on this iPhone and sends nothing anywhere.
@available(iOS 26.0, macOS 26.0, *)
public struct SystemCoachRewordingModel: CoachRewordingModel {
    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func reword(_ text: String, instructions: String) async throws -> String {
        guard isAvailable else { throw CoachRewordingModelError.unavailable }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 240)
        return try await session.respond(to: text, options: options).content
    }
}
#endif

public extension CoachRewordingModel where Self == UnavailableCoachRewordingModel {
    static var unavailable: UnavailableCoachRewordingModel { UnavailableCoachRewordingModel() }
}

/// The model this device can use: Apple's when the framework is there and the OS is iOS 26 or later, and none otherwise.
/// Whether it is available right now is `isAvailable` on the result.
public func systemCoachRewordingModel() -> any CoachRewordingModel {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) { return SystemCoachRewordingModel() }
    #endif
    return UnavailableCoachRewordingModel()
}

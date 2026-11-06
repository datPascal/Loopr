import AVFoundation
import Combine
import Foundation
import Speech

/// Why dictation is not running, in words the person can act on.
enum CoachDictationIssue: Equatable {
    case speechDenied, microphoneDenied, languageUnavailable, microphoneFailed, interrupted, timeLimit

    var message: String {
        switch self {
        case .speechDenied: "Allow speech recognition in Settings to dictate a message."
        case .microphoneDenied: "Allow microphone access in Settings to dictate a message."
        case .languageUnavailable: "On-device dictation is unavailable for this language. You can still type your message."
        case .microphoneFailed: "Could not start the microphone. Try again or type your message."
        case .interrupted: "Dictation stopped because another app or call used the microphone."
        case .timeLimit: "Dictation stopped after 60 seconds. Tap the microphone to keep going."
        }
    }
    /// Permission problems are fixed in the Settings app.
    var needsSettings: Bool { self == .speechDenied || self == .microphoneDenied }
    /// A limit or an interruption is information. The rest are failures.
    var isFailure: Bool { self != .interrupted && self != .timeLimit }
}

@MainActor
final class CoachDictation: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var issue: CoachDictationIssue?
    var error: String? { issue?.message }
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var installedTap = false
    private var sessionActive = false
    private var recognizer: SFSpeechRecognizer?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []

    func clearIssue() { issue = nil }

    #if DEBUG
    /// UI tests set this to dictate without a microphone, a permission alert or a speech model.
    static var fixtureTranscript: String?
    #endif

    func start(onText: @escaping @MainActor (String) -> Void) async {
        stop(); issue = nil
        #if DEBUG
        if let script = Self.fixtureTranscript {
            generation = UUID(); recording = true
            onText(script)
            return
        }
        #endif
        let id = UUID(); generation = id
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard id == generation else { return }
        guard speech == .authorized else { issue = .speechDenied; return }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard id == generation else { return }
        guard microphone else { issue = .microphoneDenied; return }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            issue = .languageUnavailable; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true); sessionActive = true
            self.recognizer = recognizer
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CoachDictationError.noMicrophone }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            self.request = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: request))
            installedTap = true
            recognition = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(owner: self, id: id, onText: onText))
            engine.prepare(); try engine.start(); recording = true
            observeInterruptions(id: id)
            timeout = Task {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, generation == id else { return }
                stop(); issue = .timeLimit
            }
        } catch { stop(); issue = .microphoneFailed }
    }
    func stop() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil; recognizer = nil
        recording = false
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    /// A call, Siri or a route change ends the recording. Without this the mic icon would stay
    /// lit until the 60 second limit.
    private func observeInterruptions(id: UUID) {
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification, .AVAudioEngineConfigurationChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) != .ended
                MainActor.assumeIsolated {
                    guard let self, self.generation == id, self.recording, began else { return }
                    self.stop(); self.issue = .interrupted
                }
            })
        }
    }

    // These callbacks run on the audio and speech threads. Building them in nonisolated
    // functions keeps them from inheriting the main actor, which would trap at runtime.
    nonisolated private static func tapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }
    nonisolated private static func resultHandler(owner: CoachDictation, id: UUID, onText: @escaping @MainActor (String) -> Void) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, failure in
            let text = result?.bestTranscription.formattedString
            let finished = result?.isFinal == true || failure != nil
            Task { @MainActor in
                guard let owner, owner.generation == id else { return }
                if let text { onText(text) }
                if finished { owner.stop() }
            }
        }
    }
}
nonisolated private enum CoachDictationError: Error { case noMicrophone }

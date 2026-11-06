@preconcurrency import AVFoundation
import FoodKit
import SwiftUI
import Vision

nonisolated enum FoodCameraError: Error, LocalizedError {
    case unavailable, denied, interrupted, capture
    var errorDescription: String? {
        switch self {
        case .unavailable: "The camera is unavailable. Choose a photo or enter your food."
        case .denied: "Allow camera access in Settings, or choose a photo or text entry."
        case .interrupted: "The camera stopped. Try again or choose a photo."
        case .capture: "The photo could not be captured. Try again."
        }
    }
}

/// Session configuration, capture and shutdown run on one serial queue.
nonisolated final class FoodCamera: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "loopr.food.camera")
    private let frames = DispatchQueue(label: "loopr.food.camera.frames", qos: .utility)
    private let output = AVCapturePhotoOutput()
    private var photoDelegate: FoodPhotoDelegate?
    private var frameDelegate: FoodFrameDelegate?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var configured = false
    private var device: AVCaptureDevice?
    private var observers: [NSObjectProtocol] = []

    /// - Parameter barcode: Called once a code reads the same in two frames in a row, with the code
    ///   lifted out of the frame. Nil leaves barcodes alone.
    func start(labels: @escaping @MainActor @Sendable ([String]) -> Void,
               barcode: (@MainActor @Sendable (FoodLensBarcodeHit) -> Void)? = nil,
               failure: @escaping @MainActor @Sendable (String) -> Void) async throws {
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard allowed else { throw FoodCameraError.denied }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if !self.configured {
                        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw FoodCameraError.unavailable }
                        let input = try AVCaptureDeviceInput(device: camera)
                        self.session.beginConfiguration()
                        defer { self.session.commitConfiguration() }
                        self.session.sessionPreset = .photo
                        guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else { throw FoodCameraError.unavailable }
                        self.session.addInput(input); self.session.addOutput(self.output)
                        self.device = camera
                        let video = AVCaptureVideoDataOutput(); video.alwaysDiscardsLateVideoFrames = true
                        if self.session.canAddOutput(video) {
                            self.session.addOutput(video); self.videoOutput = video
                        }
                        self.configured = true
                    }
                    let delegate = FoodFrameDelegate(labels: labels, barcode: barcode)
                    self.videoOutput?.setSampleBufferDelegate(delegate, queue: self.frames)
                    self.frameDelegate = delegate
                    if self.observers.isEmpty {
                        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
                            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: self.session, queue: nil) { _ in
                                Task { @MainActor in failure(FoodCameraError.interrupted.localizedDescription) }
                            })
                        }
                    }
                    self.session.startRunning()
                    guard self.session.isRunning else { throw FoodCameraError.unavailable }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func capture(at date: Date) async throws -> FoodPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session.isRunning, self.photoDelegate == nil else {
                    continuation.resume(throwing: FoodCameraError.capture); return
                }
                let delegate = FoodPhotoDelegate(date: date) { [weak self] result in
                    guard let self else { continuation.resume(throwing: FoodCameraError.capture); return }
                    self.queue.async {
                        self.photoDelegate = nil
                        continuation.resume(with: result)
                    }
                }
                self.photoDelegate = delegate
                self.output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: delegate)
            }
        }
    }
    /// Turns the torch on or off. Returns false when this camera has none.
    func setTorch(_ on: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let device = self.device, device.hasTorch, (try? device.lockForConfiguration()) != nil else {
                    continuation.resume(returning: false); return
                }
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
                continuation.resume(returning: true)
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let device = self.device, device.torchMode != .off, (try? device.lockForConfiguration()) != nil {
                    device.torchMode = .off; device.unlockForConfiguration()
                }
                if self.session.isRunning { self.session.stopRunning() }
                self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
                self.frameDelegate = nil
                for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
                self.observers.removeAll()
                continuation.resume()
            }
        }
    }
}

nonisolated private final class FoodPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let date: Date
    let completion: @Sendable (Result<FoodPhoto, Error>) -> Void
    private var result: Result<FoodPhoto, Error> = .failure(FoodCameraError.capture)
    init(date: Date, completion: @escaping @Sendable (Result<FoodPhoto, Error>) -> Void) { self.date = date; self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { result = .failure(error); return }
        guard let data = photo.fileDataRepresentation() else { return }
        result = Result { try FoodPhoto(type: .jpeg, capturedAt: date, bytes: data) }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(error.map { .failure($0) } ?? result)
    }
}

nonisolated private final class FoodFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let labels: @MainActor @Sendable ([String]) -> Void
    let barcode: (@MainActor @Sendable (FoodLensBarcodeHit) -> Void)?
    private var lastFrame = Date.distantPast
    private var lastBarcodeFrame = Date.distantPast
    /// The code seen in the previous barcode frame. A code has to read the same twice before it counts.
    private var candidate: String?
    private var delivered = false
    init(labels: @escaping @MainActor @Sendable ([String]) -> Void, barcode: (@MainActor @Sendable (FoodLensBarcodeHit) -> Void)?) {
        self.labels = labels; self.barcode = barcode
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        if barcode != nil, !delivered, now.timeIntervalSince(lastBarcodeFrame) >= 0.12 {
            lastBarcodeFrame = now
            detectBarcode(in: buffer)
        }
        guard now.timeIntervalSince(lastFrame) >= 2 else { return }
        lastFrame = now
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right).perform([request])
            let names = (request.results ?? []).filter { $0.confidence >= 0.6 }.prefix(3).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            Task { @MainActor in labels(names) }
        } catch { Task { @MainActor in labels([]) } }
    }
    private func detectBarcode(in buffer: CVPixelBuffer) {
        guard let observation = FoodLensArt.barcodes(in: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)).first,
              let code = FoodLensArt.code(of: observation) else { candidate = nil; return }
        guard candidate == code else { candidate = code; return }
        let frame = CIImage(cvPixelBuffer: buffer).oriented(.right)
        guard let hit = FoodLensArt.hit(observation, in: frame) else { return }
        delivered = true
        let barcode = barcode
        Task { @MainActor in barcode?(hit) }
    }
}

struct FoodCameraPreview: UIViewRepresentable {
    let camera: FoodCamera
    func makeUIView(context: Context) -> Preview {
        let view = Preview(); view.layerPreview.videoGravity = .resizeAspectFill; view.layerPreview.session = camera.session
        return view
    }
    func updateUIView(_ view: Preview, context: Context) {}
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerPreview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

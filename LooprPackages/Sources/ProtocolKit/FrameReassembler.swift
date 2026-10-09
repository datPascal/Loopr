import Foundation

/// Reassembles complete Gen 4 frames from the notifications of one inbound
/// characteristic.
///
/// A reassembler is intentionally a value type.  The caller creates one
/// instance for each inbound characteristic and feeds each notification to
/// that instance in order.  It retains only a bounded candidate stream and
/// emits frames after the strict `FrameDecoder` has validated both CRCs.
public struct FrameReassembler: Sendable {
    /// The upstream transport clears an overgrown partial buffer at 8 KiB.
    /// Loopr keeps the same hard retained-memory ceiling while enforcing the
    /// stricter 4 KiB maximum for an individual frame.
    public static let maximumBufferedBytes = 8_192

    public let maximumBufferedBytes = FrameReassembler.maximumBufferedBytes

    private var buffer = Data()
    private var errorsStorage: [ProtocolDecodeError] = []

    public private(set) var maximumObservedBufferedBytes = 0
    public private(set) var rejectionCount = 0
    public private(set) var lastError: ProtocolDecodeError?

    /// A bounded diagnostic history.  Error retention is capped independently
    /// of the byte buffer so a corrupt notification stream cannot grow memory
    /// through diagnostics either.
    public var errors: [ProtocolDecodeError] { errorsStorage }

    /// Number of bytes retained from the current partial candidate stream.
    public var bufferedByteCount: Int { buffer.count }

    public init() {}

    /// Ingests one BLE notification and returns every newly completed frame.
    ///
    /// Notifications may contain arbitrary fragments, concatenated frames, or
    /// garbage.  A valid header fixes a candidate boundary; embedded marker
    /// bytes are therefore ignored until that candidate is complete.  If the
    /// candidate fails its tail CRC, recovery drops only the rejected
    /// candidate's first marker and deterministically scans for the next valid
    /// marker.  This preserves a following frame even when dropped bytes made
    /// it overlap the rejected candidate's declared boundary.
    @discardableResult
    public mutating func ingest(_ bytes: Data) -> [Frame] {
        var frames: [Frame] = []
        for byte in bytes {
            append(byte)
            frames.append(contentsOf: processAvailable())
        }
        return frames
    }

    /// Discards all partial state and bounded diagnostics, as on disconnect.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        errorsStorage.removeAll(keepingCapacity: true)
        maximumObservedBufferedBytes = 0
        rejectionCount = 0
        lastError = nil
    }

    private mutating func append(_ byte: UInt8) {
        // Byte-at-a-time ingestion allows processing to run before another
        // notification byte is retained.  The guard remains a final hard cap
        // for malformed input and protects the invariant if this method is
        // changed to batch append in the future.
        if buffer.count == Self.maximumBufferedBytes {
            buffer.removeFirst()
        }
        buffer.append(byte)
        maximumObservedBufferedBytes = max(maximumObservedBufferedBytes, buffer.count)
        if buffer.count > Self.maximumBufferedBytes {
            buffer = Data(buffer.suffix(Self.maximumBufferedBytes))
        }
    }

    private mutating func processAvailable() -> [Frame] {
        var frames: [Frame] = []

        while true {
            guard !buffer.isEmpty else { return frames }

            // Deterministic garbage recovery: retain only the first marker and
            // discard every preceding byte.  This is the only recovery path
            // while a candidate has not yet been accepted by its header.
            guard buffer[0] == Gen4Frame.marker else {
                discardUntilMarker()
                continue
            }

            // Marker, two length bytes, and length CRC-8 are required before a
            // candidate can be classified.  A short header remains buffered.
            guard buffer.count >= 4 else { return frames }

            let declared = Int(buffer[1]) | (Int(buffer[2]) << 8)
            guard declared >= Gen4Frame.minimumDeclaredLength else {
                reject(.invalidValue(
                    offset: 1,
                    reason: "declared length \(declared) is below minimum \(Gen4Frame.minimumDeclaredLength)"
                ))
                discardRejectedMarker()
                continue
            }

            let total = declared + 4 // declared is UInt16-derived; no overflow is possible.
            guard total <= Gen4Frame.maximumTotalLength else {
                reject(.invalidRange(
                    offset: 1,
                    reason: "total frame length \(total) exceeds maximum \(Gen4Frame.maximumTotalLength)"
                ))
                discardRejectedMarker()
                continue
            }

            let expectedCRC8 = CRC8.calculate(Data([buffer[1], buffer[2]]))
            guard buffer[3] == expectedCRC8 else {
                reject(.invalidValue(
                    offset: 3,
                    reason: "CRC-8 mismatch for declared length \(declared)"
                ))
                discardRejectedMarker()
                continue
            }

            // Once this header is valid, no embedded marker may cause an early
            // split.  Wait for exactly the declared candidate boundary.
            guard buffer.count >= total else { return frames }

            let candidate = Data(buffer.prefix(total))
            do {
                frames.append(try FrameDecoder().decode(candidate))
                buffer = Data(buffer.dropFirst(total))
            } catch let error as ProtocolDecodeError {
                reject(error)
                // Do not remove the whole failed candidate.  If bytes were
                // dropped from its body, a following intact frame may already
                // overlap this declared boundary.  Dropping one byte and
                // rescanning lets the valid marker survive while still never
                // splitting a candidate whose header and CRC are valid.
                discardRejectedMarker()
            } catch {
                let error = ProtocolDecodeError.invalidValue(
                    offset: max(0, total - 4),
                    reason: "unexpected frame decode failure: \(error)"
                )
                reject(error)
                discardRejectedMarker()
            }
        }
    }

    private mutating func discardUntilMarker() {
        guard let marker = buffer.firstIndex(of: Gen4Frame.marker) else {
            buffer.removeAll(keepingCapacity: true)
            return
        }
        guard marker > 0 else { return }
        buffer = Data(buffer.dropFirst(marker))
    }

    private mutating func discardRejectedMarker() {
        guard !buffer.isEmpty else { return }
        buffer = Data(buffer.dropFirst())
    }

    private mutating func reject(_ error: ProtocolDecodeError) {
        #if DEBUG
        fputs("[Loopr Frames] rejected: \(error)\n", stderr)
        #endif
        rejectionCount += 1
        lastError = error
        if errorsStorage.count == 64 {
            errorsStorage.removeFirst()
        }
        errorsStorage.append(error)
    }
}

import Foundation

public enum ProfiledFrame: Equatable, Sendable {
    case gen4(Frame)
    case gen5(Gen5DecodedFrame)
}

public enum ProfiledFrameDispatchError: Error, Equatable, Sendable {
    case generationMismatch(expected: BandGeneration)
    case malformedGen4(ProtocolDecodeError)
    case malformedGen5(Gen5FrameError)
}

public struct ProfiledFrameDispatcher: Sendable {
    public init() {}

    public func decode(_ raw: Data, profile: BandProfile) throws -> ProfiledFrame {
        switch profile.generation {
        case .gen4:
            do { return .gen4(try FrameDecoder().decode(raw)) }
            catch let error as ProtocolDecodeError { throw ProfiledFrameDispatchError.malformedGen4(error) }
            catch { throw ProfiledFrameDispatchError.generationMismatch(expected: .gen4) }
        case .gen5:
            do { return .gen5(try Gen5FrameCodec().decode(raw)) }
            catch let error as Gen5FrameError { throw ProfiledFrameDispatchError.malformedGen5(error) }
            catch { throw ProfiledFrameDispatchError.generationMismatch(expected: .gen5) }
        }
    }
}

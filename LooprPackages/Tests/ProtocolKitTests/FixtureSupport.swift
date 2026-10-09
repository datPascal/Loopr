import Foundation

struct FrameVector: Decodable {
    let hex: String
    let source: String
}

struct InitFrameVector: Decodable {
    let sequence: UInt8
    let opcode: String
    let purpose: String
    let hex: String
    let source: String
}

struct ClockFixture: Decodable {
    let vectors: [ClockVector]
}

struct ClockVector: Decodable {
    let sequence: UInt8
    let literalTestedInnerHex: String
    let fullFrameHex: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case literalTestedInnerHex = "literal_tested_inner_hex"
        case fullFrameHex = "full_frame_hex"
    }
}

struct HistoryAckFixture: Decodable {
    let vectors: [HistoryAckVector]
}

struct HistoryAckVector: Decodable {
    let sequence: UInt8
    let tokenHex: String?
    let literalTestedInnerHex: String
    let fullFrameHex: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case tokenHex = "token_hex"
        case literalTestedInnerHex = "literal_tested_inner_hex"
        case fullFrameHex = "full_frame_hex"
    }
}

enum ProtocolFixtureSupport {
    static let repositoryRoot: URL = {
        // .../LooprPackages/Tests/ProtocolKitTests/<file.swift> -> repository root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    static func frameVectors() throws -> [FrameVector] {
        let url = repositoryRoot.appendingPathComponent("Fixtures/Protocol/frame_vectors.json")
        return try JSONDecoder().decode([FrameVector].self, from: Data(contentsOf: url))
    }

    static func initFrameVectors() throws -> [InitFrameVector] {
        let url = repositoryRoot.appendingPathComponent("Fixtures/Protocol/init_frames.json")
        return try JSONDecoder().decode([InitFrameVector].self, from: Data(contentsOf: url))
    }

    static func clockVectors() throws -> [ClockVector] {
        let url = repositoryRoot.appendingPathComponent("Fixtures/Protocol/clock_vectors.json")
        return try JSONDecoder().decode(ClockFixture.self, from: Data(contentsOf: url)).vectors
    }

    static func historyAckVectors() throws -> [HistoryAckVector] {
        let url = repositoryRoot.appendingPathComponent("Fixtures/Protocol/history_ack_vectors.json")
        return try JSONDecoder().decode(HistoryAckFixture.self, from: Data(contentsOf: url)).vectors
    }

    static func recordHex(_ name: String) throws -> Data {
        let url = repositoryRoot.appendingPathComponent("Fixtures/Protocol/records/\(name)")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any],
              let rawHex = (dictionary["raw_hex"] as? String)
                ?? ((dictionary["inner_record"] as? [String: Any])?["raw_hex"] as? String)
        else {
            throw FixtureError.missingField(name: name, key: "raw_hex")
        }
        return try data(hex: rawHex)
    }

    static func malformedHex(_ name: String, key: String = "resulting_hex") throws -> Data {
        let url = repositoryRoot.appendingPathComponent("Fixtures/Protocol/malformed/\(name).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any], let hex = dictionary[key] as? String else {
            throw FixtureError.missingField(name: name, key: key)
        }
        return try data(hex: hex)
    }

    static func data(hex: String) throws -> Data {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2) else {
            throw FixtureError.invalidHex(hex)
        }

        var output = Data()
        output.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                throw FixtureError.invalidHex(hex)
            }
            output.append(byte)
            index = next
        }
        return output
    }

    enum FixtureError: Error {
        case invalidHex(String)
        case missingField(name: String, key: String)
    }
}

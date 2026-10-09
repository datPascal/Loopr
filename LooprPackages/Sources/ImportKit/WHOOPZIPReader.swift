import Foundation
import Compression

/// Reads ordinary single-volume ZIP archives, using the central directory so
/// entries with data descriptors work too. Format facts: PKWARE APPNOTE 6.3.10,
/// sections 4.3.7, 4.3.12 and 4.3.16. Compression's COMPRESSION_ZLIB decodes raw
/// DEFLATE, as documented by Apple. No archive paths are written to disk.
public enum WHOOPZIPReader {
    public static let maximumEntryBytes = 256 * 1_024 * 1_024
    public static let maximumTotalBytes = 512 * 1_024 * 1_024

    public static func extractCSVs(from url: URL, into directory: URL) throws -> [URL] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { throw WHOOPImportError.invalidZIP }
        guard data.count <= maximumTotalBytes else { throw WHOOPImportError.oversized }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw WHOOPImportError.invalidZIP }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= data.count else { throw WHOOPImportError.invalidZIP }
            return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        var footer: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if (try u32(offset)) == 0x06054b50, offset + 22 + ((try u16(offset + 20))) == data.count { footer = offset; break }
        }
        guard let footer else { throw WHOOPImportError.invalidZIP }
        guard (try u16(footer + 4)) == 0, (try u16(footer + 6)) == 0,
              (try u16(footer + 8)) == (try u16(footer + 10)), (try u16(footer + 10)) != 0xffff else { throw WHOOPImportError.unsupportedZIP }
        let count = (try u16(footer + 10)), size = (try u32(footer + 12))
        var cursor = (try u32(footer + 16))
        let centralEnd = cursor + size
        guard centralEnd <= footer, cursor >= 0 else { throw WHOOPImportError.invalidZIP }
        var output: [URL] = []; var total = 0; var names = Set<String>()
        for _ in 0..<count {
            guard (try u32(cursor)) == 0x02014b50 else { throw WHOOPImportError.invalidZIP }
            let flags = (try u16(cursor + 8)), method = (try u16(cursor + 10))
            let crc = UInt32((try u32(cursor + 16))), compressed = (try u32(cursor + 20)), expanded = (try u32(cursor + 24))
            let nameLength = (try u16(cursor + 28)), extra = (try u16(cursor + 30)), comment = (try u16(cursor + 32))
            let local = (try u32(cursor + 42))
            guard cursor + 46 + nameLength + extra + comment <= centralEnd,
                  (try u16(cursor + 34)) == 0 else { throw WHOOPImportError.invalidZIP }
            let nameBytes = data[(cursor + 46)..<(cursor + 46 + nameLength)]
            guard let path = String(data: nameBytes, encoding: .utf8) else { throw WHOOPImportError.invalidZIP }
            cursor += 46 + nameLength + extra + comment
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            guard WHOOPExportKind.allCases.contains(where: { name == $0.rawValue + ".csv" }) else { continue }
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains(".."),
                  names.insert(name).inserted else { throw WHOOPImportError.invalidZIP }
            guard flags & 0x41 == 0, method == 0 || method == 8 else { throw WHOOPImportError.unsupportedZIP }
            guard expanded <= maximumEntryBytes, compressed <= maximumEntryBytes else { throw WHOOPImportError.oversized }
            total += expanded
            guard total <= maximumTotalBytes else { throw WHOOPImportError.oversized }
            guard (try u32(local)) == 0x04034b50, (try u16(local + 8)) == method, (try u16(local + 6)) == flags else { throw WHOOPImportError.invalidZIP }
            let localNameLength = (try u16(local + 26)), localExtra = (try u16(local + 28))
            let start = local + 30 + localNameLength + localExtra
            guard start <= centralEnd - compressed, start + compressed <= ((try u32(footer + 16))),
                  local + 30 + localNameLength <= data.count,
                  data[(local + 30)..<(local + 30 + localNameLength)] == nameBytes else { throw WHOOPImportError.invalidZIP }
            let target = directory.appendingPathComponent(name)
            _ = FileManager.default.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            do {
                var checksum: UInt32 = 0xffffffff; var written = 0
                func write(_ buffer: UnsafeBufferPointer<UInt8>) throws {
                    written += buffer.count
                    guard written <= expanded else { throw WHOOPImportError.corruptZIP }
                    for byte in buffer {
                        checksum = (checksum >> 8) ^ crcTable[Int((checksum ^ UInt32(byte)) & 0xff)]
                    }
                    try handle.write(contentsOf: Data(buffer: buffer))
                }
                try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let input = raw.bindMemory(to: UInt8.self)
                    if method == 0 {
                        guard compressed == expanded else { throw WHOOPImportError.corruptZIP }
                        try write(UnsafeBufferPointer(start: input.baseAddress! + start, count: compressed))
                    } else {
                        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
                        defer { buffer.deallocate() }
                        var stream = compression_stream(dst_ptr: buffer, dst_size: 65_536,
                            src_ptr: input.baseAddress! + start, src_size: compressed, state: nil)
                        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { throw WHOOPImportError.corruptZIP }
                        defer { compression_stream_destroy(&stream) }
                        stream.src_ptr = input.baseAddress! + start; stream.src_size = compressed
                        while true {
                            stream.dst_ptr = buffer; stream.dst_size = 65_536
                            let prior = stream.src_size
                            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                            guard status != COMPRESSION_STATUS_ERROR else { throw WHOOPImportError.corruptZIP }
                            let produced = 65_536 - stream.dst_size
                            try write(UnsafeBufferPointer(start: buffer, count: produced))
                            if status == COMPRESSION_STATUS_END {
                                guard stream.src_size == 0 else { throw WHOOPImportError.corruptZIP }; break
                            }
                            guard produced > 0 || stream.src_size < prior else { throw WHOOPImportError.corruptZIP }
                        }
                    }
                }
                guard written == expanded, checksum ^ 0xffffffff == crc else { throw WHOOPImportError.corruptZIP }
                try handle.close(); output.append(target)
            } catch {
                try? handle.close(); try? FileManager.default.removeItem(at: target); throw error
            }
        }
        guard cursor == centralEnd, !output.isEmpty else { throw WHOOPImportError.noCSV }
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
        return value
    }
}

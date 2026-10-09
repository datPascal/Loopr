import Foundation
import ProtocolKit
import XCTest

final class ByteCursorTests: XCTestCase {
    func test_byteCursor_emptyInputThrows() {
        var cursor = ByteCursor(Data())

        do {
            _ = try cursor.readByte()
            XCTFail("An empty cursor must reject a read")
        } catch let error as ProtocolDecodeError {
            XCTAssertEqual(error.offset, 0)
            XCTAssertTrue(error.reason.contains("truncated"), error.reason)
            XCTAssertTrue(error.reason.contains("1"), error.reason)
            XCTAssertEqual(cursor.position, 0, "A failed read must not partially advance")
        } catch {
            XCTFail("Expected ProtocolDecodeError, got \(error)")
        }
    }

    func test_byteCursor_littleEndianReadersRoundTripUnsignedSignedAndFloat() throws {
        // Fields are deliberately adjacent and have distinct widths so that
        // the test also exercises cursor advancement between typed reads.
        let expectedUInt16: UInt16 = 0xBEEF
        let expectedUInt32: UInt32 = 0x7856_3412
        let expectedInt16: Int16 = -1234
        let expectedInt32: Int32 = -987_654
        let expectedFloat: Float = 12.5

        var bytes = Data()
        bytes.append(contentsOf: [0xEF, 0xBE])
        bytes.append(contentsOf: [0x12, 0x34, 0x56, 0x78])
        bytes.append(contentsOf: withUnsafeBytes(of: expectedInt16.littleEndian, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: expectedInt32.littleEndian, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: expectedFloat.bitPattern.littleEndian, Array.init))

        var cursor = ByteCursor(bytes)
        XCTAssertEqual(try cursor.readUInt16LE(), expectedUInt16)
        XCTAssertEqual(try cursor.readUInt32LE(), expectedUInt32)
        XCTAssertEqual(try cursor.readInt16LE(), expectedInt16)
        XCTAssertEqual(try cursor.readInt32LE(), expectedInt32)
        XCTAssertEqual(try cursor.readFloat32LE(), expectedFloat)
        XCTAssertEqual(cursor.remaining, 0)
    }

    func test_byteCursor_truncationAtEveryByteThrowsTypedErrorWithoutPartialValue() throws {
        let fixture = Self.multiFieldFixture()
        let fieldOffsets = [
            (offset: 0, width: 2),
            (offset: 2, width: 4),
            (offset: 6, width: 2),
            (offset: 8, width: 4),
            (offset: 12, width: 4)
        ]

        for length in 0..<fixture.count {
            var cursor = ByteCursor(Data(fixture.prefix(length)))
            let expectedField = fieldOffsets.first(where: {
                $0.offset >= length || $0.offset + $0.width > length
            })!
            let expectedRemaining = max(0, length - expectedField.offset)
            do {
                _ = try cursor.readUInt16LE()
                _ = try cursor.readUInt32LE()
                _ = try cursor.readInt16LE()
                _ = try cursor.readInt32LE()
                _ = try cursor.readFloat32LE()
                XCTFail("A \(length)-byte truncation unexpectedly decoded")
            } catch let error as ProtocolDecodeError {
                XCTAssertEqual(error.offset, expectedField.offset)
                XCTAssertEqual(
                    error.reason,
                    "truncated input: expected \(expectedField.width) byte(s), only \(expectedRemaining) remaining"
                )
                XCTAssertEqual(cursor.position, expectedField.offset)
            } catch {
                XCTFail("Expected ProtocolDecodeError for length \(length), got \(error)")
            }
        }
    }

    func test_byteCursor_sliceInsideBufferReturnsExactIndependentBytes() throws {
        let source = Data([0, 1, 2, 3, 4, 5])
        var cursor = ByteCursor(source)

        var slice = try cursor.readSlice(length: 3)
        XCTAssertEqual(slice, Data([0, 1, 2]))
        XCTAssertEqual(cursor.position, 3)

        // Mutating the returned Data must not affect the cursor's remaining
        // source bytes (the slice is a copied sub-range, not a view).
        slice[0] = 0xFF
        XCTAssertEqual(try cursor.readSlice(length: 3), Data([3, 4, 5]))

        XCTAssertEqual(try cursor.slice(offset: 1, length: 3), Data([1, 2, 3]))
    }

    func test_byteCursor_slicePastEndThrowsTypedErrorAtRequestedOffset() {
        let cursor = ByteCursor(Data([1, 2, 3]))

        do {
            _ = try cursor.slice(offset: 2, length: 2)
            XCTFail("A slice extending past the source must fail")
        } catch let error as ProtocolDecodeError {
            XCTAssertEqual(error.offset, 2)
            XCTAssertEqual(error.reason, "truncated input: expected 2 byte(s), only 1 remaining")
        } catch {
            XCTFail("Expected ProtocolDecodeError, got \(error)")
        }
    }

    func test_byteCursor_absoluteNegativeOffsetThrowsTypedError() {
        let cursor = ByteCursor(Data([1, 2, 3]))

        do {
            _ = try cursor.slice(offset: -1, length: 1)
            XCTFail("A negative absolute offset must fail")
        } catch let error as ProtocolDecodeError {
            XCTAssertEqual(error.offset, 0)
            XCTAssertEqual(error.reason, "negative byte offset -1")
        } catch {
            XCTFail("Expected ProtocolDecodeError, got \(error)")
        }
    }

    func test_byteCursor_absoluteOffsetPastEndThrowsTypedError() {
        let cursor = ByteCursor(Data([1, 2, 3]))

        do {
            _ = try cursor.slice(offset: 4, length: 0)
            XCTFail("An absolute offset past the source must fail")
        } catch let error as ProtocolDecodeError {
            XCTAssertEqual(error.offset, 4)
            XCTAssertEqual(error.reason, "byte offset 4 is past the end of 3-byte input")
        } catch {
            XCTFail("Expected ProtocolDecodeError, got \(error)")
        }
    }

    func test_byteCursor_zeroLengthSliceAtEndSucceeds() throws {
        var cursor = ByteCursor(Data([1, 2, 3]))
        XCTAssertEqual(try cursor.readSlice(length: 3), Data([1, 2, 3]))
        XCTAssertEqual(try cursor.slice(offset: 3, length: 0), Data())
        XCTAssertEqual(cursor.position, 3)
        XCTAssertEqual(cursor.remaining, 0)
    }

    func test_byteCursor_failedSkipPreservesPosition() throws {
        var cursor = ByteCursor(Data([1, 2, 3]))
        _ = try cursor.readByte()

        do {
            try cursor.skip(3)
            XCTFail("A skip past the remaining bytes must fail")
        } catch let error as ProtocolDecodeError {
            XCTAssertEqual(error.offset, 1)
            XCTAssertEqual(error.reason, "truncated input: expected 3 byte(s), only 2 remaining")
            XCTAssertEqual(cursor.position, 1)
        } catch {
            XCTFail("Expected ProtocolDecodeError, got \(error)")
        }
    }

    func test_byteCursor_negativeLengthThrowsTypedError() {
        var cursor = ByteCursor(Data([1, 2, 3]))

        do {
            _ = try cursor.readSlice(length: -1)
            XCTFail("Negative lengths must be rejected")
        } catch let error as ProtocolDecodeError {
            XCTAssertEqual(error.offset, 0)
            XCTAssertEqual(error.reason, "negative byte length -1")
        } catch {
            XCTFail("Expected ProtocolDecodeError, got \(error)")
        }
    }

    func test_lengthArithmetic_overflowThrows() {
        do {
            _ = try ProtocolLengthArithmetic.checkedAdd(UInt.max, 1, offset: 17)
            XCTFail("UInt addition overflow must be rejected")
        } catch let error as ProtocolDecodeError {
            XCTAssertEqual(error.offset, 17)
            XCTAssertTrue(error.reason.contains("overflow"), error.reason)
            XCTAssertTrue(error.reason.contains("adding"), error.reason)
        } catch {
            XCTFail("Expected ProtocolDecodeError, got \(error)")
        }

        do {
            _ = try ProtocolLengthArithmetic.checkedMultiply(Int.max, 2, offset: 23)
            XCTFail("Int multiplication overflow must be rejected")
        } catch let error as ProtocolDecodeError {
            XCTAssertEqual(error.offset, 23)
            XCTAssertTrue(error.reason.contains("overflow"), error.reason)
            XCTAssertTrue(error.reason.contains("multiplying"), error.reason)
        } catch {
            XCTFail("Expected ProtocolDecodeError, got \(error)")
        }

        do {
            _ = try ProtocolLengthArithmetic.checkedAdd(Int.min, -1, offset: 29)
            XCTFail("Signed negative addition overflow must be rejected")
        } catch let error as ProtocolDecodeError {
            XCTAssertEqual(error.offset, 29)
            XCTAssertEqual(error.reason, "integer overflow while adding \(Int.min) and -1")
        } catch {
            XCTFail("Expected ProtocolDecodeError, got \(error)")
        }
    }

    func test_byteCursor_unalignedReadSucceeds() throws {
        var cursor = ByteCursor(Data([0xAA, 0x78, 0x56, 0x34, 0x12]))

        XCTAssertEqual(try cursor.readByte(), 0xAA)
        XCTAssertEqual(try cursor.readUInt32LE(), 0x1234_5678)
        XCTAssertEqual(cursor.remaining, 0)
    }

    func test_byteCursor_trailingPaddingIgnored() throws {
        var cursor = ByteCursor(Data([0x34, 0x12, 0x00, 0x00, 0xA5, 0x5A]))

        XCTAssertEqual(try cursor.readUInt16LE(), 0x1234)
        XCTAssertEqual(cursor.remaining, 4)
        XCTAssertEqual(try cursor.readByte(), 0x00)
        XCTAssertEqual(cursor.remaining, 3)
        // A structurally complete read does not make extra bytes an error.
        XCTAssertEqual(try cursor.readSlice(length: 3), Data([0x00, 0xA5, 0x5A]))
        XCTAssertTrue(cursor.isAtEnd)
    }

    private static func multiFieldFixture() -> Data {
        let floatBits = Float(-3.25).bitPattern
        var data = Data()
        data.append(contentsOf: [0xCD, 0xAB])
        data.append(contentsOf: [0x11, 0x22, 0x33, 0x44])
        data.append(contentsOf: withUnsafeBytes(of: Int16(-9).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: Int32(123_456).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: floatBits.littleEndian, Array.init))
        return data
    }
}

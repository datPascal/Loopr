import FoodKit
import Foundation
import ImageIO
import Testing
@testable import Loopr

@MainActor struct FoodPhotoPrivacyTests {
    @Test func providerJPEGRemovesGPSAndCaptureTimeWithoutChangingLocalPhoto() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = try FoodCaptureFixtures.photo(at: date)
        let source = try #require(CGImageSourceCreateWithData(fixture.bytes as CFData, nil))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, source, 0, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2023:11:14 20:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLongitude: 0.0],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private photo owner"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let local = try FoodPhoto(type: .jpeg, capturedAt: date, bytes: bytes as Data)
        let outgoing = try FoodProviderImage.jpeg(local)
        let sanitized = try #require(CGImageSourceCreateWithData(outgoing as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(sanitized, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        // ImageIO writes fresh pixel dimensions and colour-space information.
        // Only those generated fields may survive in the outgoing EXIF block.
        #expect(Set(exif.keys).isSubset(of: [kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension]))
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) <= 1_568)
        #expect((properties[kCGImagePropertyPixelHeight] as? Int ?? 0) <= 1_568)
        #expect(local.reference.capturedAt == date && local.bytes == bytes as Data)
    }
}

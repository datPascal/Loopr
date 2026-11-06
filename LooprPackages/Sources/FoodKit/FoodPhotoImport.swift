import Foundation
import ImageIO

public struct FoodPhotoTime: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case camera, libraryAsset, exif, assumedZone, user }
    public let source: Source
    public let originalLocalTime: String?
    public let originalOffset: String?
    public let assumedTimeZone: String?
    public init(source: Source, originalLocalTime: String?, originalOffset: String?, assumedTimeZone: String?) {
        self.source = source; self.originalLocalTime = originalLocalTime; self.originalOffset = originalOffset; self.assumedTimeZone = assumedTimeZone
    }
    public var needsReview: Bool { source == .assumedZone || source == .user }
    public var explanation: String {
        switch source {
        case .camera: "Time from the camera."
        case .libraryAsset: "Time from your photo library."
        case .exif: "Time from the photo."
        case .assumedZone: "The photo has no time zone. Check the meal time."
        case .user: "The photo has no capture time. Choose the meal time."
        }
    }
}

public struct FoodImportedPhoto: Equatable, Sendable {
    public let photo: FoodPhoto
    public let time: FoodPhotoTime
}

public enum FoodPhotoImport {
    public static func read(_ bytes: Data, assetDate: Date? = nil, assumedZone: TimeZone, now: Date) throws -> FoodImportedPhoto {
        guard bytes.count <= FoodPhoto.maximumBytes,
              let image = CGImageSourceCreateWithData(bytes as CFData, nil),
              let identifier = CGImageSourceGetType(image) as String?,
              let type = ["public.jpeg": FoodPhotoType.jpeg, "public.png": .png, "public.heic": .heic][identifier],
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else { throw FoodError.invalidPhoto }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let local = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let fraction = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
        let selected = time(assetDate: assetDate, local: local, offset: offset, fraction: fraction, assumedZone: assumedZone, now: now)
        return .init(photo: try .init(type: type, capturedAt: selected.0, bytes: bytes), time: selected.1)
    }
    public static func time(assetDate: Date?, local: String?, offset: String?, fraction: String? = nil,
                            assumedZone: TimeZone, now: Date) -> (Date, FoodPhotoTime) {
        if let assetDate, assetDate.timeIntervalSince1970.isFinite {
            return (assetDate, .init(source: .libraryAsset, originalLocalTime: local, originalOffset: offset, assumedTimeZone: nil))
        }
        let zone = offset.flatMap(offsetZone)
        if let local {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = zone ?? assumedZone
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"; formatter.isLenient = false
            if let value = formatter.date(from: local), formatter.string(from: value) == local {
                var subsecond: Double = 0
                if let fraction, !fraction.isEmpty, fraction.utf8.allSatisfy({ (48...57).contains($0) }) {
                    subsecond = Double("0." + fraction.prefix(9)) ?? 0
                }
                return (value.addingTimeInterval(subsecond), .init(source: zone == nil ? .assumedZone : .exif,
                    originalLocalTime: local, originalOffset: offset, assumedTimeZone: zone == nil ? assumedZone.identifier : nil))
            }
        }
        return (now, .init(source: .user, originalLocalTime: local, originalOffset: offset, assumedTimeZone: assumedZone.identifier))
    }
    private static func offsetZone(_ text: String) -> TimeZone? {
        let parts = Array(text.utf8)
        guard parts.count == 6, [43, 45].contains(parts[0]), parts[3] == 58,
              [parts[1], parts[2], parts[4], parts[5]].allSatisfy({ (48...57).contains($0) }),
              let hours = Int(text.dropFirst().prefix(2)), let minutes = Int(text.suffix(2)),
              hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
        return TimeZone(secondsFromGMT: (hours * 3_600 + minutes * 60) * (parts[0] == 45 ? -1 : 1))
    }
}

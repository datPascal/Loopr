import CoreImage
import CoreImage.CIFilterBuiltins
import FoodKit
import ImageIO
import UIKit
import Vision

/// A barcode the camera read, lifted out of the frame it was in.
nonisolated struct FoodLensBarcodeHit: @unchecked Sendable {
    let code: String
    /// The code, straightened and cropped from the frame.
    let crop: UIImage
    /// Where the code sat in the frame, as fractions of the frame's width and height from its top left.
    let region: CGRect
    /// The whole frame, scaled down, for the blurred backdrop.
    let frame: UIImage
}

/// What the camera made of one photo: the plate cut out like a sticker, or the photo itself for a label.
nonisolated struct FoodLensCutout: @unchecked Sendable {
    let image: UIImage
    /// Where the cut-out sat in the photo, as fractions from its top left.
    let region: CGRect
    let backdrop: UIImage
}

nonisolated enum FoodLensPhotoRead: @unchecked Sendable {
    case barcode(FoodLensBarcodeHit)
    case cutout(FoodLensCutout)
}

/// A lab report page lifted out of a photo for Lab mode: the page Vision found, squared up like the barcode crop,
/// or the whole photo when no page stands out. Text is read from `page`, so a line's box lands on this image.
nonisolated struct FoodLensReport: @unchecked Sendable {
    let page: CGImage
    /// Where the page sat in the photo, as fractions from its top left.
    let region: CGRect
    let backdrop: UIImage
    var image: UIImage { UIImage(cgImage: page) }
    var aspect: CGFloat { CGFloat(page.width) / CGFloat(max(page.height, 1)) }
}

/// Image work for the food camera. Everything here is synchronous and slow enough to stay off the main actor.
nonisolated enum FoodLensArt {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let symbologies: [VNBarcodeSymbology] = [.ean8, .ean13, .upce, .itf14, .code128]

    // MARK: Day dial stickers

    /// A meal photo for Today's dial: the centre square, cut round, `pixels` across. The dial draws the white rim.
    /// Nil when the bytes are not an image.
    static func dialSticker(_ data: Data, pixels: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels * 2]
        guard pixels > 0, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = CGFloat(thumbnail.width), height = CGFloat(thumbnail.height)
        let side = min(width, height)
        guard side > 0, let square = thumbnail.cropping(to: CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)) else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: pixels, height: pixels)).addClip()
            UIImage(cgImage: square).draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
    }

    /// A meal photo for the card a tapped dial sticker opens: upright, uncropped, `longestSide` pixels at most.
    static func dialPhoto(_ data: Data, longestSide: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longestSide]
        guard longestSide > 0, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    // MARK: Barcodes

    static func barcodes(in handler: VNImageRequestHandler) -> [VNBarcodeObservation] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = symbologies
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).filter { code(of: $0) != nil }
    }

    /// The code as Open Food Facts files it. UPC-E expands to twelve digits. Codes with letters are not food.
    static func code(of observation: VNBarcodeObservation) -> String? {
        guard let raw = observation.payloadStringValue else { return nil }
        if observation.symbology == .upce { return try? FoodBarcode.expandedUPCE(raw) }
        return (try? FoodBarcode.normalized(raw)) == nil ? nil : raw
    }

    /// Straightens the code out of `image`, which must be upright. Vision reports thin boxes for
    /// one-dimensional codes, so the crop is grown to a label's proportions with a quiet margin.
    static func hit(_ observation: VNBarcodeObservation, in image: CIImage) -> FoodLensBarcodeHit? {
        guard let code = code(of: observation) else { return nil }
        let image = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        let size = image.extent.size
        func point(_ value: CGPoint) -> CGPoint { .init(x: value.x * size.width, y: value.y * size.height) }
        let tl = point(observation.topLeft), tr = point(observation.topRight)
        let bl = point(observation.bottomLeft), br = point(observation.bottomRight)
        let center = CGPoint(x: (tl.x + tr.x + bl.x + br.x) / 4, y: (tl.y + tr.y + bl.y + br.y) / 4)
        var across = CGVector(dx: (tr.x - tl.x + br.x - bl.x) / 2, dy: (tr.y - tl.y + br.y - bl.y) / 2)
        var up = CGVector(dx: (tl.x - bl.x + tr.x - br.x) / 2, dy: (tl.y - bl.y + tr.y - br.y) / 2)
        let width = hypot(across.dx, across.dy)
        guard width > 8 else { return nil }
        let height = hypot(up.dx, up.dy)
        if height < width * 0.42 {
            // Perpendicular to the bars, pointing up in Core Image's lower-left space.
            let normal = CGVector(dx: -across.dy / width, dy: across.dx / width)
            up = CGVector(dx: normal.dx * width * 0.42, dy: normal.dy * width * 0.42)
        }
        across = CGVector(dx: across.dx * 1.14, dy: across.dy * 1.14)
        up = CGVector(dx: up.dx * 1.22, dy: up.dy * 1.22)
        func corner(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            .init(x: center.x + across.dx * x / 2 + up.dx * y / 2, y: center.y + across.dy * x / 2 + up.dy * y / 2)
        }
        let corners = [corner(-1, 1), corner(1, 1), corner(-1, -1), corner(1, -1)]
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image.clampedToExtent()
        filter.topLeft = corners[0]; filter.topRight = corners[1]; filter.bottomLeft = corners[2]; filter.bottomRight = corners[3]
        guard let output = filter.outputImage, output.extent.width.isFinite, output.extent.width > 0,
              let crop = context.createCGImage(output, from: output.extent.integral),
              let frame = scaled(image, longestSide: 900) else { return nil }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let box = CGRect(x: xs.min()! / size.width, y: 1 - ys.max()! / size.height,
                         width: (xs.max()! - xs.min()!) / size.width, height: (ys.max()! - ys.min()!) / size.height)
        return .init(code: code, crop: UIImage(cgImage: crop), region: box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)),
                     frame: UIImage(cgImage: frame))
    }

    // MARK: Photos

    /// Reads a taken or chosen photo. A barcode wins over food; a label keeps the photo as it is.
    static func read(photo data: Data, label: Bool) -> FoodLensPhotoRead? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600
              ] as CFDictionary) else { return nil }
        let handler = VNImageRequestHandler(cgImage: image)
        let upright = CIImage(cgImage: image)
        if !label, let observation = barcodes(in: handler).first, let hit = hit(observation, in: upright) { return .barcode(hit) }
        guard let backdrop = scaled(upright, longestSide: 900) else { return nil }
        if label { return labelCard(image, backdrop: backdrop).map(FoodLensPhotoRead.cutout) }
        if let sticker = sticker(upright, handler: handler, backdrop: backdrop) { return .cutout(sticker) }
        return roundSticker(image, backdrop: backdrop).map(FoodLensPhotoRead.cutout)
    }

    /// The eating-window rail's sticker for a saved meal photo: the same lifted subject with its white edge as the
    /// camera made, or the round crop when no subject stands out. It reads a small copy, since the rail draws 56 pt.
    static func railSticker(photo data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480
              ] as CFDictionary) else { return nil }
        let upright = CIImage(cgImage: image)
        guard let backdrop = scaled(upright, longestSide: 64) else { return nil }
        let handler = VNImageRequestHandler(cgImage: image)
        return (sticker(upright, handler: handler, backdrop: backdrop) ?? roundSticker(image, backdrop: backdrop))?.image
    }

    /// Vision's subject lifting, the same cut-out Photos makes, with a white edge grown around it.
    private static func sticker(_ image: CIImage, handler: VNImageRequestHandler, backdrop: CGImage) -> FoodLensCutout? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
              let masked = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false),
              let mask = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler),
              let bounds = maskBounds(mask) else { return nil }
        let size = image.extent.size
        // A sliver of a subject is a misread, not a meal.
        guard bounds.width * bounds.height >= size.width * size.height * 0.04 else { return nil }
        let cut = CIImage(cvPixelBuffer: masked)
            .cropped(to: CGRect(x: bounds.minX, y: size.height - bounds.maxY, width: bounds.width, height: bounds.height))
        guard let outlined = outlined(cut) else { return nil }
        return .init(image: outlined, region: CGRect(x: bounds.minX / size.width, y: bounds.minY / size.height,
                                                     width: bounds.width / size.width, height: bounds.height / size.height),
                     backdrop: UIImage(cgImage: backdrop))
    }

    /// The opaque part of a Vision mask, in pixels from the top left.
    private static func maskBounds(_ buffer: CVPixelBuffer) -> CGRect? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in stride(from: 0, to: height, by: 2) {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
            for x in stride(from: 0, to: width, by: 2) where line[x] > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 2, height: maxY - minY + 2)
    }

    /// Grows a white silhouette under the cut-out, so it reads as a sticker on any backdrop.
    private static func outlined(_ cut: CIImage) -> UIImage? {
        let longest = max(cut.extent.width, cut.extent.height)
        let scale = min(1, 900 / longest)
        let subject = cut.transformed(by: .init(scaleX: scale, y: scale))
        let edge = max(subject.extent.width, subject.extent.height) * 0.03
        let canvas = subject.extent.insetBy(dx: -edge * 1.6, dy: -edge * 1.6).integral
        let placed = subject.composited(over: CIImage(color: .clear).cropped(to: canvas))
        let white = placed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
        ])
        let grown = white.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": edge]).cropped(to: canvas)
        let sticker = placed.composited(over: grown)
        guard let image = context.createCGImage(sticker, from: canvas) else { return nil }
        return UIImage(cgImage: image)
    }

    /// When no subject stands out (or the simulator has no Neural Engine), the plate becomes a round sticker.
    private static func roundSticker(_ image: CGImage, backdrop: CGImage) -> FoodLensCutout? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let side = min(width, height) * 0.84
        let crop = CGRect(x: (width - side) / 2, y: height * 0.47 - side / 2, width: side, height: side).integral
        guard let part = image.cropping(to: crop) else { return nil }
        let edge = side * 0.035
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let size = CGSize(width: side + edge * 2, height: side + edge * 2)
        let sticker = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            UIBezierPath(ovalIn: CGRect(x: edge, y: edge, width: side, height: side)).addClip()
            UIImage(cgImage: part).draw(in: CGRect(x: edge, y: edge, width: side, height: side))
        }
        return .init(image: sticker, region: CGRect(x: crop.minX / width, y: crop.minY / height, width: side / width, height: side / height),
                     backdrop: UIImage(cgImage: backdrop))
    }

    /// A label stays a photo, framed like a card, because its words are the point.
    private static func labelCard(_ image: CGImage, backdrop: CGImage) -> FoodLensCutout? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let cardWidth = width * 0.86, cardHeight = min(height * 0.8, cardWidth * 1.25)
        let crop = CGRect(x: (width - cardWidth) / 2, y: (height - cardHeight) / 2, width: cardWidth, height: cardHeight).integral
        guard let part = image.cropping(to: crop) else { return nil }
        let edge = cardWidth * 0.03
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let size = CGSize(width: crop.width + edge * 2, height: crop.height + edge * 2)
        let card = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill(); UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: edge * 3).fill()
            UIBezierPath(roundedRect: CGRect(x: edge, y: edge, width: crop.width, height: crop.height), cornerRadius: edge * 2).addClip()
            UIImage(cgImage: part).draw(in: CGRect(x: edge, y: edge, width: crop.width, height: crop.height))
        }
        return .init(image: card, region: CGRect(x: crop.minX / width, y: crop.minY / height, width: crop.width / width, height: crop.height / height),
                     backdrop: UIImage(cgImage: backdrop))
    }

    // MARK: Lab reports

    /// Reads a photo of a lab report for Lab mode. With `straighten`, Vision looks for the page and it is cut out
    /// and squared up; when no page stands out, as on the simulator, the whole photo is the page.
    static func report(photo data: Data, straighten: Bool = true) -> FoodLensReport? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_400
              ] as CFDictionary) else { return nil }
        let upright = CIImage(cgImage: image)
        guard let backdrop = scaled(upright, longestSide: 900) else { return nil }
        if straighten, let found = page(in: image, upright: upright) {
            return .init(page: found.image, region: found.region, backdrop: UIImage(cgImage: backdrop))
        }
        return .init(page: image, region: CGRect(x: 0, y: 0, width: 1, height: 1), backdrop: UIImage(cgImage: backdrop))
    }

    /// The document Vision sees in the photo, straightened. A small or uncertain find is not a page.
    private static func page(in image: CGImage, upright: CIImage) -> (image: CGImage, region: CGRect)? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let found = request.results?.first, found.confidence >= 0.6,
              found.boundingBox.width * found.boundingBox.height >= 0.2 else { return nil }
        let size = upright.extent.size
        func point(_ value: CGPoint) -> CGPoint { .init(x: value.x * size.width, y: value.y * size.height) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = upright
        filter.topLeft = point(found.topLeft); filter.topRight = point(found.topRight)
        filter.bottomLeft = point(found.bottomLeft); filter.bottomRight = point(found.bottomRight)
        guard let output = filter.outputImage, output.extent.width.isFinite, output.extent.width > 0,
              let straight = context.createCGImage(output, from: output.extent.integral) else { return nil }
        let box = found.boundingBox
        return (straight, CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
    }

    private static func scaled(_ image: CIImage, longestSide: CGFloat) -> CGImage? {
        let scale = min(1, longestSide / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: .init(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent.integral)
    }

    private static func scaled(_ image: CGImage, longestSide: CGFloat) -> CGImage? {
        scaled(CIImage(cgImage: image), longestSide: longestSide)
    }

    // MARK: Barcode card

    /// The code redrawn as a clean printed barcode on a white card, with its digits underneath.
    static func barcodeCard(_ code: String) -> UIImage {
        let size = CGSize(width: 960, height: 460)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 56).fill()
            let bars = CGRect(x: 92, y: 60, width: size.width - 184, height: 270)
            let ink = UIColor(red: 0.07, green: 0.06, blue: 0.05, alpha: 1)
            ink.setFill()
            if let modules = ean(code) {
                let module = bars.width / CGFloat(modules.count)
                for (index, entry) in modules.enumerated() where entry.bar {
                    context.fill(CGRect(x: bars.minX + CGFloat(index) * module, y: bars.minY, width: module + 0.4,
                                        height: bars.height + (entry.guard ? 30 : 0)))
                }
            } else if let image = code128(code) {
                context.cgContext.interpolationQuality = .none
                UIImage(cgImage: image).draw(in: bars)
            }
            let font = UIFont(name: "SpaceGrotesk-Medium", size: 58) ?? .monospacedDigitSystemFont(ofSize: 58, weight: .medium)
            let text = NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: ink, .kern: 9])
            let bounds = text.boundingRect(with: size, options: [], context: nil)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: bars.maxY + 36))
        }
    }

    /// EAN-13, UPC-A and EAN-8 as 95 or 67 modules. Guard bars run longer, as printed.
    private static func ean(_ code: String) -> [(bar: Bool, guard: Bool)]? {
        var digits = code.compactMap(\.wholeNumberValue)
        guard digits.count == code.count else { return nil }
        if digits.count == 12 { digits.insert(0, at: 0) }
        let left = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
        let even = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
        let right = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]
        let parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
        var modules: [(Bool, Bool)] = []
        func add(_ pattern: String, guard isGuard: Bool) { modules += pattern.map { ($0 == "1", isGuard) } }
        switch digits.count {
        case 13:
            let pattern = Array(parity[digits[0]])
            add("101", guard: true)
            for index in 1...6 { add(pattern[index - 1] == "L" ? left[digits[index]] : even[digits[index]], guard: false) }
            add("01010", guard: true)
            for index in 7...12 { add(right[digits[index]], guard: false) }
            add("101", guard: true)
        case 8:
            add("101", guard: true)
            for index in 0...3 { add(left[digits[index]], guard: false) }
            add("01010", guard: true)
            for index in 4...7 { add(right[digits[index]], guard: false) }
            add("101", guard: true)
        default: return nil
        }
        return modules.map { (bar: $0.0, guard: $0.1) }
    }

    private static func code128(_ code: String) -> CGImage? {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(code.utf8); filter.quietSpace = 0
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}

#if DEBUG
import AnalyticsKit
import CoreGraphics
import FoodKit
import Foundation
import ImageIO
import StorageKit
import UIKit

/// Authored plate illustration for seeded capture and meal-photo fixtures.
/// It never runs in a production composition.
nonisolated enum FoodCaptureFixtures {
    static func photo(at date: Date) throws -> FoodPhoto {
        let width = 804, height = 1000
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FoodError.invalidPhoto }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.setFillColor(color(0x090807)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color(0x3b2d20), color(0x21180f), color(0x090807)] as CFArray, locations: [0, 0.35, 0.75]) {
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: 402, y: 450), startRadius: 0,
                endCenter: CGPoint(x: 402, y: 450), endRadius: 681, options: .drawsAfterEndLocation)
        }
        context.saveGState()
        context.addEllipse(in: CGRect(x: 142, y: 200, width: 520, height: 520)); context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color(0xece6da), color(0xd3ccbe), color(0xa29a8d)] as CFArray, locations: [0, 0.55, 0.70]) {
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: 360.4, y: 408), startRadius: 0,
                endCenter: CGPoint(x: 360.4, y: 408), endRadius: 434, options: .drawsAfterEndLocation)
        }
        context.restoreGState()
        rounded(context, rect: CGRect(x: 236, y: 300, width: 208, height: 144), radius: 0.4, hex: 0xc58a4c, rotation: -12)
        rounded(context, rect: CGRect(x: 360, y: 424, width: 224, height: 160), radius: 0.45, hex: 0xf1ebde)
        rounded(context, rect: CGRect(x: 220, y: 472, width: 128, height: 112), radius: 0.4, hex: 0x6f9a3e)
        guard let image = context.makeImage() else { throw FoodError.invalidPhoto }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else { throw FoodError.invalidPhoto }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FoodError.invalidPhoto }
        return try FoodPhoto(type: .jpeg, capturedAt: date, bytes: bytes as Data)
    }
    private static func rounded(_ context: CGContext, rect: CGRect, radius: CGFloat, hex: UInt32, rotation: CGFloat = 0) {
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY); context.rotate(by: rotation * .pi / 180)
        let centered = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        context.addPath(CGPath(roundedRect: centered, cornerWidth: rect.width * radius, cornerHeight: rect.height * radius, transform: nil))
        context.setFillColor(color(hex)); context.fillPath(); context.restoreGState()
    }
    private static func color(_ hex: UInt32) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// Lab mode on the simulator, which has no report to point at. `--loopr-food-lab-fixture` reads a fixed English
/// report, `--loopr-food-lab-fixture=de` a German one and `--loopr-food-lab-fixture=empty` a page with no results,
/// instead of the camera and Vision. Each report has one value read at low confidence, so it needs a look.
///
/// Every row is synthetic, written in the shape of the LV-08a.4 parser fixtures; it is nobody's report. It never runs
/// in a production composition.
nonisolated enum FoodLabFixture {
    enum Report: String, Sendable { case english = "en", german = "de", empty }

    static let argument = "--loopr-food-lab-fixture"
    /// The confidence of the uncertain row, under the parser's 0.6 threshold.
    static let uncertainConfidence = 0.41

    static func requested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Report? {
        for argument in arguments {
            if argument == Self.argument { return .english }
            if argument.hasPrefix(Self.argument + "=") {
                return Report(rawValue: String(argument.dropFirst(Self.argument.count + 1))) ?? .english
            }
        }
        return nil
    }

    /// Reads the fixture's lines instead of Vision. The page is the rendered report, as it is.
    static func reader(_ report: Report) -> FoodLabReader {
        FoodLabReader(
            lift: { data in FoodLensArt.report(photo: data, straighten: false) },
            recognize: { _ in lines(report) })
    }

    /// The report's text as Vision would give it: one line per cell, origin at the bottom left.
    static func lines(_ report: Report) -> [LabTextLine] {
        let uncertain = report == .german ? "CRP (hochsensitiv)" : "hs-CRP"
        return rows(report).enumerated().flatMap { index, cells -> [LabTextLine] in
            let y = 0.965 - Double(index) * 0.0245
            let confidence = cells.first?.0 == uncertain ? uncertainConfidence : 0.98
            return cells.map { cell in
                LabTextLine(text: cell.0, minX: cell.1, minY: y, width: Double(cell.0.count) * 0.0095, height: 0.015,
                            confidence: confidence)
            }
        }
    }

    /// The report drawn on paper, so the camera screen has a page to lift.
    static func photo(_ report: Report, at date: Date) throws -> FoodPhoto {
        let size = CGSize(width: 1_000, height: 1_400)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let ink = UIColor(red: 0.165, green: 0.145, blue: 0.125, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.984, green: 0.972, blue: 0.949, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in lines(report).enumerated() {
                let height = line.height * size.height
                let font = index == 0 ? UIFont.systemFont(ofSize: height * 1.05, weight: .semibold)
                    : UIFont.monospacedSystemFont(ofSize: height * 0.86, weight: .regular)
                let origin = CGPoint(x: line.minX * size.width, y: (1 - line.minY - line.height) * size.height - height * 0.1)
                NSString(string: line.text).draw(at: origin, withAttributes: [.font: font, .foregroundColor: ink])
            }
        }
        guard let bytes = image.jpegData(compressionQuality: 0.9) else { throw FoodError.invalidPhoto }
        return try FoodPhoto(type: .jpeg, capturedAt: date, bytes: bytes)
    }

    /// Lab mode's store in fixture launches, which have no production database: one temporary file per launch.
    static func database() throws -> StorageDatabase { try store.get() }

    private static let store: Result<StorageDatabase, any Error> = Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LooprLabFixture-\(UUID().uuidString)")
        return try StorageDatabase(url: root.appendingPathComponent("labs.sqlite"), applicationVersion: "lab-fixture")
    }

    private typealias Cell = (String, Double)

    private static func rows(_ report: Report) -> [[Cell]] {
        switch report {
        case .english: english
        case .german: german
        case .empty:
            [[("Sample Diagnostics Laboratory", 0.05)], [("Page 2 of 2", 0.05)], [("Notes", 0.05)],
             [("Please discuss these results with your doctor", 0.05)]]
        }
    }

    /// Name, value, optional flag, unit and the lab's range, at the columns of a typical report.
    private static func result(_ name: String, _ value: String, _ unit: String, _ range: String, flag: String? = nil) -> [Cell] {
        [(name, 0.05), (value, 0.36)] + (flag.map { [($0, 0.46)] } ?? []) + [(unit, 0.53), (range, 0.7)]
    }

    private static let english: [[Cell]] = [
        [("Sample Diagnostics Laboratory", 0.05)],
        [("Page 1 of 2", 0.05)],
        [("Collected:", 0.05), ("November 13, 2023 08:15", 0.2)],
        [("Received:", 0.05), ("2023-11-14", 0.2)],
        [("Birth date:", 0.05), ("03/04/1985", 0.2)],
        [("Fasting: yes", 0.05)],
        [("Test", 0.05), ("Result", 0.36), ("Flag", 0.46), ("Units", 0.53), ("Reference Interval", 0.7)],
        result("Albumin", "4.6", "g/dL", "3.5 - 5.2"),
        result("Creatinine", "0.82", "mg/dL", "0.60 - 1.20"),
        result("Glucose, fasting", "88", "mg/dL", "70 - 99"),
        result("hs-CRP", "0.6", "mg/L", "< 3.0"),
        result("Lymphocytes %", "31", "%", "20 - 40"),
        result("MCV", "89.4", "fL", "80.0 - 100.0"),
        result("RDW", "12.9", "%", "11.5 - 14.5"),
        result("Alkaline Phosphatase", "64", "U/L", "40 - 129"),
        result("White Blood Cell Count", "5.9", "x10E3/uL", "3.4 - 10.8"),
        result("Apolipoprotein B", "112", "mg/dL", "< 90", flag: "H"),
        result("Hemoglobin A1c", "5.2", "%", "4.0 - 5.6"),
        result("LDL Cholesterol", "92", "mg/dL", "< 100"),
        result("HDL Cholesterol", "58", "mg/dL", "> 40"),
        result("Triglycerides", "71", "mg/dL", "< 150"),
        result("Cholesterol, Total", "190", "mg/dL", "100 - 199"),
        result("Lipoprotein (a)", "38", "nmol/L", "< 75"),
        result("Insulin", "5.1", "uIU/mL", "2.6 - 24.9"),
        result("Ferritin", "412", "ng/mL", "30 - 400", flag: "*"),
        result("Vitamin D, 25-Hydroxy", "41.0", "ng/mL", "30.0 - 100.0"),
        result("TSH", "1.90", "uIU/mL", "0.45 - 4.50"),
        result("ALT", "22", "U/L", "0 - 44"),
        result("AST", "24", "U/L", "0 - 40"),
        result("GGT", "17", "U/L", "0 - 65"),
        result("eGFR", "108", "mL/min/1.73 m2", "> 60"),
        result("Uric Acid", "5.0", "mg/dL", "3.8 - 8.4"),
        result("Hemoglobin", "14.6", "g/dL", "13.0 - 17.7"),
        result("Platelets", "231", "x10E3/uL", "150 - 450"),
        result("Homocysteine", "9.2", "umol/L", "0.0 - 14.5"),
        result("Vitamin B12, Active", "88", "pmol/L", "40 - 120")
    ]

    private static let german: [[Cell]] = [
        [("Laborbefund", 0.05)],
        [("MVZ Labor Beispielstadt", 0.05)],
        [("Geburtsdatum:", 0.05), ("03.04.1985", 0.22)],
        [("Probenentnahme:", 0.05), ("13.11.2023 08:15", 0.22)],
        [("Eingangsdatum:", 0.05), ("13.11.2023", 0.22)],
        [("Befunddatum:", 0.05), ("14.11.2023", 0.22)],
        [("Probe: nüchtern abgenommen", 0.05)],
        [("Untersuchung", 0.05), ("Ergebnis", 0.36), ("Flag", 0.46), ("Einheit", 0.53), ("Referenzbereich", 0.7)],
        result("Kreatinin", "0,82", "mg/dl", "0,60-1,20"),
        result("Glukose nüchtern", "88", "mg/dl", "(70 - 99)"),
        result("Albumin", "46,2", "g/l", "Ref.: 35 bis 52"),
        result("CRP (hochsensitiv)", "0,6", "mg/l", "< 3,0"),
        result("Lymphozyten %", "31,0", "%", "20 - 40"),
        result("MCV", "89,4", "fl", "80,0 - 100,0"),
        result("RDW", "12,9", "%", "11,5 - 14,5"),
        result("Alkalische Phosphatase", "64", "U/l", "40 - 129"),
        result("Leukozyten", "5,9", "/nl", "3,4 - 10,8"),
        result("HbA1c (IFCC)", "33", "mmol/mol", "20 - 38"),
        result("Apolipoprotein B", "1,12", "g/l", "< 0,90", flag: "H"),
        result("Lipoprotein(a)", "38", "nmol/l", "< 75"),
        result("LDL-Cholesterin", "92", "mg/dl", "< 100"),
        result("HDL-Cholesterin", "58", "mg/dl", "> 40"),
        result("Triglyzeride", "71", "mg/dl", "< 150"),
        result("Cholesterin gesamt", "190", "mg/dl", "< 200"),
        result("Ferritin", "96", "µg/l", "30 - 400"),
        result("25-OH-Vitamin D", "41,0", "ng/ml", "30,0 - 100,0"),
        result("TSH", "1,90", "mIU/l", "0,45 - 4,50"),
        result("GOT (AST)", "24", "U/l", "< 40"),
        result("GPT (ALT)", "22", "U/l", "< 45"),
        result("Gamma-GT", "17", "U/l", "< 66"),
        result("eGFR (CKD-EPI)", "108", "ml/min/1,73m²", "> 60"),
        result("Harnsäure", "5,0", "mg/dl", "3,4 - 7,0"),
        result("Hämoglobin", "14,6", "g/dl", "13,5 - 17,5"),
        result("Thrombozyten", "231", "Tsd./µl", "150 - 450"),
        result("Homocystein", "9,2", "µmol/l", "< 12,0"),
        result("Insulin", "5,1", "µU/ml", "2,6 - 24,9"),
        result("Mikroalbumin", "8", "mg/l", "negativ")
    ]
}
#endif

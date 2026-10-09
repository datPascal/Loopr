import Foundation
import ProfileKit

/// The profile step's editable state, kept free of SwiftUI so validation,
/// unit conversion and the derived max heart rate are unit-testable.
///
/// Every field is text as typed. A blank field becomes an absent value in
/// the draft, never a zero or a guess.
public struct OnboardingProfileForm: Equatable, Sendable {
    public enum SexChoice: String, CaseIterable, Sendable {
        case female
        case male
        case intersex
        case undisclosed

        public var title: String {
            switch self {
            case .female: "Female"
            case .male: "Male"
            case .intersex: "Intersex"
            case .undisclosed: "Prefer not to say"
            }
        }

        public var biologicalSex: BiologicalSex {
            switch self {
            case .female: .female
            case .male: .male
            case .intersex: .intersex
            case .undisclosed: .undisclosed
            }
        }

        init(_ value: BiologicalSex) {
            switch value {
            case .female: self = .female
            case .male: self = .male
            case .intersex: self = .intersex
            case .undisclosed: self = .undisclosed
            }
        }
    }

    public enum Issue: Equatable, Sendable {
        case age
        case height
        case weight

        public var message: String {
            switch self {
            case .age:
                "Enter an age from \(ProfileEstimates.supportedAges.lowerBound) to \(ProfileEstimates.supportedAges.upperBound), or leave it blank."
            case .height: "That height looks off. Check the number and the units, or leave it blank."
            case .weight: "That weight looks off. Check the number and the units, or leave it blank."
            }
        }
    }

    public var name: String = ""
    public var age: String = ""
    public var sex: SexChoice?
    public var unitSystem: UnitSystem = .metric
    /// Centimetres when metric; whole feet when imperial.
    public var heightPrimary: String = ""
    /// Inches when imperial; unused when metric.
    public var heightInches: String = ""
    public var weight: String = ""

    public init() {}

    /// Rebuilds the form from a previously saved draft, for Back and for a
    /// relaunch in the middle of onboarding.
    public init(draft: ProfileDraft, currentYear: Int) {
        name = draft.displayName ?? ""
        if let birthYear = draft.birthYear {
            age = String(ProfileEstimates.age(birthYear: birthYear, currentYear: currentYear))
        }
        sex = draft.biologicalSex.map(SexChoice.init)
        unitSystem = draft.unitSystem ?? .metric
        if let centimetres = draft.heightCentimeters {
            switch unitSystem {
            case .metric:
                heightPrimary = String(Int(centimetres.rounded()))
            case .imperial:
                let totalInches = Int((centimetres / 2.54).rounded())
                heightPrimary = String(totalInches / 12)
                heightInches = String(totalInches % 12)
            }
        }
        if let kilograms = draft.weightKilograms {
            let value = unitSystem == .metric ? kilograms : UnitConverter.kilogramsToPounds(kilograms)
            weight = Self.format(value)
        }
    }

    // MARK: Parsed values

    public var ageValue: Int? {
        Int(age.trimmingCharacters(in: .whitespaces))
    }

    public var heightCentimeters: Double? {
        switch unitSystem {
        case .metric:
            return Self.number(heightPrimary)
        case .imperial:
            let feet = Self.number(heightPrimary)
            let inches = Self.number(heightInches)
            guard feet != nil || inches != nil else { return nil }
            return UnitConverter.inchesToCentimeters((feet ?? 0) * 12 + (inches ?? 0))
        }
    }

    public var weightKilograms: Double? {
        guard let value = Self.number(weight) else { return nil }
        return unitSystem == .metric ? value : UnitConverter.poundsToKilograms(value)
    }

    /// The Tanaka estimate for the typed age, or nil when the age is blank
    /// or outside the supported range.
    public var estimatedMaxHeartRate: Int? {
        ageValue.flatMap(ProfileEstimates.estimatedMaxHeartRate(age:))
    }

    // MARK: Validation

    /// Problems with what was typed. Blank fields are never a problem.
    public var issues: [Issue] {
        var result: [Issue] = []
        if !age.trimmingCharacters(in: .whitespaces).isEmpty {
            if let value = ageValue, ProfileEstimates.supportedAges.contains(value) {} else { result.append(.age) }
        }
        let heightTyped = !heightPrimary.trimmingCharacters(in: .whitespaces).isEmpty
            || !heightInches.trimmingCharacters(in: .whitespaces).isEmpty
        if heightTyped {
            let inchesValid = unitSystem == .metric || heightInches.trimmingCharacters(in: .whitespaces).isEmpty
                || Self.number(heightInches).map { (0 ..< 12).contains($0) } == true
            if let centimetres = heightCentimeters, Self.heightRange.contains(centimetres), inchesValid {} else {
                result.append(.height)
            }
        }
        if !weight.trimmingCharacters(in: .whitespaces).isEmpty {
            if let kilograms = weightKilograms, Self.weightRange.contains(kilograms) {} else { result.append(.weight) }
        }
        return result
    }

    public var canSubmit: Bool { issues.isEmpty }

    /// The draft saved to ProfileKit. Time zone comes from the device, so
    /// nobody types an identifier.
    public func draft(currentYear: Int, timeZone: TimeZone = .current) -> ProfileDraft {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProfileDraft(
            displayName: trimmedName.isEmpty ? nil : trimmedName,
            birthYear: ageValue.flatMap {
                ProfileEstimates.supportedAges.contains($0)
                    ? ProfileEstimates.birthYear(age: $0, currentYear: currentYear)
                    : nil
            },
            biologicalSex: sex?.biologicalSex,
            heightCentimeters: heightCentimeters,
            weightKilograms: weightKilograms,
            timezoneIdentifier: timeZone.identifier,
            unitSystem: unitSystem
        )
    }

    /// Switching units converts what was typed, so a person who types 180
    /// and then taps Imperial sees 5 ft 11 in rather than an error.
    public mutating func switchUnits(to system: UnitSystem) {
        guard system != unitSystem else { return }
        let centimetres = heightCentimeters
        let kilograms = weightKilograms
        unitSystem = system
        heightPrimary = ""
        heightInches = ""
        if let centimetres {
            switch system {
            case .metric:
                heightPrimary = String(Int(centimetres.rounded()))
            case .imperial:
                let totalInches = Int((centimetres / 2.54).rounded())
                heightPrimary = String(totalInches / 12)
                heightInches = String(totalInches % 12)
            }
        }
        if let kilograms {
            weight = Self.format(system == .metric ? kilograms : UnitConverter.kilogramsToPounds(kilograms))
        }
    }

    // Mirrors ProfileValidator so the form flags a value before Save does.
    static let heightRange: ClosedRange<Double> = 80 ... 250
    static let weightRange: ClosedRange<Double> = 20 ... 400

    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    private static func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded() == rounded ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

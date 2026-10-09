import Foundation

/// Values derived from profile fields, shared by onboarding and any screen
/// that previews what a profile field changes. Nothing here is persisted:
/// the profile stores the birth year, never the age or the estimate.
public enum ProfileEstimates {
    /// The ages `ProfileValidator` accepts, expressed as years rather than as a
    /// birth-year window.
    public static let supportedAges: ClosedRange<Int> = 13 ... 120

    public static func currentYear(for date: Date = Date()) -> Int {
        Calendar(identifier: .gregorian).component(.year, from: date)
    }

    /// Age in whole years from a stored birth year. The profile keeps only
    /// the year, so this can be one year high before the birthday.
    public static func age(birthYear: Int, currentYear: Int) -> Int {
        currentYear - birthYear
    }

    public static func birthYear(age: Int, currentYear: Int) -> Int {
        currentYear - age
    }

    /// Age-predicted maximum heart rate, Tanaka, Monahan and Seals (2001):
    /// 208 minus 0.7 times age. AnalyticsKit's `ActivityAnalytics.estimateHRmax`
    /// uses the same prior and replaces it with the observed peak when that is
    /// higher, so this preview matches what the strain model starts from.
    /// Returns nil outside the supported ages rather than extrapolating.
    public static func estimatedMaxHeartRate(age: Int) -> Int? {
        guard supportedAges.contains(age) else { return nil }
        return Int((208 - 0.7 * Double(age)).rounded())
    }
}

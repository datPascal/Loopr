import Foundation

/// The not-a-medical-device line (DEC-12, App Store guideline 1.4.1). Every screen that shows a lab value, a blood
/// age, a Cardio Age or a method page draws this text, alone or as the start of a longer sentence. One constant, so
/// no screen words it its own way.
public enum LooprMedicalLine {
    public static let text = "Loopr is not a medical device."
}

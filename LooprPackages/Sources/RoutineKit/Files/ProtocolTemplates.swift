import Foundation

/// The five protocols that ship with Loopr, as protocol files in the RoutineKit bundle (`Templates/`). They go through the
/// same validator as a file from anyone else, so a template that stops validating fails a test. The repo's `protocols/`
/// folder holds the same files byte for byte.
///
/// Every target is a conservative default and the person can change any of it. No template names a person or a brand.
/// Where a default has published evidence, it is cited here; where none exists the default is a modest habit, and the
/// comment says so. Every rule carries a `why` and an `evidence` (ICP R2-NEW-07, R2-DES-02, R2-VET-05). The why is one
/// plain sentence of at most 16 words that the app never cuts short, and it never names the rule's number, so it stays
/// true when the person changes the target. The evidence is the source in a sentence or three, the study or guideline
/// named in words, shown as "Where this comes from".
///
/// A gentle start, for a person new to all of this (ICP R1-SEN-14): three rules, one the band checks, one Apple Health
/// checks and one the person ticks, so the first evening asks one question.
/// - In bed by 22:30, as in Sleep first.
/// - Walk 6,000 steps. The low end of the 6,000 to 8,000 steps a day at which mortality risk levelled off at age 60 and
///   over (Paluch et al., Lancet Public Health 2022;7(3):e219-e228). Under 60 it levelled off at 8,000 to 10,000, and
///   the evidence says so, so a younger person sees the figure that fits them (ICP R3-NEW-05). An iPhone counts steps
///   without a watch.
/// - One drink at most, as in Everything at once, but ticked rather than read from Food, so it works without logging.
///
/// Sleep first
/// - In bed by 22:30. No study fixes a bedtime. 22:30 leaves 7 to 9 hours before a 06:30 to 07:30 wake time, the range
///   the AASM and Sleep Research Society consensus recommends for adults (Watson et al., Sleep 2015;38(6):843-844).
/// - Kitchen closes at 19:00, 3.5 hours before bed. Common guidance and observational evidence only. No trial sets the gap.
/// - No caffeine after 14:00. 400 mg of caffeine 6 hours before bed cut sleep by more than an hour (Drake et al., J Clin
///   Sleep Med 2013;9(11):1195-1200). 14:00 is 8.5 hours before 22:30.
/// - 30 minutes in daylight. No guideline sets a figure. A modest default.
/// - Screens off an hour before bed, track your sleeping heart rate. Habits without a published target.
///
/// Fitness for the long run
/// - Zone 2, 150 minutes a week. WHO guidelines on physical activity: 150 to 300 minutes of moderate activity a week
///   (Bull et al., Br J Sports Med 2020;54(24):1451-1462). The low end is the default.
/// - Two strength sessions a week. The same WHO guidelines: muscle-strengthening activity on 2 or more days a week.
/// - 30 hard minutes a week (zones 4 and 5). WHO counts 75 to 150 minutes of vigorous activity a week as equal to the
///   moderate range. 30 minutes is a start below that.
/// - Two mobility sessions a week. ACSM position stand: flexibility exercise on 2 or more days a week (Garber et al.,
///   Med Sci Sports Exerc 2011;43(7):1334-1359).
/// - Grip strength retest, monthly. Grip strength predicts death from all causes (Leong et al., Lancet 2015;386:266-273).
/// - One-leg balance retest, monthly. Failing a 10-second one-leg stand predicts higher mortality in people 51 to 75
///   (Araujo et al., Br J Sports Med 2022;56:975-980).
///
/// Everything at once
/// - The sleep rules above, the fitness rules for zone 2 and strength, and:
/// - Protein, 80 grams. About 1.0 to 1.2 g per kg for a person near 70 kg, the range proposed for older adults (Bauer et al.,
///   PROT-AGE, J Am Med Dir Assoc 2013;14(8):542-559). The RDA is 0.8 g per kg. Body weight varies, so edit it.
/// - Fibre, 25 grams. The EFSA adequate intake for adults (EFSA Journal 2010;8(3):1462).
/// - One drink at most. Alcohol before bed fragments sleep in the second half of the night (Ebrahim et al., Alcohol
///   Clin Exp Res 2013;37(4):539-549), so the why speaks of sleep, kindly (ICP R2-NEW-07). The US Dietary Guidelines
///   for 2020 to 2025 cap drinking at 1 a day for women and 2 for men. WHO says no level of alcohol is without risk
///   (2023). 1 is the lower of the two caps.
/// - 7,000 steps. Mortality risk fell until about 6,000 to 8,000 steps a day at age 60 and over, and 8,000 to 10,000 below
///   that (Paluch et al., Lancet Public Health 2022;7(3):e219-e228).
/// - Take your supplements. A tick for the stack the person sets up in Food. No dose or product is named.
/// - Blood test every 6 months. A common interval. Ask your clinician what suits you.
///
/// Start empty has no rules.
public enum ProtocolTemplate: String, CaseIterable, Sendable {
    case gentleStart = "gentle-start"
    case sleepFirst = "sleep-first"
    case fitnessForTheLongRun = "fitness-for-the-long-run"
    case everythingAtOnce = "everything-at-once"
    case startEmpty = "start-empty"

    /// The template a newcomer is pointed at first: the gentlest one.
    public static let recommended = ProtocolTemplate.gentleStart

    public var title: String {
        switch self {
        case .gentleStart: "A gentle start"
        case .sleepFirst: "Sleep first"
        case .fitnessForTheLongRun: "Fitness for the long run"
        case .everythingAtOnce: "Everything at once"
        case .startEmpty: "Start empty"
        }
    }

    /// The template's file in the RoutineKit bundle.
    public var fileName: String { "\(rawValue).\(ProtocolFile.fileExtension)" }

    public func data() throws -> Data {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: ProtocolFile.fileExtension, subdirectory: "Templates") else {
            throw ProtocolTemplateError.missingResource(fileName)
        }
        return try Data(contentsOf: url)
    }

    /// The template through the validator, ready for `RoutineStore.importFile`.
    public func load() throws -> ProtocolImportPreview { try ProtocolFileCodec.validate(try data()) }
}

public enum ProtocolTemplateError: Error, Equatable, LocalizedError, Sendable {
    case missingResource(String)
    public var errorDescription: String? { "A template that ships with Loopr could not be found." }
}

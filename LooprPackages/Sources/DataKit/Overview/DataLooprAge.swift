import Foundation

// LV-08b step 1: Loopr Age stays locked (DEC-02.12). The tile is text only and never carries a number; its type has
// no numeric field to put one in. Tapping it opens a page that says, for a person, what Loopr Age would be and why it is
// locked. It opens with no network request. ICP R2-LAB-15: the page used to show the engineering plan and point at a
// source file; the stage list stays here, tied to docs/LOOPR_AGE.md by a test, but the page shows only `step`.

public enum DataLooprAgeTile {
    public static let identifier = "data-loopr-age-locked"
    public static let title = "Loopr Age"
    public static let line = "Not shown until it is tested on people it was not built from."
    public static let spokenLabel = "Loopr Age, locked. \(line)"
    public static let hint = "Says what it would be and why it is locked."
}

public struct DataLooprAgePlanStage: Equatable, Sendable, Identifiable {
    /// "A" to "D", as in the plan. Only the accessibility identifier uses it.
    public let letter: String
    /// The stage's heading in docs/LOOPR_AGE.md, in sentence case. Not shown.
    public let title: String
    /// The stage in a person's words, as the page shows it.
    public let step: String

    public var id: String { letter }
}

/// The page behind the locked tile. The stages follow the Build Plan section of docs/LOOPR_AGE.md; a test keeps their
/// titles in step with the document's headings.
public enum DataLooprAgePlan {
    public static let identifier = "data-loopr-age-plan"
    public static let sourcePath = "docs/LOOPR_AGE.md"

    public static let intro = """
        Loopr Age would be one age built from your cardio fitness, resting heart rate, movement, training, sleep and \
        body composition.
        """

    public static let whyLocked = """
        Loopr will not show it until it has been tested on people it was not built from. Until then there is no Loopr \
        Age anywhere in the app.
        """

    public static let stagesHeader = "Before it appears"

    public static let stages: [DataLooprAgePlanStage] = [
        DataLooprAgePlanStage(letter: "A", title: "Data foundation and Cardio Age",
            step: "Loopr reads each input with its source, starting with Cardio Age."),
        DataLooprAgePlanStage(letter: "B", title: "Internal composite research",
            step: "The team decides what the age should predict before it looks at any test results."),
        DataLooprAgePlanStage(letter: "C", title: "Validation and age conversion",
            step: "The model is tested on people it never saw, then reviewed by outside experts."),
        DataLooprAgePlanStage(letter: "D", title: "Product launch",
            step: "It ships with a page that shows how it works. A new version never rewrites your old values.")
    ]

    public static let otherAges = """
        Cardio Age and blood age are separate numbers, each with its own method. Each one shows on the ruler once you \
        have the data it needs.
        """
}

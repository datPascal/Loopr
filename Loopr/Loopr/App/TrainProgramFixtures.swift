#if DEBUG
import Foundation
import TrainKit

/// The agent draft behind `--loopr-train-draft-fixture`. It goes through the same `ProgramDraftDecoder` FT-05 will use,
/// so the fixture proves the decoder and the store path together. Alex, Australia/Perth.
nonisolated extension AppTrainFixtures {
    static let draftName = "Spring base"

    /// Monday 20 November, the first Monday after the fixture day.
    static let draftStartDay = "2023-11-20"

    /// What an agent would send for "Build a base with three runs and two lifts a week for four weeks."
    static var draftJSON: String {
        func slots(light: Bool) -> String {
            let kind = light ? "light" : "normal"
            return """
            [{"weekday":"monday","template":"Lower A","kind":"\(kind)","tag":"LA"},
             {"weekday":"wednesday","template":"Zone 2"},
             {"weekday":"thursday","template":"Easy ride"},
             {"weekday":"saturday","template":"Upper B","kind":"\(kind)","tag":"UB"}]
            """
        }
        let weeks = (1...4).map { slots(light: $0 == 4) }.joined(separator: ",")
        return """
        {"schemaVersion":1,"name":"\(draftName)","request":"Build a base with three runs and two lifts a week for four weeks.",
         "startDay":"\(draftStartDay)","weeks":[\(weeks)],
         "newTemplates":[{"name":"Easy ride","kind":"cardio","cardio":{"activity":"cycle","minutes":40,"zone":2}}],
         "rules":{"earlyLightWeek":true,"missed":"skip"}}
        """
    }

    /// Decodes the draft against the saved templates and stores it with status `.draft`.
    static func seedDraft(_ store: TrainStore, at date: Date) throws {
        let decoder = ProgramDraftDecoder(templates: try store.templates(), library: nil, defaultStartDay: draftStartDay)
        _ = try store.saveProgram(try decoder.decode(draftJSON), at: date)
    }
}
#endif

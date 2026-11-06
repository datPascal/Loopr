import DesignSystem
import SwiftUI
import Testing

@MainActor struct TrainSharedControlsTests {
    private static let themes: [ColorScheme] = [.light, .dark]
    private static let minimum = LooprSpacing.interactiveRowHeight

    // MARK: Week strip and weekday picker

    private var weekDays: [LooprWeekStripDay] {
        [
            LooprWeekStripDay(identifier: "d-13", weekdayLetter: "M", dateNumeral: "13", caption: "Done", isDone: true,
                              accessibilityLabel: "Monday 13 November, done"),
            LooprWeekStripDay(identifier: "d-14", weekdayLetter: "T", dateNumeral: "14", caption: "Upper A", isToday: true,
                              accessibilityLabel: "Tuesday 14 November, Upper A, today"),
            LooprWeekStripDay(identifier: "d-15", weekdayLetter: "W", dateNumeral: "15", caption: "Zone 2", accessibilityLabel: "Wednesday 15 November, Zone 2"),
            LooprWeekStripDay(identifier: "d-16", weekdayLetter: "T", dateNumeral: "16", caption: "Lower B", accessibilityLabel: "Thursday 16 November, Lower B"),
            LooprWeekStripDay(identifier: "d-17", weekdayLetter: "F", dateNumeral: "17", caption: "Rest", accessibilityLabel: "Friday 17 November, rest"),
            LooprWeekStripDay(identifier: "d-18", weekdayLetter: "S", dateNumeral: "18", caption: "Upper B", accessibilityLabel: "Saturday 18 November, Upper B"),
            LooprWeekStripDay(identifier: "d-19", weekdayLetter: "S", dateNumeral: "19", caption: "Long run", accessibilityLabel: "Sunday 19 November, long run")
        ]
    }

    @Test func weekStripRendersAtEveryTextSizeAndStaysAtLeastOneTargetTall() throws {
        let strip = LooprWeekStrip(days: weekDays, identifier: "strip") { _ in }
        #expect(LooprWeekStrip.minimumCellHeight == Self.minimum)
        for appearance in Self.themes {
            let regular = try render(strip, appearance: appearance, size: .large, width: 358)
            #expect(regular.width == 358 && CGFloat(regular.height) >= Self.minimum)
            let largest = try render(strip, appearance: appearance, size: .accessibility5)
            // Seven stacked rows of at least 56 pt each, so nothing clips to one line.
            #expect(largest.width == 320 && CGFloat(largest.height) >= Self.minimum * 7)
        }
    }

    @Test func weekStripDaysCarryTheCallersLabelAndIdentifier() {
        let today = weekDays[1]
        #expect(today.id == "d-14" && today.identifier == "d-14")
        #expect(today.accessibilityLabel == "Tuesday 14 November, Upper A, today")
        #expect(weekDays.filter(\.isToday).count == 1)
        #expect(weekDays.filter(\.isDone).count == 1)
        #expect(Set(weekDays.map(\.identifier)).count == 7)
    }

    @Test func weekdaysMapToCalendarNumbersAndKeepMondayFirst() {
        #expect(LooprWeekday.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 6, 7])
        #expect(LooprWeekday.allCases.map(\.initial).joined() == "MTWTFSS")
        #expect(LooprWeekday.monday.calendarWeekday == 2)
        #expect(LooprWeekday.sunday.calendarWeekday == 1)
        for day in LooprWeekday.allCases {
            #expect(LooprWeekday(calendarWeekday: day.calendarWeekday) == day)
        }
        #expect(LooprWeekday(calendarWeekday: 0) == nil)
        #expect(LooprWeekday(calendarWeekday: 8) == nil)
        #expect(LooprWeekday.tuesday.code == "tue")
    }

    @Test func weekdayPickerTogglesOneDayAtATime() {
        var days: Set<LooprWeekday> = [.tuesday]
        days = LooprWeekdayPicker.toggling(.saturday, in: days)
        #expect(days == [.tuesday, .saturday])
        days = LooprWeekdayPicker.toggling(.tuesday, in: days)
        #expect(days == [.saturday])
        days = LooprWeekdayPicker.toggling(.saturday, in: days)
        #expect(days.isEmpty)
    }

    @Test func weekdayPickerSpeaksFullNamesInWeekOrder() {
        #expect(LooprWeekdayPicker.accessibilitySummary(title: "Days", selection: [.saturday, .tuesday]) == "Days, Tuesday, Saturday")
        #expect(LooprWeekdayPicker.accessibilitySummary(title: "Days", selection: []) == "Days, none selected")
    }

    @Test func weekdayPickerKeepsFiftySixPointTargetsAtEverySize() throws {
        #expect(LooprWeekdayPicker.minimumTargetHeight == Self.minimum)
        for appearance in Self.themes {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let image = try render(LooprWeekdayPicker(selection: .constant([.tuesday, .saturday]), identifier: "days"),
                                       appearance: appearance, size: size)
                #expect(image.width == 320 && CGFloat(image.height) >= Self.minimum)
            }
        }
    }

    // MARK: Exercise row

    private func member(_ id: String, rest: String?) -> LooprExerciseRow.Member {
        .init(id: id, name: "Exercise \(id)", spec: "3 × 10 · 28 KG", rest: rest, identifier: "ex-\(id)", accessibilityLabel: "Exercise \(id)")
    }

    @Test func specLineJoinsRestWithTheMonoSeparator() {
        #expect(LooprExerciseRow.specLine(spec: "4 × 6–8 · 80 KG", rest: "2:30") == "4 × 6–8 · 80 KG · Rest 2:30")
        #expect(LooprExerciseRow.specLine(spec: "4 × 6 · +10 KG", rest: nil) == "4 × 6 · +10 KG")
        #expect(LooprExerciseRow.specLine(spec: "3 × 12", rest: "") == "3 × 12")
    }

    @Test func supersetShowsRestOnTheLastMemberOnly() {
        let members = [member("a", rest: "1:30"), member("b", rest: "1:30"), member("c", rest: "2:00")]
        #expect(LooprExerciseRow.visibleRest(of: members, at: 0) == nil)
        #expect(LooprExerciseRow.visibleRest(of: members, at: 1) == nil)
        #expect(LooprExerciseRow.visibleRest(of: members, at: 2) == "2:00")
        #expect(LooprExerciseRow.visibleRest(of: [member("solo", rest: "2:30")], at: 0) == "2:30")
        #expect(LooprExerciseRow.visibleRest(of: members, at: 3) == nil)
    }

    @Test func exerciseRowsKeepTheirHeightAndWrapAtLargestText() throws {
        let long = "Dumbbell Romanian deadlift with a long pause at the bottom"
        for appearance in Self.themes {
            let single = LooprExerciseRow(name: long, spec: "4 × 6–8 · 80 KG", rest: "2:30", identifier: "single",
                                          accessibilityLabel: long, onMoveUp: {}, onMoveDown: {}) {}
            let group = LooprExerciseRow(members: [member("a", rest: "1:30"), member("b", rest: "1:30")],
                                         identifier: "group", onSelect: { _ in }, onMoveUp: {}, onMoveDown: {})
            let regular = try render(single, appearance: appearance, size: .large)
            let largest = try render(single, appearance: appearance, size: .accessibility5)
            #expect(CGFloat(regular.height) >= LooprExerciseRow.minimumRowHeight)
            #expect(largest.height > regular.height)
            let groupRegular = try render(group, appearance: appearance, size: .large)
            let groupLargest = try render(group, appearance: appearance, size: .accessibility5)
            #expect(CGFloat(groupRegular.height) >= LooprExerciseRow.minimumRowHeight * 2)
            #expect(groupLargest.height > groupRegular.height)
        }
    }

    // MARK: Value stepper

    @Test func stepperClampsToItsRange() {
        let range = 0.0...500.0
        #expect(LooprValueStepper.clamped(-3, in: range) == 0)
        #expect(LooprValueStepper.clamped(512.5, in: range) == 500)
        #expect(LooprValueStepper.stepped(0, direction: -1, step: 2.5, range: range) == 0)
        #expect(LooprValueStepper.stepped(500, direction: 1, step: 2.5, range: range) == 500)
        #expect(LooprValueStepper.stepped(499, direction: 1, step: 2.5, range: range) == 500)
        #expect(LooprValueStepper.stepped(1, direction: -1, step: 2.5, range: range) == 0)
    }

    @Test func stepperAddsStepsWithoutBinaryNoise() {
        let range = 0.0...500.0
        var value = 80.0
        for _ in 0..<3 { value = LooprValueStepper.stepped(value, direction: 1, step: 2.5, range: range) }
        #expect(value == 87.5)
        var tenth = 0.0
        for _ in 0..<3 { tenth = LooprValueStepper.stepped(tenth, direction: 1, step: 0.1, range: range) }
        #expect(tenth == 0.3)
        #expect(LooprValueStepper.stepped(8, direction: -1, step: 1, range: 0...100) == 7)
    }

    @Test func stepperSpeaksTheValueWithItsUnit() {
        let locale = Locale(identifier: "en_US")
        #expect(LooprValueStepper.valueText(80, locale: locale) == "80")
        #expect(LooprValueStepper.valueText(82.5, locale: locale) == "82.5")
        #expect(LooprValueStepper.spokenValue(82.5, spokenUnit: "kilograms", locale: locale) == "82.5 kilograms")
        #expect(LooprValueStepper.spokenValue(8, spokenUnit: "reps", locale: locale) == "8 reps")
    }

    @Test func stepperKeepsFiftySixPointTargetsAtEverySize() throws {
        #expect(LooprValueStepper.minimumTargetHeight == Self.minimum)
        for appearance in Self.themes {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let stepper = LooprValueStepper("kg", label: "Weight", spokenUnit: "kilograms", value: .constant(80), step: 2.5,
                    range: 0...500, identifier: "kg", decrementIdentifier: "kg-minus", incrementIdentifier: "kg-plus")
                let image = try render(stepper, appearance: appearance, size: size, width: size == .large ? 173 : 320)
                #expect(CGFloat(image.height) >= Self.minimum)
            }
        }
    }

    // MARK: Set log table

    private var setRows: [LooprSetLogRow] {
        [
            .init(number: 1, weight: "80", reps: "8", rpe: "7", status: .logged),
            .init(number: 2, weight: "80", reps: "8", rpe: nil, status: .logged),
            .init(number: 3, weight: "80", reps: "8", status: .current),
            .init(number: 4, weight: "80", reps: "8", status: .planned)
        ]
    }

    @Test func setRowsSpeakTheirStateAndRPE() {
        let rows = setRows
        #expect(LooprSetLogTable.spokenSummary(rows[0]) == "Set 1, 80 kilograms, 8 reps, RPE 7, logged")
        #expect(LooprSetLogTable.spokenSummary(rows[1]) == "Set 2, 80 kilograms, 8 reps, logged")
        #expect(LooprSetLogTable.spokenSummary(rows[2]) == "Set 3, 80 kilograms, 8 reps, current set")
        #expect(LooprSetLogTable.spokenSummary(rows[3]) == "Set 4, 80 kilograms, 8 reps, planned")
        #expect(LooprSetLogTable.rpeAccessibilityLabel(rows[0]) == "RPE for set 1, 7")
        #expect(LooprSetLogTable.rpeAccessibilityLabel(rows[1]) == "Add RPE for set 2")
        #expect(rows.map(\.id) == [1, 2, 3, 4])
    }

    @Test func setLogTableFitsAtEverySizeWithFiftySixPointRows() throws {
        #expect(LooprSetLogTable.minimumRowHeight == Self.minimum)
        let table = LooprSetLogTable(rows: setRows, rowIdentifierPrefix: "row", rpeIdentifierPrefix: "rpe") { _ in }
        for appearance in Self.themes {
            let regular = try render(table, appearance: appearance, size: .large)
            #expect(CGFloat(regular.height) >= Self.minimum * 4)
            let largest = try render(table, appearance: appearance, size: .accessibility5)
            #expect(largest.height > regular.height)
        }
    }

    // MARK: Rest timer

    @Test func restCountdownIsDeterministicForAFixedNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(LooprRestTimerCard.remainingSeconds(endDate: now.addingTimeInterval(105), now: now) == 105)
        #expect(LooprRestTimerCard.remainingSeconds(endDate: now.addingTimeInterval(104.2), now: now) == 105)
        #expect(LooprRestTimerCard.remainingSeconds(endDate: now, now: now) == 0)
        #expect(LooprRestTimerCard.remainingSeconds(endDate: now.addingTimeInterval(-30), now: now) == 0)
        #expect(LooprRestTimerCard.countdownText(seconds: 105) == "1:45")
        #expect(LooprRestTimerCard.countdownText(seconds: 150) == "2:30")
        #expect(LooprRestTimerCard.countdownText(seconds: 9) == "0:09")
        #expect(LooprRestTimerCard.countdownText(seconds: 0) == "0:00")
        #expect(LooprRestTimerCard.countdownText(seconds: -4) == "0:00")
        #expect(LooprRestTimerCard.countdownText(seconds: 600) == "10:00")
    }

    @Test func restCountdownIsSpokenInWholeUnits() {
        #expect(LooprRestTimerCard.spokenCountdown(seconds: 105) == "1 minute 45 seconds")
        #expect(LooprRestTimerCard.spokenCountdown(seconds: 120) == "2 minutes")
        #expect(LooprRestTimerCard.spokenCountdown(seconds: 1) == "1 second")
        #expect(LooprRestTimerCard.spokenCountdown(seconds: 0) == "0 seconds")
    }

    @Test func restRingDrainsFromFullToEmptyAndNeverLeavesZeroToOne() {
        #expect(LooprRestTimerCard.remainingFraction(remainingSeconds: 150, totalSeconds: 150) == 1)
        #expect(LooprRestTimerCard.remainingFraction(remainingSeconds: 75, totalSeconds: 150) == 0.5)
        #expect(LooprRestTimerCard.remainingFraction(remainingSeconds: 0, totalSeconds: 150) == 0)
        #expect(LooprRestTimerCard.remainingFraction(remainingSeconds: 200, totalSeconds: 150) == 1)
        #expect(LooprRestTimerCard.remainingFraction(remainingSeconds: 10, totalSeconds: 0) == 0)
        #expect(LooprRestTimerCard.ringDiameter == 52)
    }

    @Test func restTimerCardRendersWithAFiftySixPointAddButton() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(LooprRestTimerCard.minimumTargetHeight == Self.minimum)
        for appearance in Self.themes {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let card = LooprRestTimerCard(endDate: now.addingTimeInterval(105), now: now, totalSeconds: 150,
                    caption: "Rest · the band buzzes at zero", identifier: "rest", addIdentifier: "rest-add") {}
                let image = try render(card, appearance: appearance, size: size)
                #expect(image.width == 320 && CGFloat(image.height) >= Self.minimum)
            }
        }
    }

    // MARK: Skipped and editable set rows

    private var rowsWithASkippedSet: [LooprSetLogRow] {
        [
            .init(number: 1, weight: "80", reps: "8", rpe: "7", status: .logged),
            .init(number: 2, weight: "–", reps: "–", status: .skipped),
            .init(number: 3, weight: "80", reps: "8", status: .current),
            .init(number: 4, weight: "80", reps: "8", status: .planned)
        ]
    }

    @Test func aSkippedSetIsSpokenAsSkippedAndNotAsAPlannedSetWithADash() {
        let skipped = rowsWithASkippedSet[1]
        #expect(LooprSetLogTable.spokenSummary(skipped) == "Set 2, skipped")
        #expect(!LooprSetLogTable.spokenSummary(skipped).contains("planned"))
        #expect(LooprSetLogTable.spokenSummary(skipped, spokenWeightUnit: "") == "Set 2, skipped")
        #expect(skipped.status != LooprSetLogStatus.planned)
    }

    @Test func onlyLoggedAndSkippedRowsCanBeEditedAndTheHintSaysWhatTheTapDoes() {
        let rows = rowsWithASkippedSet
        #expect(rows.map(LooprSetLogTable.isEditable) == [true, true, false, false])
        #expect(LooprSetLogTable.editHint(rows[0]) == "Edit this set")
        #expect(LooprSetLogTable.editHint(rows[1]) == "Log this set")
    }

    @Test func editableTablesRenderWithASkippedRowAtEverySize() throws {
        let table = LooprSetLogTable(rows: rowsWithASkippedSet, rowIdentifierPrefix: "row", rpeIdentifierPrefix: "rpe",
                                     onSelectRPE: { _ in }, onEdit: { _ in })
        for appearance in Self.themes {
            let regular = try render(table, appearance: appearance, size: .large)
            #expect(regular.width == 320 && CGFloat(regular.height) >= Self.minimum * 4)
            let largest = try render(table, appearance: appearance, size: .accessibility5)
            // Every stacked block is at least one 56 pt target tall, and the skipped one still takes its place.
            #expect(largest.height > regular.height && CGFloat(largest.height) >= Self.minimum * 4)
        }
    }

    @Test func aTableWithoutAnEditorStillRendersEveryStatus() throws {
        let table = LooprSetLogTable(rows: rowsWithASkippedSet, rowIdentifierPrefix: "row", rpeIdentifierPrefix: "rpe")
        for appearance in Self.themes {
            let image = try render(table, appearance: appearance, size: .large)
            #expect(CGFloat(image.height) >= Self.minimum * 4)
        }
    }

    // MARK: Rest timer done control

    @Test func restTimerCardGrowsByTheDoneControlAndStaysAtFiftySixPoints() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for appearance in Self.themes {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let plain = LooprRestTimerCard(endDate: now.addingTimeInterval(105), now: now, totalSeconds: 150,
                    caption: "Rest · the band buzzes at zero", identifier: "rest", addIdentifier: "rest-add") {}
                let withDone = LooprRestTimerCard(endDate: now.addingTimeInterval(105), now: now, totalSeconds: 150,
                    caption: "Rest · the band buzzes at zero", identifier: "rest", addIdentifier: "rest-add",
                    doneIdentifier: "rest-done", onAdd: {}, onDone: {})
                let without = try render(plain, appearance: appearance, size: size)
                let with = try render(withDone, appearance: appearance, size: size)
                #expect(with.width == 320)
                // One more full-height button, plus the gap above it.
                #expect(CGFloat(with.height - without.height) >= Self.minimum)
            }
        }
    }

    @Test func restTimerKeepsItsOriginalCallShape() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // The trailing closure is still the add action, so the earlier call sites compile unchanged.
        _ = LooprRestTimerCard(endDate: now, now: now, totalSeconds: 60, caption: "Rest",
                               identifier: "rest", addIdentifier: "rest-add") {}
    }

    // MARK: Status chip accent

    @Test func movementAccentKeepsTheMovementToken() {
        #expect(StatusChip.accentToken(for: .movement) == .movement)
        #expect(LooprColorToken.movement.spectralChipLabel == .brandChip)
    }

    @Test func otherChipAccentsAndTonesStillMapAsBefore() {
        #expect(StatusChip.accentToken(for: nil, tone: .neutral) == .inkSecondary)
        #expect(StatusChip.accentToken(for: nil, tone: .positive) == .brand)
        #expect(StatusChip.accentToken(for: nil, tone: .warning) == .strain)
        #expect(StatusChip.accentToken(for: nil, tone: .critical) == .heart)
        #expect(StatusChip.accentToken(for: .sleepChip) == .sleep)
        #expect(StatusChip.accentToken(for: .heartSoft) == .heart)
        #expect(StatusChip.accentToken(for: .warning) == .strain)
        #expect(StatusChip.accentToken(for: .recoveryMid) == .recoveryMid)
        #expect(StatusChip.accentToken(for: .brand) == .brand)
    }

    @Test func aMovementChipKeepsItsLabelAndANonColourCue() throws {
        let chip = StatusChip("Today · 18:00", symbol: nil, accent: .movement)
        #expect(chip.accessibilitySummary == "Today · 18:00" && chip.hasNonColorDifferentiator)
        for appearance in Self.themes {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let image = try render(chip, appearance: appearance, size: size, width: 360)
                #expect(image.width == 360 && image.height > 0)
            }
        }
    }

    // MARK: Program grid

    @Test func cellKindsMapToTokens() {
        #expect(LooprProgramCellKind.normal.fillToken == .ink)
        #expect(LooprProgramCellKind.heavy.fillToken == .strain)
        #expect(LooprProgramCellKind.light.fillToken == .sleep)
        #expect(LooprProgramCellKind.cardio.fillToken == .movement)
        #expect(LooprProgramCellKind.empty.fillToken == nil)
        #expect(LooprProgramCellKind.normal.fillOpacity > 0 && LooprProgramCellKind.normal.fillOpacity < 0.18)
        #expect(LooprProgramCellKind.empty.fillOpacity == 0)
        for kind in [LooprProgramCellKind.heavy, .light, .cardio] { #expect(kind.fillOpacity > 0 && kind.fillOpacity < 1) }
        #expect(LooprProgramCellKind.heavy.labelToken == LooprColorToken.strain.textInk)
        #expect(LooprProgramCellKind.light.labelToken == LooprColorToken.sleep.textInk)
        #expect(LooprProgramCellKind.cardio.labelToken == LooprColorToken.movement.textInk)
        #expect(LooprProgramCellKind.normal.labelToken == .ink)
        #expect(LooprProgramGrid.legendKinds == [.normal, .heavy, .light, .cardio])
    }

    @Test func gridWeeksAlwaysHoldSevenDays() {
        let short = LooprProgramWeek(label: "W1", cells: [LooprProgramCell(code: "LA")])
        #expect(short.cells.count == 7)
        #expect(short.cells[1] == .empty)
        let long = LooprProgramWeek(label: "W2", cells: Array(repeating: LooprProgramCell(code: "UA"), count: 9))
        #expect(long.cells.count == 7)
    }

    @Test func weekSummariesNameDaysKindsAndToday() {
        let week = LooprProgramWeek(label: "W3", cells: [
            LooprProgramCell(code: "LA", spokenName: "Lower A"),
            LooprProgramCell(code: "UA", spokenName: "Upper A", isCurrent: true),
            LooprProgramCell(code: "Z2", kind: .cardio, spokenName: "Zone 2"),
            LooprProgramCell(code: "LB", kind: .heavy)
        ])
        #expect(LooprProgramGrid.accessibilitySummary(for: week)
            == "Week 3. Monday, Lower A. Tuesday, Upper A, today. Wednesday, Zone 2, cardio. Thursday, LB, heavy")
        #expect(LooprProgramGrid.accessibilitySummary(for: LooprProgramWeek(label: "W9", cells: []))
            == "Week 9. Nothing planned")
        #expect(LooprProgramGrid.accessibilitySummary(for: LooprProgramWeek(label: "W4", cells: [], summary: "Week 4, lighter"))
            == "Week 4, lighter")
    }

    @Test func programGridRendersEightWeeksAtEverySizeInBothThemes() throws {
        let weeks = (1...8).map { number in
            LooprProgramWeek(label: "W\(number)", cells: [
                LooprProgramCell(code: "LA", kind: number == 3 ? .heavy : .normal, isCurrent: number == 3),
                LooprProgramCell(code: "UA", kind: number % 4 == 0 ? .light : .normal),
                LooprProgramCell(code: "Z2", kind: .cardio),
                LooprProgramCell(code: "MAX", kind: .heavy)
            ])
        }
        for appearance in Self.themes {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let image = try render(LooprProgramGrid(weeks: weeks, identifier: "grid"), appearance: appearance, size: size)
                // Eight 40 pt rows plus the header and the legend.
                #expect(image.width == 320 && CGFloat(image.height) >= LooprSpacing.hero * 8)
            }
        }
    }

    // MARK: Ask field

    @Test func askFieldIsFiftySixPointsAndWrapsAtLargestText() throws {
        #expect(LooprAskField.minimumHeight == Self.minimum)
        for appearance in Self.themes {
            let field = LooprAskField("Describe it: \"push day, 50 min\"", accessibilityLabel: "Describe it", identifier: "describe") {}
            let regular = try render(field, appearance: appearance, size: .large)
            #expect(regular.width == 320 && CGFloat(regular.height) >= Self.minimum)
            let largest = try render(field, appearance: appearance, size: .accessibility5)
            #expect(largest.height > regular.height)
        }
    }

    @Test func galleryAndComponentsConstruct() {
        _ = DesignSystemGallery(initialSection: "train")
        _ = LooprExerciseRow(name: "Squat", spec: "5 × 5", identifier: "squat", accessibilityLabel: "Squat") {}
    }

    private func render(_ view: some View, appearance: ColorScheme, size: DynamicTypeSize, width: CGFloat = 320) throws -> CGImage {
        try #require(ImageRenderer(content: view.environment(\.colorScheme, appearance)
            .environment(\.dynamicTypeSize, size).frame(width: width)).cgImage)
    }
}

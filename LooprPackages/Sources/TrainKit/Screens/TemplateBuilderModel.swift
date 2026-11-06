import Foundation

/// What the exercise editor sheet edits: one exercise's numbers plus its superset links.
/// The sheet works on a copy and the builder applies it when the person taps Apply.
public struct ExerciseEditorDraft: Equatable, Sendable {
    public static let setsRange = 1...TrainLimits.maxSets
    public static let repsRange = 1...TrainLimits.maxReps
    public static let loadRange = 0.0...TrainLimits.maxLoadKg
    public static let restRange = 0...TrainLimits.maxRestSeconds
    public static let secondsRange = 1...TrainLimits.maxSetSeconds
    public static let metresRange = 1.0...TrainLimits.maxSetMetres

    /// For bodyweight: no extra load, a load added, or assistance taken off.
    public enum BodyweightLoad: String, CaseIterable, Sendable { case none, added, assisted }

    public var sets: Int
    public var repsMin: Int
    public var repsMax: Int
    /// Kilograms. Zero means no load is set. For bodyweight it is the added load.
    public var loadKg: Double
    /// What a set records.
    public var measure: TrainSetMeasure {
        didSet {
            clampReps()
            // Switching to bodyweight starts with no extra load; the person picks added or assisted.
            if measure != oldValue, measure == .bodyweight { bodyweightLoad = .none }
        }
    }
    /// Kilograms of assistance, for bodyweight with `bodyweightLoad == .assisted`.
    public var assistKg: Double
    public var bodyweightLoad: BodyweightLoad
    /// The hold to aim for, for a time exercise.
    public var targetSeconds: Int
    /// The distance to aim for, for a distance exercise.
    public var targetMetres: Double
    public var restSeconds: Int
    public var note: String
    /// True when another exercise sits above this one in the list.
    public let hasPrevious: Bool
    /// True when another exercise sits below this one in the list.
    public let hasNext: Bool
    public var linkedWithPrevious: Bool
    public var linkedWithNext: Bool
    /// Where the exercise's block sits in the list when the editor opens, counting from zero.
    /// A block is one exercise, or a whole superset.
    public let blockIndex: Int
    public let blockCount: Int
    /// True when the exercise is part of a superset, so moving it moves the whole superset.
    public let isInSuperset: Bool
    /// Blocks to move: negative is up, positive is down. The model applies it on Apply.
    public private(set) var blockShift = 0

    /// - Parameter measure: Wins over `loadKind` when given.
    public init(sets: Int, repsMin: Int, repsMax: Int, loadKg: Double, loadKind: TrainLoadKind = .weight,
                measure: TrainSetMeasure? = nil, assistKg: Double = 0,
                targetSeconds: Int = TemplateExercise.defaultTargetSeconds, targetMetres: Double = TemplateExercise.defaultTargetMetres,
                restSeconds: Int, note: String, hasPrevious: Bool = false, hasNext: Bool = false,
                linkedWithPrevious: Bool = false, linkedWithNext: Bool = false,
                blockIndex: Int = 0, blockCount: Int = 1, isInSuperset: Bool = false) {
        self.sets = sets; self.repsMin = repsMin; self.repsMax = repsMax; self.loadKg = loadKg
        self.measure = measure ?? (loadKind == .bodyweight ? .bodyweight : .weight)
        self.assistKg = assistKg
        self.bodyweightLoad = assistKg > 0 ? .assisted : loadKg > 0 ? .added : .none
        self.targetSeconds = targetSeconds; self.targetMetres = targetMetres
        self.restSeconds = restSeconds; self.note = note; self.hasPrevious = hasPrevious; self.hasNext = hasNext
        self.linkedWithPrevious = linkedWithPrevious; self.linkedWithNext = linkedWithNext
        self.blockIndex = blockIndex; self.blockCount = blockCount; self.isInSuperset = isInSuperset
    }

    /// Weight or bodyweight, for code written before measures.
    public var loadKind: TrainLoadKind {
        get { measure == .bodyweight ? .bodyweight : .weight }
        set { if newValue == .bodyweight { measure = .bodyweight } else if measure == .bodyweight { measure = .weight } }
    }

    /// The rep bounds the measure allows: up to 100 for a lift, 1,000 for bodyweight.
    public var repsLimit: ClosedRange<Int> { 1...measure.maxReps }

    private mutating func clampReps() {
        repsMin = min(max(repsMin, repsLimit.lowerBound), repsLimit.upperBound)
        repsMax = min(max(repsMax, repsMin), repsLimit.upperBound)
    }

    /// The block position after the pending moves, counting from zero.
    public var pendingBlockIndex: Int { blockIndex + blockShift }
    public var canMoveUp: Bool { pendingBlockIndex > 0 }
    public var canMoveDown: Bool { pendingBlockIndex < blockCount - 1 }

    public mutating func moveUp() { if canMoveUp { blockShift -= 1 } }
    public mutating func moveDown() { if canMoveDown { blockShift += 1 } }

    /// Sets the lower rep bound. The upper bound follows when it would fall below.
    public mutating func setRepsMin(_ value: Int) {
        repsMin = min(max(value, repsLimit.lowerBound), repsLimit.upperBound)
        if repsMax < repsMin { repsMax = repsMin }
    }

    /// Sets the upper rep bound. The lower bound follows when it would rise above.
    public mutating func setRepsMax(_ value: Int) {
        repsMax = min(max(value, repsLimit.lowerBound), repsLimit.upperBound)
        if repsMin > repsMax { repsMin = repsMax }
    }
}

/// The editable state of the workout builder. Pure value logic: no storage, no views.
///
/// The model keeps the template as it was loaded (`original`) and the template being edited
/// (`draft`). Every edit goes through a method so superset members always stay adjacent and
/// a superset never has fewer than two members.
public struct TemplateBuilderModel: Equatable, Sendable {
    /// Saves a template and returns it as stored, with its new revision.
    public typealias SaveHandler = @Sendable (WorkoutTemplate) async throws -> WorkoutTemplate

    /// Why the template cannot be saved yet. The messages say what to fix.
    public enum Problem: Error, Equatable, Sendable, LocalizedError {
        case nameMissing
        case noExercises
        case tooManyExercises
        case invalidExercise(String)
        case invalid

        public var errorDescription: String? { message }

        public var message: String {
            switch self {
            case .nameMissing: "Name this workout to save it."
            case .noExercises: "Add at least one exercise to save this workout."
            case .tooManyExercises: "A workout holds up to \(TrainLimits.maxExercisesPerTemplate) exercises. Remove some to save it."
            case .invalidExercise(let name): "Check the sets, reps and load for \(name). One of them is out of range."
            case .invalid: "Check the sets, reps and loads. One of them is out of range."
            }
        }
    }

    /// One unit of reordering: a single exercise, or every member of one superset.
    public struct Block: Equatable, Sendable, Identifiable {
        public let exerciseIDs: [UUID]
        public var id: UUID { exerciseIDs[0] }
        public var isSuperset: Bool { exerciseIDs.count > 1 }
    }

    public static let maxExercises = TrainLimits.maxExercisesPerTemplate
    public static let untitledName = "New workout"

    public private(set) var original: WorkoutTemplate
    public private(set) var draft: WorkoutTemplate

    public init(template: WorkoutTemplate) {
        original = template
        draft = template
    }

    /// A blank strength template that has never been saved.
    public static func blank(id: UUID = UUID()) -> TemplateBuilderModel {
        TemplateBuilderModel(template: WorkoutTemplate(id: id, name: ""))
    }

    // MARK: State

    /// True until the first successful save.
    public var isNew: Bool { original.revision == 0 }

    /// True when the draft differs from what was loaded or last saved.
    public var isDirty: Bool { draft != original }

    public var isStrength: Bool { draft.kind == .strength }

    /// The screen title: the template name, or a placeholder while it is empty.
    public var title: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.untitledName : trimmed
    }

    public var exercises: [TemplateExercise] { draft.exercises }

    public var summary: TemplateSummary { TemplateSummary(template: draft) }

    public func exercise(id: UUID) -> TemplateExercise? { draft.exercises.first { $0.id == id } }

    public func index(of id: UUID) -> Int? { draft.exercises.firstIndex { $0.id == id } }

    // MARK: Fields

    public var name: String {
        get { draft.name }
        set { draft.name = newValue }
    }

    public var weekdays: Set<TrainWeekday> {
        get { Set(draft.weekdays) }
        set { draft.weekdays = newValue.sorted() }
    }

    public var progression: ProgressionRule {
        get { draft.progression }
        set { draft.progression = newValue }
    }

    public var bandRestCue: Bool {
        get { draft.bandRestCue }
        set { draft.bandRestCue = newValue }
    }

    /// The recovery rule as it applies, or the default one when none is stored yet.
    public var recoveryRule: RecoveryRule { draft.recoveryRule ?? RecoveryRule(enabled: false) }

    public var recoveryEnabled: Bool {
        get { draft.recoveryRule?.enabled ?? false }
        set {
            if newValue {
                var rule = draft.recoveryRule ?? RecoveryRule()
                rule.enabled = true
                draft.recoveryRule = rule
            } else if var rule = draft.recoveryRule {
                rule.enabled = false
                draft.recoveryRule = rule
            }
        }
    }

    // MARK: Validation

    /// The first thing blocking a save, or nil when the template can be saved.
    public var problem: Problem? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nameMissing }
        if draft.kind == .strength {
            if draft.exercises.isEmpty { return .noExercises }
            if draft.exercises.count > Self.maxExercises { return .tooManyExercises }
            for line in draft.exercises where (try? line.validate()) == nil { return .invalidExercise(line.exercise.name) }
        }
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? candidate.validate()) == nil ? .invalid : nil
    }

    public var canSave: Bool { problem == nil }

    public var canAddExercise: Bool { isStrength && draft.exercises.count < Self.maxExercises }

    // MARK: Exercises

    /// Appends a library or custom exercise with starting numbers and returns its line id.
    /// The measure comes from the exercise: holds are timed, carries are distances, and exercises that
    /// need no equipment start as bodyweight. See `TrainSetMeasure.defaultMeasure(for:)`.
    @discardableResult
    public mutating func addExercise(_ definition: ExerciseDefinition) -> UUID? {
        guard canAddExercise else { return nil }
        let line = TemplateExercise.starting(definition)
        draft.exercises.append(line)
        return line.id
    }

    /// Removes an exercise. A superset left with one member is dissolved.
    public mutating func removeExercise(id: UUID) {
        draft.exercises.removeAll { $0.id == id }
        normalizeGroups()
    }

    // MARK: Reordering

    /// The exercises grouped into the units that move together.
    public var blocks: [Block] { Self.blocks(of: draft.exercises) }

    /// The position of the block holding the exercise, counting from zero.
    public func blockIndex(of id: UUID) -> Int? { blocks.firstIndex { $0.exerciseIDs.contains(id) } }

    public func canMoveUp(_ id: UUID) -> Bool { (blockIndex(of: id) ?? 0) > 0 }

    public func canMoveDown(_ id: UUID) -> Bool {
        guard let index = blockIndex(of: id) else { return false }
        return index < blocks.count - 1
    }

    /// Moves the block holding the exercise up by one block. A superset moves as a whole.
    public mutating func moveUp(_ id: UUID) {
        guard let index = blockIndex(of: id), index > 0 else { return }
        swapBlocks(index - 1, index)
    }

    /// Moves the block holding the exercise down by one block. A superset moves as a whole.
    public mutating func moveDown(_ id: UUID) {
        guard let index = blockIndex(of: id), index < blocks.count - 1 else { return }
        swapBlocks(index, index + 1)
    }

    /// Drops the block holding `id` onto the block holding `target`. Moving down puts it after the
    /// target block and moving up puts it before, which is where a drag lands.
    public mutating func move(_ id: UUID, onto target: UUID) {
        var lines = Self.blocks(of: draft.exercises).map { block in block.exerciseIDs.compactMap { exercise(id: $0) } }
        guard let from = lines.firstIndex(where: { $0.contains { $0.id == id } }),
              let to = lines.firstIndex(where: { $0.contains { $0.id == target } }), from != to else { return }
        let moved = lines.remove(at: from)
        lines.insert(moved, at: to)
        draft.exercises = lines.flatMap { $0 }
    }

    private mutating func swapBlocks(_ first: Int, _ second: Int) {
        var lines = Self.blocks(of: draft.exercises).map { block in block.exerciseIDs.compactMap { exercise(id: $0) } }
        lines.swapAt(first, second)
        draft.exercises = lines.flatMap { $0 }
    }

    private static func blocks(of exercises: [TemplateExercise]) -> [Block] {
        var result: [[UUID]] = []
        var openGroup: UUID?
        for line in exercises {
            if let group = line.supersetGroup, group == openGroup {
                result[result.count - 1].append(line.id)
            } else {
                result.append([line.id])
            }
            openGroup = line.supersetGroup
        }
        return result.map { Block(exerciseIDs: $0) }
    }

    // MARK: Supersets

    /// True when the exercise sits above another and a superset between them is possible.
    public func canLinkWithNext(_ id: UUID) -> Bool {
        guard let index = index(of: id) else { return false }
        return index < draft.exercises.count - 1
    }

    public func isLinkedWithNext(_ id: UUID) -> Bool {
        guard let index = index(of: id), index < draft.exercises.count - 1,
              let group = draft.exercises[index].supersetGroup else { return false }
        return draft.exercises[index + 1].supersetGroup == group
    }

    public func isLinkedWithPrevious(_ id: UUID) -> Bool {
        guard let index = index(of: id), index > 0 else { return false }
        return isLinkedWithNext(draft.exercises[index - 1].id)
    }

    /// Puts the exercise and the one below it in one superset. Two groups that meet here merge.
    public mutating func linkWithNext(_ id: UUID) {
        guard let index = index(of: id), index < draft.exercises.count - 1 else { return }
        let upper = draft.exercises[index].supersetGroup
        let lower = draft.exercises[index + 1].supersetGroup
        switch (upper, lower) {
        case (nil, nil):
            let group = UUID()
            draft.exercises[index].supersetGroup = group
            draft.exercises[index + 1].supersetGroup = group
        case (let group?, nil):
            draft.exercises[index + 1].supersetGroup = group
        case (nil, let group?):
            draft.exercises[index].supersetGroup = group
        case (let keep?, let merge?):
            guard keep != merge else { return }
            for position in draft.exercises.indices where draft.exercises[position].supersetGroup == merge {
                draft.exercises[position].supersetGroup = keep
            }
        }
    }

    /// Splits a superset between the exercise and the one below it. A part left with one member
    /// stops being a superset.
    public mutating func unlinkFromNext(_ id: UUID) {
        guard isLinkedWithNext(id), let index = index(of: id), let group = draft.exercises[index].supersetGroup else { return }
        var end = index + 1
        while end + 1 < draft.exercises.count, draft.exercises[end + 1].supersetGroup == group { end += 1 }
        let newGroup = UUID()
        for position in (index + 1)...end { draft.exercises[position].supersetGroup = newGroup }
        normalizeGroups()
    }

    /// Dissolves every superset group that has fewer than two members.
    private mutating func normalizeGroups() {
        var counts: [UUID: Int] = [:]
        for line in draft.exercises { if let group = line.supersetGroup { counts[group, default: 0] += 1 } }
        for position in draft.exercises.indices {
            if let group = draft.exercises[position].supersetGroup, counts[group, default: 0] < 2 {
                draft.exercises[position].supersetGroup = nil
            }
        }
    }

    // MARK: Exercise editor

    /// The editor state for one exercise, or nil when it is gone.
    public func editorDraft(for id: UUID) -> ExerciseEditorDraft? {
        guard let line = exercise(id: id), let position = index(of: id) else { return nil }
        return ExerciseEditorDraft(
            sets: line.sets, repsMin: line.repsMin, repsMax: line.repsMax, loadKg: line.loadKg ?? 0,
            measure: line.measure, assistKg: line.assistKg ?? 0, targetSeconds: line.plannedSeconds,
            targetMetres: line.plannedMetres, restSeconds: line.restSeconds, note: line.note,
            hasPrevious: position > 0, hasNext: position < draft.exercises.count - 1,
            linkedWithPrevious: isLinkedWithPrevious(id), linkedWithNext: isLinkedWithNext(id),
            blockIndex: blockIndex(of: id) ?? 0, blockCount: blocks.count,
            isInSuperset: isLinkedWithPrevious(id) || isLinkedWithNext(id))
    }

    /// Writes the editor state back. Numbers are clamped into the stored ranges. Superset links change
    /// first, then pending moves, and a move always carries a whole superset.
    public mutating func apply(_ editor: ExerciseEditorDraft, to id: UUID) {
        guard let position = index(of: id) else { return }
        var edited = editor
        edited.sets = min(max(edited.sets, ExerciseEditorDraft.setsRange.lowerBound), ExerciseEditorDraft.setsRange.upperBound)
        edited.setRepsMin(edited.repsMin)
        edited.setRepsMax(edited.repsMax)
        edited.restSeconds = min(max(edited.restSeconds, ExerciseEditorDraft.restRange.lowerBound), ExerciseEditorDraft.restRange.upperBound)
        func kilograms(_ value: Double) -> Double { min(max(value.isFinite ? value : 0, 0), ExerciseEditorDraft.loadRange.upperBound) }
        edited.loadKg = kilograms(edited.loadKg)
        edited.assistKg = kilograms(edited.assistKg)
        edited.targetSeconds = min(max(edited.targetSeconds, ExerciseEditorDraft.secondsRange.lowerBound), ExerciseEditorDraft.secondsRange.upperBound)
        edited.targetMetres = min(max(edited.targetMetres.isFinite ? edited.targetMetres : 0, ExerciseEditorDraft.metresRange.lowerBound),
                                  ExerciseEditorDraft.metresRange.upperBound)
        var line = draft.exercises[position]
        line.sets = edited.sets
        line.repsMin = edited.repsMin
        line.repsMax = edited.repsMax
        line.measure = edited.measure
        // Bodyweight keeps the added load or the assistance its toggle picks, never both.
        let bodyweight = edited.measure == .bodyweight
        let usesLoad = !bodyweight || edited.bodyweightLoad == .added
        line.loadKg = usesLoad && edited.loadKg > 0 ? edited.loadKg : nil
        line.assistKg = bodyweight && edited.bodyweightLoad == .assisted && edited.assistKg > 0 ? edited.assistKg : nil
        line.targetSeconds = edited.measure == .time ? edited.targetSeconds : nil
        line.targetMetres = edited.measure == .distance ? edited.targetMetres : nil
        line.restSeconds = edited.restSeconds
        line.note = String(edited.note.prefix(TrainLimits.note))
        draft.exercises[position] = line
        if position > 0 {
            let above = draft.exercises[position - 1].id
            if editor.linkedWithPrevious, !isLinkedWithNext(above) { linkWithNext(above) }
            else if !editor.linkedWithPrevious, isLinkedWithNext(above) { unlinkFromNext(above) }
        }
        if position < draft.exercises.count - 1 {
            if editor.linkedWithNext, !isLinkedWithNext(id) { linkWithNext(id) }
            else if !editor.linkedWithNext, isLinkedWithNext(id) { unlinkFromNext(id) }
        }
        if editor.blockShift < 0 { for _ in 0..<(-editor.blockShift) { moveUp(id) } }
        if editor.blockShift > 0 { for _ in 0..<editor.blockShift { moveDown(id) } }
    }

    // MARK: Saving

    /// Saves the draft through `perform`. On success the stored template, with its new revision,
    /// becomes both the draft and the baseline, so the model is clean again. Throws `Problem`
    /// when the draft is not valid, or whatever `perform` throws, and leaves the model unchanged.
    /// An existing template with no edits is not written again.
    public mutating func save(using perform: SaveHandler) async throws {
        if let problem { throw problem }
        if !isNew, !isDirty { return }
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = try await perform(candidate)
        original = stored
        draft = stored
    }
}

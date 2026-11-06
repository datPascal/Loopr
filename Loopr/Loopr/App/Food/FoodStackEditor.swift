import DesignSystem
import FoodKit
import NotificationKit
import SettingsKit
import SwiftUI

/// One stack item as the editor holds it while the person types. Two drafts are the same draft when their ids match.
struct FoodStackDraft: Identifiable, Hashable {
    let id: UUID
    let lane: StackLane
    /// Nil for a new item. A saved item keeps its key, so Protocol rules that name it keep working after a rename.
    var key: String?
    var name = ""
    var amount = ""
    var unit: DoseUnit = .mg
    var form: SupplementForm = .capsule
    var brand = ""
    /// Nil picks a pair from the item's key.
    var colors: CapsuleColors?
    var schedule: StackSchedule = .morning
    var prescriber = ""
    var notes = ""
    var isActive = true
    var startDay: String
    var sortOrder: Int
    var createdAt: Date

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(lane: StackLane, startDay: String, sortOrder: Int, createdAt: Date) {
        id = UUID(); self.lane = lane; self.startDay = startDay; self.sortOrder = sortOrder; self.createdAt = createdAt
        if lane == .medication { unit = .mg }
    }

    init(_ item: SupplementItem) {
        id = item.id; lane = .supplement; key = item.key; name = item.name; amount = Self.text(item.dose.amount); unit = item.dose.unit
        form = item.form; brand = item.brand ?? ""; colors = item.colors; schedule = item.schedule; isActive = item.isActive
        startDay = item.startDay; sortOrder = item.sortOrder; createdAt = item.createdAt
    }

    init(_ item: MedicationItem) {
        id = item.id; lane = .medication; key = item.key; name = item.name; amount = Self.text(item.dose.amount); unit = item.dose.unit
        prescriber = item.prescriber ?? ""; notes = item.notes ?? ""; schedule = item.schedule; isActive = item.isActive
        startDay = item.startDay; sortOrder = item.sortOrder; createdAt = item.createdAt
    }

    /// The dose in the phone's number format, so "2,5" shows where a comma is the separator (DEC-08.6).
    static func text(_ amount: Double) -> String { amount.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)) }

    /// "2.5" and "2,5" both read as two and a half.
    var parsedAmount: Double? {
        Double(amount.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The stack editor, opened from "Edit" on the Food tab's Stack: add, change, pause and remove supplements and
/// medication, and set a daily reminder for each part of the day. Medication stays in its own section (DEC-12.10).
struct FoodStackEditor: View {
    @Environment(\.dismiss) private var dismiss
    let repository: AppFoodRepository
    let calendar: Calendar
    let now: Date
    let didChange: @MainActor @Sendable () async -> Void
    @State private var supplements: [SupplementItem] = []
    @State private var medication: [MedicationItem] = []
    @State private var editing: FoodStackDraft?
    @State private var removing: (id: UUID, name: String)?
    @State private var message: String?
    @State private var reminders: [String: Int] = [:]

    private var today: String { (try? FoodMeal.day(at: now, timeZoneIdentifier: calendar.timeZone.identifier)) ?? "" }
    private var nextSort: Int { ((supplements.map(\.sortOrder) + medication.map(\.sortOrder)).max() ?? -1) + 1 }

    var body: some View {
        Form {
            Section {
                ForEach(supplements) { item in
                    row(name: item.name, key: item.key, detail: [item.dose.text, Self.title(item.schedule), item.brand].compactMap { $0 }.joined(separator: " · "),
                        active: item.isActive, id: item.id, colors: item.colors ?? FoodStackShelf.colors(forKey: item.key), tablet: false) {
                        editing = FoodStackDraft(item)
                    }
                }
                Button { editing = FoodStackDraft(lane: .supplement, startDay: today, sortOrder: nextSort, createdAt: now) } label: {
                    Label("Add a supplement", systemImage: "plus")
                }
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .accessibilityIdentifier("food-stack-add-supplement")
            } header: { Text("Supplements") } footer: {
                Text("Your morning and evening stacks. Ticks on the Food tab count for Protocol rules and experiments.")
            }
            Section {
                ForEach(medication) { item in
                    row(name: item.name, key: "medication-\(item.key)",
                        detail: [item.dose.text, Self.title(item.schedule), item.prescriber].compactMap { $0 }.joined(separator: " · "),
                        active: item.isActive, id: item.id, colors: FoodStackShelf.medicationColors, tablet: true) {
                        editing = FoodStackDraft(item)
                    }
                }
                Button { editing = FoodStackDraft(lane: .medication, startDay: today, sortOrder: nextSort, createdAt: now) } label: {
                    Label("Add a medicine", systemImage: "plus")
                }
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .accessibilityIdentifier("food-stack-add-medication")
            } header: { Text("Medication") } footer: {
                Text("Kept apart from supplements, with its dose and who prescribed it. Loopr does not check doses or interactions.")
            }
            #if canImport(UserNotifications)
            remindersSection
            #endif
            if let message {
                Section { Text(message).foregroundStyle(Color.loopr(.critical)).accessibilityIdentifier("food-stack-error") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Your stack")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("food-stack-done") } }
        .navigationDestination(item: $editing) { draft in
            FoodStackItemForm(draft: draft) { @MainActor @Sendable saved in try await save(saved) }
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let removing {
                Button("Remove and delete its ticks", role: .destructive) {
                    let id = removing.id
                    Task { await run { try await repository.deleteStackItem(id: id) } }
                }.accessibilityIdentifier("food-stack-confirm-remove")
            }
        } message: { Text("Its history goes too. Pause it instead to keep what you recorded.") }
        .task { await reload() }
        .accessibilityIdentifier("food-stack-editor")
    }

    private func row(name: String, key: String, detail: String, active: Bool, id: UUID, colors: CapsuleColors, tablet: Bool,
                     open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: LooprSpacing.sm) {
                FoodStackSwatch(colors: colors, tablet: tablet).opacity(active ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).looprTypography(.rowTitle).foregroundStyle(Color.loopr(.ink))
                    Text(active ? detail : "\(detail) · paused").looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                }
                Spacer(minLength: 0)
                LooprChevron()
            }
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { removing = (id, name) } label: { Label("Remove", systemImage: "trash") }
                .accessibilityIdentifier("food-stack-remove-\(key)")
            Button { Task { await run { try await repository.setStackItemActive(!active, id: id) } } } label: {
                Label(active ? "Pause" : "Resume", systemImage: active ? "pause" : "play")
            }
            .tint(Color.loopr(.inkSecondary))
            .accessibilityIdentifier("food-stack-pause-\(key)")
        }
        .accessibilityHint("Opens this item. Swipe for pause and remove.")
        .accessibilityIdentifier("food-stack-row-\(key)")
    }

    static func title(_ schedule: StackSchedule) -> String {
        switch schedule { case .morning: "Morning"; case .evening: "Evening"; case .both: "Morning and evening" }
    }

    private func save(_ draft: FoodStackDraft) async throws {
        guard let name = FoodStackDraft.clean(draft.name), let amount = draft.parsedAmount else { throw StackError.invalidItem }
        let key: String
        if let existing = draft.key { key = existing } else { key = try await repository.uniqueStackKey(forName: name, lane: draft.lane) }
        let dose = DoseAmount(amount: amount, unit: draft.unit)
        switch draft.lane {
        case .supplement:
            try await repository.saveSupplement(try SupplementItem(id: draft.id, key: key, name: name, dose: dose, form: draft.form,
                brand: FoodStackDraft.clean(draft.brand), colors: draft.colors, schedule: draft.schedule, isActive: draft.isActive,
                startDay: draft.startDay, sortOrder: draft.sortOrder, createdAt: draft.createdAt))
        case .medication:
            try await repository.saveMedication(try MedicationItem(id: draft.id, key: key, name: name, dose: dose,
                prescriber: FoodStackDraft.clean(draft.prescriber), schedule: draft.schedule, notes: FoodStackDraft.clean(draft.notes),
                isActive: draft.isActive, startDay: draft.startDay, sortOrder: draft.sortOrder, createdAt: draft.createdAt))
        }
        await reload()
        await didChange()
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) async {
        message = nil
        do { try await work(); await reload(); await didChange() }
        catch { message = error.localizedDescription }
    }

    private func reload() async {
        do {
            supplements = try await repository.supplements()
            medication = try await repository.medication()
        } catch { message = error.localizedDescription }
        #if canImport(UserNotifications)
        reminders = await LooprNotificationRuntime.shared.stackReminderMinutes(calendar: calendar)
        #endif
    }

    // MARK: Reminders

    #if canImport(UserNotifications)
    /// One row per lane and part of the day that has an active item. The text the notification will show is on the
    /// row, and the person confirms it before it is set.
    @ViewBuilder private var remindersSection: some View {
        let slots: [(StackLane, StackSlot)] = StackSlot.allCases.filter { slot in supplements.contains { $0.isActive && $0.schedule.includes(slot) } }
            .map { (StackLane.supplement, $0) }
            + StackSlot.allCases.filter { slot in medication.contains { $0.isActive && $0.schedule.includes(slot) } }.map { (StackLane.medication, $0) }
        if !slots.isEmpty {
            Section {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, pair in
                    FoodStackReminderRow(lane: pair.0, slot: pair.1, calendar: calendar, now: now,
                                         current: reminders[StackReminder.objectID(lane: pair.0, slot: pair.1)]) { minute in
                        let outcome = await LooprNotificationRuntime.shared.scheduleStackReminder(lane: pair.0, slot: pair.1, minuteOfDay: minute, calendar: calendar)
                        reminders = await LooprNotificationRuntime.shared.stackReminderMinutes(calendar: calendar)
                        return Self.message(for: outcome)
                    } remove: {
                        await LooprNotificationRuntime.shared.cancelStackReminder(lane: pair.0, slot: pair.1)
                        reminders = await LooprNotificationRuntime.shared.stackReminderMinutes(calendar: calendar)
                    }
                }
            } header: { Text("Reminders") } footer: {
                Text("A daily reminder through Reminders you set. It names the stack, never what is in it.")
            }
        }
    }

    static func message(for outcome: UserReminderOutcome) -> String? {
        switch outcome {
        case .set: nil
        case .notAllowed: "Notifications are off for Loopr. Turn them on in the Settings app to get this reminder."
        case .full: "Ten reminders are already waiting. Remove one in Settings, under Reminders you set."
        case .familyOff: "Reminders you set is off in Loopr's settings. Turn it on to get this reminder."
        case .failed: "The reminder could not be set. Try again."
        }
    }
    #endif
}

/// A small capsule or tablet in an item's colours, beside its name in the editor.
struct FoodStackSwatch: View {
    let colors: CapsuleColors
    let tablet: Bool
    var body: some View {
        let first = Self.color(colors.first), second = Self.color(colors.second)
        Group {
            if tablet {
                Circle().fill(LinearGradient(colors: [first, second], startPoint: .top, endPoint: .bottom)).frame(width: 20, height: 20)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(stops: [.init(color: first, location: 0), .init(color: first, location: 0.5),
                                                 .init(color: second, location: 0.5), .init(color: second, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 12, height: 26)
                    .rotationEffect(.degrees(18))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    static func color(_ hex: String) -> Color {
        guard hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return Color.loopr(.energy) }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// The form for one supplement or medicine.
struct FoodStackItemForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FoodStackDraft
    let save: @MainActor @Sendable (FoodStackDraft) async throws -> Void
    @State private var saving = false
    @State private var message: String?

    init(draft: FoodStackDraft, save: @escaping @MainActor @Sendable (FoodStackDraft) async throws -> Void) {
        _draft = State(initialValue: draft); self.save = save
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text(draft.lane == .supplement ? "Vitamin D3" : "Name on the pack"))
                    .accessibilityIdentifier("food-stack-name")
                HStack {
                    TextField("Dose", text: $draft.amount, prompt: Text("Amount"))
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("food-stack-dose")
                    Picker("Unit", selection: $draft.unit) {
                        ForEach(DoseUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Unit")
                    .accessibilityIdentifier("food-stack-unit")
                }
                if draft.lane == .supplement {
                    Picker("Form", selection: $draft.form) {
                        ForEach(SupplementForm.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("food-stack-form")
                    TextField("Brand", text: $draft.brand, prompt: Text("Brand, if you want it"))
                        .accessibilityIdentifier("food-stack-brand")
                } else {
                    TextField("Prescriber", text: $draft.prescriber, prompt: Text("Who prescribed it, if you want"))
                        .accessibilityIdentifier("food-stack-prescriber")
                    TextField("Notes", text: $draft.notes, prompt: Text("Notes"), axis: .vertical)
                        .accessibilityIdentifier("food-stack-notes")
                }
            }
            Section("When") {
                Picker("Taken", selection: $draft.schedule) {
                    ForEach(StackSchedule.allCases, id: \.self) { schedule in
                        Text(schedule == .both ? "Both" : FoodStackEditor.title(schedule)).tag(schedule)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("food-stack-schedule")
                Toggle("Paused", isOn: Binding(get: { !draft.isActive }, set: { draft.isActive = !$0 }))
                    .accessibilityHint("A paused item is not due and keeps its history")
                    .accessibilityIdentifier("food-stack-paused")
            }
            if draft.lane == .supplement {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: LooprSpacing.xs) {
                        ForEach(Array(FoodStackShelf.palette.enumerated()), id: \.offset) { index, pair in
                            Button { draft.colors = pair } label: {
                                FoodStackSwatch(colors: pair, tablet: false)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().strokeBorder(Color.loopr(.energy), lineWidth: draft.colors == pair ? 2 : 0))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour \(index + 1)")
                            .accessibilityAddTraits(draft.colors == pair ? .isSelected : [])
                            .accessibilityIdentifier("food-stack-colour-\(index)")
                        }
                    }
                } header: { Text("Capsule colours") } footer: { Text("How the capsule looks on the Food tab.") }
            }
            if let message {
                Section { Text(message).foregroundStyle(Color.loopr(.critical)).accessibilityIdentifier("food-stack-form-error") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle(draft.key == nil ? (draft.lane == .supplement ? "New supplement" : "New medicine") : draft.name)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true; message = nil
                    Task {
                        do { try await save(draft); dismiss() }
                        catch { message = error.localizedDescription }
                        saving = false
                    }
                }
                .disabled(saving || FoodStackDraft.clean(draft.name) == nil || draft.parsedAmount == nil)
                .accessibilityIdentifier("food-stack-save")
            }
        }
    }
}

#if canImport(UserNotifications)
/// The daily reminder for one part of the day. It shows the exact words the notification will carry, and asks once
/// more with those words before it sets or changes the reminder.
struct FoodStackReminderRow: View {
    let lane: StackLane
    let slot: StackSlot
    let calendar: Calendar
    let now: Date
    /// Minutes after midnight of the waiting reminder, or nil when there is none.
    let current: Int?
    let set: @MainActor (Int) async -> String?
    let remove: @MainActor () async -> Void
    @State private var time = Date()
    @State private var confirming = false
    @State private var message: String?
    @State private var working = false

    private var title: String { StackReminder.title(lane: lane, slot: slot) }
    private var detail: String { StackReminder.detail(lane: lane, slot: slot) }
    private var identifier: String { "\(lane.rawValue)-\(slot.rawValue)" }
    private var minute: Int {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack {
                Text(title).looprTypography(.rowTitle)
                Spacer(minLength: LooprSpacing.xs)
                Text(current.map { "Every day at \(LooprClockFormat.text(minuteOfDay: $0))" } ?? "Off")
                    .looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
            }
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, calendar.timeZone)
                .frame(minHeight: 44)
                .accessibilityIdentifier("food-stack-reminder-time-\(identifier)")
            Text("It will read: \(title). \(detail)")
                .looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: LooprSpacing.sm) {
                Button(current == nil ? "Set reminder" : "Change time") { confirming = true }
                    .buttonStyle(.borderless)
                    .disabled(working)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("food-stack-reminder-set-\(identifier)")
                if current != nil {
                    Button("Turn off", role: .destructive) {
                        working = true
                        Task { await remove(); working = false }
                    }
                    .buttonStyle(.borderless)
                    .disabled(working)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("food-stack-reminder-off-\(identifier)")
                }
            }
            if let message { Text(message).looprTypography(.caption).foregroundStyle(Color.loopr(.critical)) }
        }
        .padding(.vertical, LooprSpacing.xxs)
        .onAppear {
            let start = current ?? (slot == .morning ? 8 * 60 : 21 * 60)
            time = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: now) ?? now
        }
        .confirmationDialog("Set this daily reminder?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Set for \(LooprClockFormat.text(minuteOfDay: minute))") {
                working = true; message = nil
                let chosen = minute
                Task { message = await set(chosen); working = false }
            }
            .accessibilityIdentifier("food-stack-reminder-confirm-\(identifier)")
        } message: {
            Text("Every day at \(LooprClockFormat.text(minuteOfDay: minute)) your phone will show \"\(title)\" with \"\(detail)\"")
        }
    }
}

extension LooprNotificationRuntime {
    /// The waiting stack reminders, by object id, as minutes after midnight on `calendar`'s clock.
    func stackReminderMinutes(calendar: Calendar) async -> [String: Int] {
        await userReminders().filter(StackReminder.isStackReminder).reduce(into: [:]) { result, request in
            let parts = calendar.dateComponents([.hour, .minute], from: request.fireDate)
            result[request.identity.objectID] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    /// Sets or moves the daily reminder for one stack, after the person confirmed its words. Asks for permission here,
    /// on that confirmation, and never before.
    func scheduleStackReminder(lane: StackLane, slot: StackSlot, minuteOfDay: Int, calendar: Calendar) async -> UserReminderOutcome {
        switch await refreshAuthorization() {
        case .authorized: break
        case .notDetermined: guard await requestPermission() == .available else { return .notAllowed }
        case .denied: return .notAllowed
        }
        switch StackReminder.build(lane: lane, slot: slot, minuteOfDay: minuteOfDay, now: Date(), calendar: calendar,
                                   pending: await userReminders()) {
        case .refused(.full): return .full
        case .refused(.invalidTime): return .failed
        case .request(let request, let replacesPending):
            if replacesPending {
                try? await policy.remove(family: .userReminders, objectID: request.identity.objectID, day: request.identity.day)
            }
            do {
                switch try await policy.schedule(request) {
                case .scheduled, .deferred, .duplicate: return .set
                case .disabled: return .familyOff
                case .denied, .queued: return .notAllowed
                case .limitReached: return .full
                case .quietHours, .expired: return .failed
                }
            } catch { return .failed }
        }
    }

    func cancelStackReminder(lane: StackLane, slot: StackSlot) async {
        try? await policy.remove(family: .userReminders, objectID: StackReminder.objectID(lane: lane, slot: slot))
    }
}
#endif

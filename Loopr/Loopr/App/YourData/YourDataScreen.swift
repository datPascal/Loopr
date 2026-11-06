import AIKit
import DataKit
import DesignSystem
import SettingsKit
import SwiftUI

struct YourDataScreen: View {
    @Environment(\.looprBandIndicator) private var band
    @Environment(\.looprBandLink) private var bandLink
    @State private var model: YourDataModel
    @State private var choosingFolder = false
    let route: (SettingsFlowRoute) -> Void
    let openTab: (MainTab) -> Void
    init(repositories: ProductRepositoryContainer?, route: @escaping (SettingsFlowRoute) -> Void, openTab: @escaping (MainTab) -> Void) {
        _model = State(initialValue: YourDataModel(repositories: repositories))
        self.route = route; self.openTab = openTab
    }
    var body: some View {
        LooprDetailScaffold(spacing: LooprSpacing.lg) {
            storage
            sources
            access
            providers
            exports
            settings
            if let error = model.error ?? model.backup.error {
                LooprCard(style: .warning) {
                    LooprText(error, style: .prose)
                    Button(model.backup.error == nil ? "Reload storage" : "Try backup again") {
                        Task {
                            if model.backup.error != nil { await model.backupNow() }
                            else { await model.load() }
                        }
                    }
                        .buttonStyle(LooprButtonStyle())
                        .accessibilityIdentifier("your-data-retry")
                }
            }
            if let archive = model.preparedArchive {
                ShareLink(item: archive) { Label("Share export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .accessibilityIdentifier("your-data-share")
            }
            Button("Delete all data", role: .destructive) { route(.data(.deletion)) }
                .buttonStyle(LooprDestructiveButtonStyle())
                .disabled(model.isExporting || model.backup.isRunning)
                .accessibilityIdentifier("your-data-delete")
        }
        .tint(Color.loopr(.brand))
        .navigationTitle("Your data")
        .toolbarTitleDisplayMode(.inline)
        .looprAskToolbar(origin: "Your data")
        .accessibilityIdentifier("your-data-screen")
        .task { await model.load() }
        .sheet(isPresented: $choosingFolder) {
            FilesBackupFolderPicker(selected: { url in
                choosingFolder = false
                Task { await model.chooseFolder(url) }
            }, cancelled: { choosingFolder = false })
        }
    }
    private var storage: some View {
        LooprCard(style: .hero(.brand)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                StatusChip("On this iPhone", symbol: "iphone", accent: .brand)
                if let inventory = model.inventory {
                    LooprValueText(inventory.diskBytes.formatted(.byteCount(style: .file).locale(LooprUnitFormatter.displayLocale)), valueStyle: .metric)
                        .accessibilityIdentifier("your-data-total")
                    LooprText("No Loopr account and no Loopr server. Data leaves only when you export it or ask the agent.", style: .prose, color: .inkSecondary)
                    LooprStorageBreakdown(segments: YourDataDomain.allCases.map { domain in
                        .init(id: domain.rawValue, title: domain.title, bytes: inventory.contentBytes[domain] ?? 0, accent: domain.accent)
                    }, compactLegend: true)
                    .accessibilityHint("Category sizes count saved content. The total also includes database space and temporary database files.")
                } else {
                    StateMessage(model.isLoading ? .loading : model.error != nil ? .recoverableError : .noRecords, compact: true)
                }
            }
        }
    }
    private var sources: some View {
        VStack(spacing: LooprSpacing.xs) {
            LooprSectionHeader("Sources")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    row(bandLink?.bandModelName ?? "WHOOP band", detail: bandDetail, accent: .brand, id: "band") { route(.settings(.deviceCenter)) }
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    row("Apple Health", detail: count(\.healthRecords, "stored reading", "stored readings"), accent: .heart, id: "apple-health") { route(.settings(.healthKit)) }
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    row("WHOOP account export", detail: count(\.importedDays, "day imported", "days imported"), accent: .inkSecondary, id: "import") { route(.data(.importPreview)) }
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    row("Food log", detail: model.inventory.map { "\($0.meals) \($0.meals == 1 ? "meal" : "meals") · \($0.photos) \($0.photos == 1 ? "photo" : "photos")" } ?? (model.error == nil ? "Loading" : "Count unavailable"), accent: .energy, id: "food") { openTab(.food) }
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    row("Fitness", detail: count(\.workouts, "saved workout", "saved workouts"), accent: .movement, id: "training") { openTab(.fitness) }
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    row("Protocol", detail: model.inventory.map { "\($0.checkIns) \($0.checkIns == 1 ? "check-in" : "check-ins") · \($0.notes) \($0.notes == 1 ? "entry" : "entries")" } ?? (model.error == nil ? "Loading" : "Count unavailable"), accent: .cyclePlum, id: "journal") { openTab(.protocol) }
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    // Pending notifications live in iOS, not in a file, so no export or count can include them.
                    row("Reminders you set", detail: "On this iPhone only, not in exports", accent: .brand, id: "reminders") { route(.settings(.notifications)) }
                }
            }
        }
    }
    /// The rest of Settings. FT-01 matched this screen to its mockup and dropped the only row into it, which left
    /// profile, units, appearance, privacy and support with no way in.
    private var settings: some View {
        VStack(spacing: LooprSpacing.xs) {
            LooprSectionHeader("Settings")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    row("Profile", detail: "Age, sex, height and weight", accent: .brand, id: "profile") { route(.settings(.profile)) }
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    row("All settings", detail: "Units, appearance, notifications, privacy and support", accent: .brand, id: "all-settings") { route(.settingsHome) }
                }
            }
        }
    }
    private var access: some View {
        VStack(spacing: LooprSpacing.xs) {
            LooprSectionHeader("What the agent may read", detail: "Applies to every question you send")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    ForEach(AgentDataDomain.allCases, id: \.self) { domain in
                        LooprToggleRow(title: domain.title, subtitle: domain.detail, isOn: Binding(
                            get: { model.access.allows(domain) }, set: { model.access.set(domain, allowed: $0) }
                        ))
                        .accessibilityIdentifier("agent-access-\(domain.rawValue)")
                        LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    }
                    NavigationLink { RequestLogScreen(log: model.requestLog) } label: {
                        LooprRow(title: "Request log", subtitle: "What was sent, last \(AgentRequestLogPolicy.retentionDays) days", symbol: nil)
                    }
                    .buttonStyle(.looprPressableRow)
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .accessibilityIdentifier("your-data-request-log")
                }
            }
        }
    }
    private var providers: some View {
        VStack(spacing: LooprSpacing.xs) {
            LooprSectionHeader("AI provider")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    provider(.anthropic, id: "claude")
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    provider(.openAI, id: "openai")
                }
            }
        }
    }
    private var exports: some View {
        VStack(spacing: LooprSpacing.xs) {
            LooprSectionHeader("Take it with you")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    row("Export everything", detail: "JSON and CSV per table, plus photos", accent: .brand, id: "export") { Task { await model.export(.everything) } }
                        .disabled(model.isExporting || model.inventory == nil)
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    row("Copy the database", detail: "Both SQLite files, including band history", accent: .brand, id: "database") { Task { await model.export(.databases) } }
                        .disabled(model.isExporting || model.inventory == nil)
                    LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                    LooprToggleRow(title: "Weekly backup to Files", subtitle: backupDetail, isOn: Binding(get: { model.backup.preferences.enabled }, set: { enabled in
                        if enabled, model.backup.preferences.bookmark == nil { choosingFolder = true }
                        else { model.backup.preferences.setEnabled(enabled) }
                    }))
                    .disabled(model.backup.isRunning)
                    .accessibilityIdentifier("your-data-weekly-backup")
                    if model.backup.preferences.bookmark != nil {
                        LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                        row("Back up now", detail: model.backup.preferences.folderName, accent: .brand, id: "backup-now") { Task { await model.backupNow() } }
                            .disabled(model.backup.isRunning || model.isExporting)
                        LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                        row("Choose backup folder", detail: nil, accent: .brand, id: "backup-folder") { choosingFolder = true }
                            .disabled(model.backup.isRunning)
                    }
                }
            }
            if model.isExporting || model.backup.isRunning { StateMessage(.loading, compact: true) }
        }
    }
    private var bandDetail: String {
        var parts = [count(\.bandRecords, "daily reading", "daily readings")]
        if let band {
            switch band.link {
            case .connected: parts.append("Connected")
            case .syncing: parts.append("Syncing")
            case .reconnecting: parts.append("Reconnecting")
            case .disconnected: parts.append("Not connected")
            case .bluetoothOff: parts.append("Bluetooth is off")
            case .needsAttention: parts.append("Needs attention")
            case .notPaired: parts.append("No paired band")
            }
            if let percent = band.batteryPercent { parts.append("\(percent)% battery") }
        }
        if let sync = band?.lastSyncedAt { parts.append("Synced " + sync.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
    private var backupDetail: String {
        let policy = "Copies everything, blood tests too, as a ZIP that Loopr does not encrypt. Saves when you open Loopr, if your last backup was more than a week ago."
        guard let last = model.backup.preferences.lastSuccess else { return policy }
        return "Last saved \(last.formatted(date: .abbreviated, time: .shortened)). " + policy
    }
    private func count(_ keyPath: KeyPath<YourDataInventory, Int64>, _ singular: String, _ plural: String) -> String {
        model.inventory.map { "\($0[keyPath: keyPath]) \($0[keyPath: keyPath] == 1 ? singular : plural)" } ?? (model.error == nil ? "Loading" : "Count unavailable")
    }
    private func row(_ title: String, detail: String?, accent: LooprColorToken, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LooprRow(title: title, subtitle: detail, symbol: sourceSymbol(id), accent: accent)
        }
        .buttonStyle(.looprPressableRow)
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .accessibilityIdentifier("your-data-\(id)")
    }
    private func sourceSymbol(_ id: String) -> String? {
        switch id {
        case "band": "applewatch"
        case "reminders": "bell"
        case "apple-health": "heart.fill"
        case "import": "doc.text"
        case "food": "fork.knife"
        case "training": "dumbbell.fill"
        case "journal": "book.closed.fill"
        case "profile": "person.crop.circle"
        case "all-settings": "gearshape"
        default: nil
        }
    }
    private func provider(_ provider: CoachProvider, id: String) -> some View {
        Button { route(.provider(provider)) } label: {
            LooprRow(title: provider.name,
                     subtitle: model.configuredProviders.contains(provider) ? "Your API key" : "Add a key",
                     symbol: nil) {
                if model.selectedProvider == provider {
                    StatusChip("In use", symbol: "checkmark.circle", accent: .brand)
                } else {
                    Image(systemName: "chevron.right")
                }
            }
        }
        .buttonStyle(.looprPressableRow)
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .accessibilityIdentifier("your-data-\(id)")
    }

}

private extension YourDataDomain {
    var accent: LooprColorToken {
        switch self {
        case .band: .heart
        case .food: .energy
        case .training: .movement
        case .journal: .cyclePlum
        case .other: .inkSecondary
        }
    }
}

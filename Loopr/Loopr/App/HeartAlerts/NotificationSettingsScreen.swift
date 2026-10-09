import SwiftUI
import DesignSystem
import NotificationKit
import SettingsKit

/// Settings > Notifications. Permission, quiet hours, the heart alerts entry
/// and one toggle per notification Loopr actually sends.
struct LooprNotificationSettingsScreen: View {
    let openHeartAlerts: () -> Void
    var runtime: LooprNotificationRuntime = .shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var authorization: NotificationAuthorizationState = .notDetermined
    @State private var delivery = NotificationDeliverySettings.standard
    @State private var families: [NotificationPreferenceSetting] = []
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprSectionGroup(title: "Permission") { permissionCard }
                LooprSectionGroup(title: "Quiet hours") { quietHoursCard }
                LooprSectionGroup(title: "Heart") {
                    LooprFormCard(padding: 0) {
                        Button(action: openHeartAlerts) {
                            HStack {
                                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                    LooprText("Heart alerts", style: .settingsRow)
                                    LooprText("High and low heart rate, overnight check", style: .caption, color: .inkSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Color.loopr(.inkMuted))
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, LooprSpacing.formCardPadding)
                            .frame(minHeight: LooprSpacing.interactiveRowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-notification-heart-alerts")
                    }
                }
                LooprSectionGroup(title: "Alerts") { familyToggles }
                if let message {
                    LooprInlineMessage(message, tone: .warning)
                }
            }
            .padding(LooprSpacing.screenGutter)
        }
        .background(Color.loopr(.background))
        .foregroundStyle(Color.loopr(.ink))
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("settings-destination-notifications")
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
        }
    }

    private var permissionCard: some View {
        LooprFormCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(permissionTitle, style: .rowTitle)
                    .accessibilityIdentifier("settings-notifications-permission-state")
                LooprText(permissionDetail, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch authorization {
                case .notDetermined:
                    Button("Allow notifications") {
                        Task {
                            _ = await runtime.requestPermission()
                            await refresh()
                        }
                    }
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .disabled(!loaded)
                    .accessibilityIdentifier("settings-notifications-request-permission")
                case .denied:
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false))
                    .accessibilityIdentifier("settings-notifications-open-settings")
                case .authorized:
                    EmptyView()
                }
            }
        }
    }

    private var permissionTitle: String {
        guard loaded else { return "Checking permission…" }
        return switch authorization {
        case .authorized: "Allowed"
        case .denied: "Off in iOS Settings"
        case .notDetermined: "Not asked yet"
        }
    }

    private var permissionDetail: String {
        switch authorization {
        case .authorized: "Loopr can send the notifications you turn on below."
        case .denied: "Loopr can't send anything until you allow notifications for Loopr in iOS Settings."
        case .notDetermined: "Loopr asks once. Nothing is sent until you allow it."
        }
    }

    private var quietHoursCard: some View {
        LooprFormCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                LooprToggleRow(
                    title: "Quiet hours",
                    subtitle: "Workout and device notifications are skipped during these hours. Reminders you set still arrive on time. The morning recap and heart alerts wait until quiet hours end, unless you allow heart alerts in Heart alerts.",
                    isOn: Binding(
                        get: { delivery.quietHoursEnabled },
                        set: { enabled in
                            var next = delivery
                            next.quietHoursEnabled = enabled
                            save(next)
                        }
                    )
                )
                .accessibilityIdentifier("settings-notifications-quiet-hours")
                if delivery.quietHoursEnabled {
                    LooprHairline()
                    timeRow(title: "From", minute: delivery.quietHours.startMinute, identifier: "settings-notifications-quiet-start") { minute in
                        var next = delivery
                        next.quietHours = QuietHours(startMinute: minute, endMinute: delivery.quietHours.endMinute)
                        save(next)
                    }
                    LooprHairline()
                    timeRow(title: "To", minute: delivery.quietHours.endMinute, identifier: "settings-notifications-quiet-end") { minute in
                        var next = delivery
                        next.quietHours = QuietHours(startMinute: delivery.quietHours.startMinute, endMinute: minute)
                        save(next)
                    }
                }
            }
        }
    }

    private func timeRow(title: String, minute: Int, identifier: String, set: @escaping (Int) -> Void) -> some View {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        return DatePicker(
            selection: Binding(
                get: { calendar.date(byAdding: .minute, value: minute, to: base) ?? base },
                set: { date in
                    let parts = calendar.dateComponents([.hour, .minute], from: date)
                    set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
                }
            ),
            displayedComponents: .hourAndMinute
        ) {
            LooprText(title, style: .settingsRow)
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var familyToggles: some View {
        if !loaded {
            LooprSkeleton(height: 56)
        } else {
            LooprFormCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(families.enumerated()), id: \.element.id) { index, family in
                        LooprToggleRow(title: family.title, subtitle: family.id == "recoveryReadiness" ? "Recovery, what shaped it and today's strain range, once after your night syncs." : nil, isOn: Binding(
                            get: { families.first(where: { $0.id == family.id })?.isEnabled ?? false },
                            set: { enabled in setFamily(family, enabled: enabled) }
                        ))
                        .accessibilityIdentifier("settings-notification-\(family.id)")
                        if index < families.count - 1 { LooprHairline() }
                    }
                }
            }
        }
    }

    private func setFamily(_ family: NotificationPreferenceSetting, enabled: Bool) {
        if let index = families.firstIndex(where: { $0.id == family.id }) {
            families[index] = NotificationPreferenceSetting(id: family.id, title: family.title, isEnabled: enabled)
        }
        Task {
            do {
                try await runtime.setPreference(id: family.id, enabled: enabled)
                message = nil
            } catch {
                message = "Loopr couldn't save this change. \(error.localizedDescription)"
            }
            families = await runtime.preferences()
        }
    }

    private func save(_ next: NotificationDeliverySettings) {
        delivery = next
        Task {
            do {
                try await runtime.setDeliverySettings(next)
                message = nil
            } catch {
                message = "Loopr couldn't save quiet hours. \(error.localizedDescription)"
                delivery = await runtime.deliverySettings()
            }
        }
    }

    private func refresh() async {
        authorization = await runtime.refreshAuthorization()
        delivery = await runtime.deliverySettings()
        families = await runtime.preferences()
        loaded = true
    }
}

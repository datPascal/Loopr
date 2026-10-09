import Foundation

/// What the pairing step shows. The app maps its Bluetooth model onto this,
/// so the package never imports the app's status type.
public enum OnboardingPairingPhase: Equatable, Sendable {
    /// Nothing started yet.
    case idle
    /// The app still needs one more tap before the system sheet can open.
    case confirmReady
    /// The iOS accessory sheet is up.
    case choosing
    /// A band was chosen and Loopr is connecting to it.
    case connecting
    case connected
    case bluetoothOff
    case cancelled
    /// The sheet closed without a band.
    case notFound
    /// iOS kept a pairing key the band no longer accepts. The only fix is
    /// Forget This Device in the iPhone's Bluetooth settings.
    case bondRepair
    case failed(String)

    public var isWorking: Bool {
        switch self {
        case .choosing, .connecting: true
        default: false
        }
    }

    public var isProblem: Bool {
        switch self {
        case .bluetoothOff, .cancelled, .notFound, .bondRepair, .failed: true
        default: false
        }
    }

    /// The "band not in the list" checklist fits the moments the person is
    /// looking at the sheet, or has just left it without a band. It never
    /// shows while a chosen band is connecting: the band was found.
    public var offersFindHelp: Bool {
        switch self {
        case .choosing, .cancelled, .notFound, .failed: true
        default: false
        }
    }

    /// While the sheet is up, help waits a calm beat. After a problem it
    /// shows at once.
    public var findHelpWaits: Bool { self == .choosing }
}

/// Every string the onboarding flow shows, in one place so review against
/// the copy rules (sentence case, no em dashes, no exclamation marks, no
/// medical claims) covers the whole flow at once. Loopr never claims to be
/// WHOOP or to be made by WHOOP; it names WHOOP only to say which band and
/// which app the person has.
public enum OnboardingCopy {
    public enum Chrome {
        public static let back = "Back"
        public static let dataControls = "Data controls"

        public static func progress(step: Int, of total: Int) -> String {
            "Step \(step) of \(total)"
        }

        /// The mono line under the header title, as the tabs have.
        public static func meta(step: Int, of total: Int, optional: Bool) -> String {
            let base = "STEP \(step) OF \(total)"
            return optional ? "\(base) · OPTIONAL" : base
        }

        public static func headerTitle(for stage: OnboardingStage) -> String {
            switch stage {
            case .launching, .welcomeDisclosures: Welcome.headerTitle
            case .whoopHandover: Handover.headerTitle
            case .prepareBand: Prepare.headerTitle
            case .pairing: Pairing.headerTitle
            case .profileSetup: Profile.headerTitle
            case .appleHealth: Health.headerTitle
            case .notifications: Notifications.headerTitle
            case .sleepGoal: SleepNeedStep.headerTitle
            case .finish, .mainShell: Finish.headerTitle
            }
        }
    }

    public enum Welcome {
        public static let headerTitle = "Welcome"
        public static let title = "Your band, your data."
        public static let promise = "Loopr reads your WHOOP band over Bluetooth and does every calculation on this iPhone."
        public static let sectionTitle = "Before you start"
        public static let privateTitle = "Stays on this iPhone"
        public static let privateDetail = "No Loopr account or server. You choose when to export data or save it to Apple Health. This build does not send AI requests."
        public static let wellnessTitle = "Wellness, not medicine"
        public static let independentTitle = "Not made by WHOOP"
        public static let action = "Continue"
    }

    /// Getting the WHOOP app off the band.
    public enum Handover {
        public static let headerTitle = "The WHOOP app"
        public static let title = "Turn off the WHOOP app's Bluetooth"
        public static let detail = "The WHOOP app reconnects to your band in the background. Closing it only stops that until the phone restarts or you open WHOOP again. Switching off its Bluetooth access keeps it off, and the app stays installed."
        public static let sectionTitle = "Do this first"
        public static let bluetoothTitle = "Switch off WHOOP's Bluetooth access"
        public static let bluetoothDetail = "In Settings, open Privacy & Security, then Bluetooth, and turn WHOOP off. Done with WHOOP for good? You can delete the app instead."
        public static let openSettings = "Open Settings"
        public static let openSettingsNote = "Settings opens on Loopr's page. Go back to the main list to find Privacy & Security."
        public static let swipeTitle = "Swipe the WHOOP app away"
        public static let swipeDetail = "Swipe up from the bottom of the screen and flick WHOOP off the top. That drops the connection it has right now."
        public static let otherDeviceTitle = "WHOOP on another phone or iPad?"
        public static let otherDeviceDetail = "Do the same there. A WHOOP band connects to one phone at a time."
        public static let reverseNote = "No WHOOP app on this iPhone? Carry on. To use WHOOP again later, switch its Bluetooth access back on."
        public static let mockPath = "Privacy & Security › Bluetooth"
        public static let mockApp = "WHOOP"
        public static let mockCaption = "Turn this off"
        public static let action = "Continue"
        public static let later = "Set up my band later"
    }

    public enum Prepare {
        public static let headerTitle = "Pairing mode"
        public static let title = "Put your band in pairing mode"
        public static let detail = "The side light pulses blue when it's ready. Tapping can take 15 to 20 seconds."
        public static let sectionTitle = "How to"
        public static let offTitle = "Take it off"
        public static let offDetail = "Take the band off your wrist. Wait for the green lights underneath to go out."
        public static let tapTitle = "Tap until it pulses blue"
        public static let tapDetail = "Hold it by the sides and tap the top firmly with two fingers. Keep tapping until the side light pulses blue. Don't set it down while you tap."
        public static let newBandTitle = "New band, never paired?"
        public static let newBandDetail = "Slide on a battery pack that has charged for at least 15 minutes. The side light pulses blue."
        public static let heroCaption = "Side light pulses blue"
        public static let action = "The light is pulsing blue"
        public static let later = "Set up my band later"
    }

    public enum Pairing {
        public static let headerTitle = "Connect"
        public static let connect = "Connect band"
        public static let tryAgain = "Try again"
        public static let continueAction = "Continue"
        public static let later = "Set up my band later"
        public static let showSheet = "Show nearby bands"
        public static let sectionTitle = "While you connect"
        public static let timingTitle = "About 3 minutes"
        public static let timingDetail = "Pairing mode lasts about 3 minutes. If the light stops, tap the band again."
        public static let nearbyTitle = "Keep it close"
        public static let nearbyDetail = "Hold the band next to your iPhone until it connects."
        public static let helpTitle = "Band not in the list?"
        public static let helpTitleAfterFailure = "Before you try again"

        public static func helpTitle(for phase: OnboardingPairingPhase) -> String {
            if case .failed = phase { return helpTitleAfterFailure }
            return helpTitle
        }
        public static let helpIntro = "Pair here, not in the iPhone's Bluetooth settings. Then check these."
        public static let helpItems = [
            "The side light is pulsing blue. If it stopped, tap the band again.",
            "WHOOP's Bluetooth access is off, and the WHOOP app is swiped away.",
            "The band is within arm's reach of your iPhone."
        ]
        public static let bondRepairSectionTitle = "How to fix it"
        public static let bondRepairSteps = [
            "Open Settings, then Bluetooth.",
            "Tap the info button next to your WHOOP band, then Forget This Device.",
            "Come back here and tap Try again."
        ]
        public static let bondRepairWarning = "Forgetting removes the band from every device on your Apple Account. If you go back to the WHOOP app, it will need to pair again."
        public static let sharedLinkTitle = "Another app may be connected"
        public static let sharedLinkDetail = "iOS reports a second connection to your band from this iPhone. If that's the WHOOP app, switch off its Bluetooth access in Settings, under Privacy & Security, then Bluetooth."
        public static let supportedTitle = "Supported band"
        public static let stableTitle = "WHOOP 4.0"
        public static let stableDetail = "Loopr's stable pairing path is for WHOOP 4.0."
        public static let experimentalTitle = "Using a WHOOP 5.0 or MG?"
        public static let experimentalDetail = "Try pairing, battery readings, live heart rate and history sync. Each still needs testing on both models. Clock setting, alarms, haptics and firmware updates are unavailable."
        public static let experimentalSwitch = "Turn on experimental support"
        /// The name the iOS pairing sheet shows for the band.
        public static let pickerName = "WHOOP 4.0"

        public static func title(for phase: OnboardingPairingPhase) -> String {
            switch phase {
            case .idle: "Connect your band"
            case .confirmReady: "Is the light pulsing blue?"
            case .choosing: "Pick your band"
            case .connecting: "Connecting"
            case .connected: "Band connected"
            case .bluetoothOff: "Bluetooth is off"
            case .cancelled: "Pairing cancelled"
            case .notFound: "No band chosen"
            case .bondRepair: "Forget the old pairing"
            case .failed: "Pairing didn't finish"
            }
        }

        public static func detail(for phase: OnboardingPairingPhase) -> String {
            switch phase {
            case .idle:
                "iOS will list nearby bands. Pick yours. Loopr can only talk to the band you pick."
            case .confirmReady:
                "When it is, Loopr can show the bands nearby."
            case .choosing:
                "Choose your band in the sheet at the bottom of the screen."
            case .connecting:
                "Keep the band next to your iPhone. You can carry on with setup while it connects."
            case .connected:
                "Loopr is reading the history stored on your band."
            case .bluetoothOff:
                "Turn on Bluetooth in Control Center, then try again."
            case .cancelled:
                "Nothing was paired. Try again when the side light pulses blue."
            case .notFound:
                "The sheet closed before you picked a band. Check the side light, then try again."
            case .bondRepair:
                "Your iPhone kept an old pairing key that the band no longer accepts. Forget the band in Bluetooth settings, then pair again."
            case .failed(let reason):
                reason
            }
        }
    }

    public enum Profile {
        public static let headerTitle = "About you"
        public static let detail = "Age sets your heart rate zones and strain. Height, weight and sex tune calorie estimates. Leave anything blank and Loopr won't guess it."
        public static let youSection = "You"
        public static let bodySection = "Body"
        public static let nameTitle = "Name"
        public static let namePlaceholder = "Optional"
        public static let ageTitle = "Age"
        public static let sexTitle = "Sex"
        public static let unitsTitle = "Units"
        public static let heightTitle = "Height"
        public static let weightTitle = "Weight"
        public static let maxHeartRateTitle = "Estimated max heart rate"
        public static let maxHeartRateEmpty = "Add your age to see it"
        public static let maxHeartRateNote = "208 minus 0.7 × age (Tanaka). If Loopr records a higher peak from you, it uses that instead."
        public static let action = "Continue"

        public static func timeZone(_ label: String) -> String {
            "Time zone: \(label), from this iPhone."
        }
    }

    public enum Health {
        public static let headerTitle = "Apple Health"
        public static let title = "Share with Apple Health"
        public static let detail = "Loopr saves what it measures to Apple Health. It also reads what's already there, so your charts start with history."
        public static let writeOnlyDetail = "Loopr saves what it measures to Apple Health, so your other apps can use it too."
        public static let savesTitle = "Loopr saves"
        public static let readsTitle = "Loopr reads"
        public static let savesCaption = "Saves"
        public static let readsCaption = "Reads"
        public static let choiceNote = "iOS asks next, with a switch for each type. Change it any time in Settings or the Health app."
        public static let allow = "Connect Apple Health"
        public static let skip = "Not now"

        public static func detail(for request: OnboardingHealthRequest) -> String {
            request.importsHistory ? detail : writeOnlyDetail
        }

        /// The spoken summary of one list, for VoiceOver.
        public static func spokenList(_ title: String, _ types: [OnboardingHealthType]) -> String {
            "\(title): " + types.map { $0.name.lowercased() }.joined(separator: ", ")
        }
    }

    public enum Notifications {
        public static let headerTitle = "Notifications"
        public static let title = "What Loopr tells you"
        public static let detail = "A few alerts about workouts and your band. Anything about your heart stays off until you turn it on."
        public static let onSection = "On by default"
        public static let offSection = "Off until you turn them on"
        /// Two real notifications, for the illustration at the top.
        public static let sample = [
            (title: "Workout detected", detail: "Review the detected workout in Loopr."),
            (title: "Strap update", detail: "Open Device Center for details.")
        ]
        public static let sampleApp = "LOOPR"
        public static let sampleTime = "now"
        public static let allow = "Allow notifications"
        public static let skip = "Not now"

        public static func title(for group: OnboardingNotificationGroup) -> String {
            switch group {
            case .workouts: "Workouts"
            case .breathing: "Breathing"
            case .band: "Your band"
            case .offUntilChosen: "Heart alerts and reminders"
            }
        }

        public static func detail(for group: OnboardingNotificationGroup) -> String {
            switch group {
            case .workouts: "When Loopr detects a workout, and when one you recorded is saved."
            case .breathing: "When a breathing session ends."
            case .band: "Low battery, charging, a lost connection, or data that stopped syncing."
            case .offUntilChosen: "High and low heart rate, overnight checks, cardio fitness, and journal and cycle reminders. Turn them on in Settings."
            }
        }

        public static func symbol(for group: OnboardingNotificationGroup) -> String {
            switch group {
            case .workouts: "figure.run"
            case .breathing: "wind"
            case .band: "battery.50"
            case .offUntilChosen: "bell.slash"
            }
        }
    }

    /// The sleep need, named as Settings names it.
    public enum SleepNeedStep {
        public static let headerTitle = "Sleep need"
        public static let title = "How much sleep do you need?"
        /// Watson et al. 2015, AASM and Sleep Research Society consensus:
        /// adults should sleep 7 or more hours per night on a regular basis.
        public static let detail = "Today and Sleep measure each night against this. Most adults need 7 hours or more."
        public static let options: [Double] = [7, 7.5, 8, 8.5, 9]
        public static let ringCaption = "Sleep need"
        public static let save = "Save sleep need"
        public static let skip = "Skip"

        public static func skipNote(defaultHours: Double) -> String {
            "Skip keeps \(label(defaultHours)) hours. You can change it later in Settings, under Profile."
        }

        public static func label(_ hours: Double) -> String {
            hours.rounded() == hours ? "\(Int(hours))" : String(format: "%.1f", hours)
        }

        public static func ringText(_ hours: Double) -> String { "\(label(hours)) h" }
    }

    public enum Finish {
        public static let headerTitle = "Ready"
        public static let title = "You're set"
        public static let deferredTitle = "Your band comes next"
        public static let ringCaption = "Nights learned"
        public static let sectionTitle = "What happens next"
        public static let wearTitle = "Wear it tonight"
        public static let wearDetail = "Sleep, HRV and resting heart rate come from overnight data."
        public static let syncTitle = "The first sync takes a while"
        public static let syncDetail = "Your band holds days of history. Loopr reads it in the background while your iPhone is near the band. If you swipe Loopr away, reading stops until you open it again."
        public static let laterTitle = "Connect your band later"
        public static let laterDetail = "When your band is ready, tap Connect band on Today."
        public static let connectingTitle = "Your band is still connecting"
        public static let connectingDetail = "Keep it next to your iPhone. Today shows when it's connected."
        public static let refreshTitle = "Background App Refresh is off"
        public static let refreshDetail = "Loopr schedules its overnight syncs through it. Turn it on in Loopr's settings."
        public static let openSettings = "Open Settings"
        public static let action = "Open Loopr"

        public static func ringText(nights: Int) -> String { "0/\(nights)" }

        public static func baselineTitle(nights: Int) -> String {
            "Recovery after \(nights) nights"
        }

        public static func baselineDetail(nights: Int) -> String {
            "Loopr learns your usual from your first \(nights) nights, then scores each night against it. Today shows how many it has so far."
        }
    }

    public enum DataControls {
        public static let detail = "Each action asks you to confirm first."
    }
}

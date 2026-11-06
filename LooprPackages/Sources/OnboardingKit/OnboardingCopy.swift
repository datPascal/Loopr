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
        public static let title = "Your health data, on your iPhone."
        public static let promise = "Loopr puts sleep, training, food and blood tests into one daily view. It reads a WHOOP 4.0 band and Apple Health, and does every calculation on this iPhone."
        /// What works for someone with no band, said once, before they choose.
        public static let noBandLine = "No band yet? Food, fitness tests, your protocol and blood tests work without one. Apple Health adds steps, daylight and weight."
        public static let sectionTitle = "Your privacy"
        public static let accountTitle = "No account"
        public static let accountDetail = "Nothing to sign up for, and no Loopr server."
        public static let privateTitle = "Stays on this iPhone"
        public static let privateDetail = "Loopr stores your health data here. You choose when to export it or save it to Apple Health."
        public static let coachTitle = "Ask is off"
        public static let coachDetail = "It stays off until you add your own OpenAI or Claude key. Then it sends only what you approve."
        public static let goodToKnowTitle = "Good to know"
        public static let wellnessTitle = "Wellness, not medicine"
        public static let independentTitle = "Not made by WHOOP"
        /// The band path: the three band steps come next.
        public static let action = "I have a WHOOP band"
        /// The no-band path: straight to About you.
        public static let noBandAction = "Continue without a band"
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
        public static let headerTitle = "Your band"
        public static let title = "Get your band ready"
        public static let detail = "Two quick steps before you connect. About a minute."
        public static let sectionTitle = "Get your band ready"
        public static let whoopTitle = "Turn off WHOOP's Bluetooth"
        public static let whoopDetail = "The WHOOP app grabs the band in the background. In Settings, open Privacy & Security, then Bluetooth, and switch WHOOP off. Then swipe the WHOOP app away. Using WHOOP on an iPad too? Do the same there."
        public static let offTitle = "Take it off"
        public static let offDetail = "Take the band off your wrist. Wait for the green lights underneath to go out."
        public static let tapTitle = "Tap until it pulses blue"
        public static let tapDetail = "Take the band off your wrist. Hold it by the sides and tap the top firmly with two fingers until the side light pulses blue. This can take 15 to 20 seconds."
        public static let newBandTitle = "New band, never paired?"
        public static let newBandDetail = "Slide on a battery pack that has charged for at least 15 minutes. The side light pulses blue."
        public static let newBandNote = "New band that was never paired? Slide on a battery pack charged for at least 15 minutes and the side light pulses blue."
        public static let noWhoopNote = "No WHOOP app on this iPhone? Skip the first step. To use WHOOP again later, switch its Bluetooth back on."
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
        public static let detail = "Your birth year sets your real age and your heart rate zones. Sex picks the reference curves. Leave anything blank and Loopr won't guess it."
        public static let youSection = "You"
        public static let doneEditing = "Hide keyboard"
        public static let bodySection = "Body"
        public static let moreTitle = "More about you"
        public static let moreSummary = "Name, units, height and weight. All optional."
        public static let nameTitle = "Name"
        public static let namePlaceholder = "Optional"
        public static let birthYearTitle = "Birth year"
        public static let birthYearPlaceholder = "e.g. 1990"
        /// Beside the year: the age it gives, "36 yrs".
        public static func ageCaption(_ age: Int) -> String { "\(age) yrs" }
        public static let sexTitle = "Sex"
        public static let unitsTitle = "Units"
        public static let heightTitle = "Height"
        public static let weightTitle = "Weight"
        public static let maxHeartRateTitle = "Estimated max heart rate"
        public static let maxHeartRateEmpty = "Add your birth year to see it"
        public static let maxHeartRateNote = "208 minus 0.7 × age (Tanaka). If Loopr records a higher peak from you, it uses that instead."
        public static let action = "Continue"

        public static func timeZone(_ label: String) -> String {
            "Time zone: \(label), from this iPhone."
        }
    }

    public enum Health {
        public static let headerTitle = "Apple Health"
        public static let title = "Read from Apple Health"
        public static let detail = "Loopr reads what's already in Apple Health, so your charts start with your history. It can also save what it measures there, for your other apps."
        public static let writeOnlyDetail = "Loopr can save what it measures to Apple Health, so your other apps can use it too."
        public static let savesTitle = "Loopr saves"
        public static let readsTitle = "Loopr reads"
        public static let savesCaption = "Saves"
        public static let readsCaption = "Reads"
        public static let choiceNote = "iOS asks next, with a switch for each type. You can allow reading and leave saving off. Change it any time in Settings or the Health app."
        public static let allow = "Connect Apple Health"
        public static let skip = "Not now"

        public static let writeOnlyTitle = "Save to Apple Health"

        public static func title(for request: OnboardingHealthRequest) -> String {
            request.importsHistory ? title : writeOnlyTitle
        }

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
        public static let noBandDetail = "Loopr tells you when a workout or breathing session is saved, and sends the reminders you set. Heart alerts stay off until you turn them on."
        public static let onSection = "On by default"
        public static let offSection = "Off until you turn them on"
        /// Two real notifications, for the illustration at the top. The
        /// second matches the band notification the app posts.
        public static let sample = [
            (title: "Workout detected", detail: "Review the detected workout in Loopr."),
            (title: "Band update", detail: "Open Loopr's Settings, then Band.")
        ]
        /// Without a band: an evening rule reminder quoting the person's own
        /// words (ProtocolRuleReminder), and a saved workout.
        public static let noBandSample = [
            (title: "Screens off", detail: "You wrote this morning: \"The news can wait.\""),
            (title: "Workout saved", detail: "Your workout summary is ready.")
        ]

        public static func detail(on path: OnboardingPath) -> String {
            path == .noBand ? noBandDetail : detail
        }

        public static func sample(on path: OnboardingPath) -> [(title: String, detail: String)] {
            path == .noBand ? noBandSample : sample
        }

        /// The groups listed as on by default. A band alert can never fire
        /// without a band, so that path lists reminders instead.
        public static func onGroups(on path: OnboardingPath) -> [OnboardingNotificationGroup] {
            let groups: [OnboardingNotificationGroup] = path == .noBand
                ? [.workouts, .breathing, .reminders]
                : [.workouts, .breathing, .band]
            return groups.filter { !$0.families.isEmpty }
        }
        public static let sampleApp = "LOOPR"
        public static let sampleTime = "now"
        public static let allow = "Allow notifications"
        public static let skip = "Not now"

        public static func title(for group: OnboardingNotificationGroup) -> String {
            switch group {
            case .workouts: "Workouts"
            case .breathing: "Breathing"
            case .band: "Your band"
            case .reminders: "Reminders you set"
            case .offUntilChosen: "Heart alerts and reminders"
            }
        }

        /// Detection reads the band's heart rate, so without one only saved
        /// workouts notify.
        public static func detail(for group: OnboardingNotificationGroup, on path: OnboardingPath) -> String {
            if path == .noBand, group == .workouts { return "When a workout you recorded in Loopr is saved." }
            return detail(for: group)
        }

        public static func detail(for group: OnboardingNotificationGroup) -> String {
            switch group {
            case .workouts: "When Loopr detects a workout, and when one you recorded is saved."
            case .breathing: "When a breathing session ends."
            case .band: "Low battery, charging, a lost connection, or data that stopped syncing."
            case .reminders: "Reminders from Ask, a Patterns test, a supplement or medication stack, or an evening rule. Each arrives at the time you chose, even in quiet hours."
            case .offUntilChosen: "High and low heart rate, overnight checks, cardio fitness, and check-in and cycle reminders. Turn them on in Settings."
            }
        }

        public static func symbol(for group: OnboardingNotificationGroup) -> String {
            switch group {
            case .workouts: "figure.run"
            case .breathing: "wind"
            case .band: "battery.50"
            case .reminders: "bell"
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
        public static let detail = "Today measures each night against this. Most adults need 7 hours or more."
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
        public static let deferredTitle = "You're set"
        public static let ringCaption = "Nights learned"
        public static let sectionTitle = "What comes next"
        public static let wearTitle = "Wear it tonight"
        public static let wearDetail = "Keep your iPhone near the band. The first sync reads days of history and can take a while."
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

        /// Without a band: what to do first, and how a band joins later.
        public static let noBandSectionTitle = "Where to start"
        public static let mealTitle = "Log a meal"
        public static let mealDetail = "Take a photo of your plate or scan a barcode in Food."
        public static let protocolTitle = "Pick a protocol"
        public static let protocolDetail = "Start one from a template in Protocol. Today lists its rules and ticks the ones Food, Fitness and Apple Health can check."
        public static let healthTitle = "Steps and daylight from Apple Health"
        public static let healthDetail = "Today shows them once you allow Loopr to read them. Change that any time in Settings, under Apple Health."
        public static let addBandTitle = "Add a band later"
        public static let addBandDetail = "Got a WHOOP 4.0? Tap Connect band on Today, or open Settings, then Band."

        /// With a band, the longevity side: it needs no nights of wear (ICP R2-UPG-9).
        public static let longevityTitle = "Food, workouts and blood tests work from today"
        public static let longevityDetail = "They need no band. Log a meal in Food, start a workout in Fitness, or add a lab report in Data."

        public static func ringText(nights: Int) -> String { "0/\(nights)" }

        public static func baselineTitle(nights: Int) -> String {
            "Recovery after \(nights) nights"
        }

        public static func baselineDetail(nights: Int) -> String {
            "Recovery appears after \(nights) nights, once Loopr knows your usual."
        }
    }

    public enum DataControls {
        public static let detail = "Each action asks you to confirm first."
    }
}

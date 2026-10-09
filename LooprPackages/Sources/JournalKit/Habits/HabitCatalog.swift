import Foundation

public enum HabitCategory: String, Codable, CaseIterable, Sendable {
    case evening = "Evening"
    case sleepEnvironment = "Sleep environment"
    case nutrition = "Nutrition"
    case substances = "Substances"
    case recovery = "Recovery"
    case stress = "Stress"
    case context = "Context"
}

public struct HabitCatalogItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let category: HabitCategory
    public let name: String
    public let question: String

    public init(id: String, category: HabitCategory, name: String, question: String) {
        self.id = id
        self.category = category
        self.name = name
        self.question = question
    }
}

public enum HabitCatalog {
    public static let items: [HabitCatalogItem] = [
        .init(id: "short_video_before_bed", category: .evening, name: "Short videos before bed", question: "Scrolled short videos in the final hour before sleep?"),
        .init(id: "screen_before_bed", category: .evening, name: "Screen before bed", question: "Used a screen in the final hour before sleep?"),
        .init(id: "worked_late", category: .evening, name: "Worked late", question: "Worked in the final two hours before sleep?"),
        .init(id: "read_before_bed", category: .evening, name: "Read before bed", question: "Read before sleep?"),
        .init(id: "meditated", category: .evening, name: "Meditation", question: "Meditated or did breathwork?"),
        .init(id: "stretched", category: .evening, name: "Stretching", question: "Stretched before sleep?"),
        .init(id: "dark_room", category: .sleepEnvironment, name: "Dark room", question: "Slept in a dark room?"),
        .init(id: "sleep_mask", category: .sleepEnvironment, name: "Sleep mask", question: "Used a sleep mask?"),
        .init(id: "earplugs", category: .sleepEnvironment, name: "Earplugs", question: "Used earplugs?"),
        .init(id: "white_noise", category: .sleepEnvironment, name: "White noise", question: "Used white noise?"),
        .init(id: "warm_bedroom", category: .sleepEnvironment, name: "Warm bedroom", question: "Bedroom felt warmer than usual?"),
        .init(id: "shared_bed", category: .sleepEnvironment, name: "Shared bed", question: "Shared the bed?"),
        .init(id: "away_from_home", category: .sleepEnvironment, name: "Away from home", question: "Slept away from home?"),
        .init(id: "late_caffeine", category: .nutrition, name: "Late caffeine", question: "Had caffeine after 2 p.m.?"),
        .init(id: "alcohol", category: .substances, name: "Alcohol", question: "Drank alcohol?"),
        .init(id: "nicotine", category: .substances, name: "Nicotine", question: "Used nicotine?"),
        .init(id: "cannabis", category: .substances, name: "Cannabis", question: "Used cannabis?"),
        .init(id: "late_meal", category: .nutrition, name: "Late meal", question: "Ate a meal in the final three hours before sleep?"),
        .init(id: "late_sugary_snack", category: .nutrition, name: "Late sugary snack", question: "Had a sugary snack in the final three hours before sleep?"),
        .init(id: "hydration_target", category: .nutrition, name: "Hydration target", question: "Met your hydration target?"),
        .init(id: "late_intense_exercise", category: .recovery, name: "Late intense exercise", question: "Did intense exercise in the final three hours before sleep?"),
        .init(id: "napped", category: .recovery, name: "Nap", question: "Took a nap?"),
        .init(id: "sauna", category: .recovery, name: "Sauna", question: "Used a sauna?"),
        .init(id: "cold_exposure", category: .recovery, name: "Cold exposure", question: "Did deliberate cold exposure?"),
        .init(id: "outdoor_daylight", category: .recovery, name: "Outdoor daylight", question: "Spent at least 30 minutes outdoors in daylight?"),
        .init(id: "morning_sunlight", category: .recovery, name: "Morning sunlight", question: "Got outdoor light within an hour of waking?"),
        .init(id: "high_mental_stress", category: .stress, name: "High mental stress", question: "Had a high-stress day?"),
        .init(id: "travel_day", category: .context, name: "Travel day", question: "Traveled across time zones?")
    ]

    public static let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

    public static func search(_ query: String) -> [HabitCatalogItem] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return items }
        return items.filter {
            normalize([$0.name, $0.question, $0.category.rawValue].joined(separator: " ")).contains(needle)
        }
    }

    public static func exactMatch(_ value: String) -> HabitCatalogItem? {
        let needle = normalize(value)
        return items.first { normalize($0.name) == needle || normalize($0.question) == needle }
    }

    public static func hasNearDuplicate(in catalogIDs: Set<String>) -> Bool {
        catalogIDs.contains("short_video_before_bed") && catalogIDs.contains("screen_before_bed")
    }

    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

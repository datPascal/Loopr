import Foundation

public struct ParityFieldDifference: Sendable, Equatable {
    public let field: String
    public let category: String
    public let expected: String
    public let actual: String
    public let delta: Double?
    public let passed: Bool
    public init(field: String, category: String, expected: String, actual: String, delta: Double?, passed: Bool) {
        self.field = field; self.category = category; self.expected = expected; self.actual = actual; self.delta = delta; self.passed = passed
    }
}

public struct ParityReport: Sendable, Equatable {
    public let passed: Bool
    public let differences: [ParityFieldDifference]
    public var humanReadable: String {
        if differences.isEmpty { return "PASS parity: all fields match" }
        return differences.map { difference in
            let delta = difference.delta.map { " delta=\($0)" } ?? ""
            return "\(difference.passed ? "PASS" : "FAIL") \(difference.field) [\(difference.category)] expected=\(difference.expected) actual=\(difference.actual)\(delta)"
        }.joined(separator: "\n")
    }
}

public struct ParityToleranceManifest: Sendable, Equatable {
    public struct Rule: Sendable, Equatable {
        public let category: String
        public let absolute: Double?
        public let relative: Double?
        public let absoluteFloor: Double?
        public let decimals: Int?
        public init(category: String, absolute: Double? = nil, relative: Double? = nil, absoluteFloor: Double? = nil, decimals: Int? = nil) {
            self.category = category; self.absolute = absolute; self.relative = relative; self.absoluteFloor = absoluteFloor; self.decimals = decimals
        }
    }

    public let rules: [String: Rule]
    public let fields: [String: String]

    public init(rules: [String: Rule], fields: [String: String]) {
        self.rules = rules; self.fields = fields
    }

    public static let defaults = ParityToleranceManifest(
        rules: [
            "exact": Rule(category: "exact"),
            "canonical-rounded": Rule(category: "canonical-rounded", decimals: 0),
            "float-primitive": Rule(category: "float-primitive", absolute: 1e-9),
            "normalized-score": Rule(category: "normalized-score", absolute: 1e-6),
            "spectral-iterative": Rule(category: "spectral-iterative", absolute: 1e-8, relative: 1e-5, absoluteFloor: 1e-8)
        ],
        fields: [:]
    )

    public static func load(data: Data) throws -> ParityToleranceManifest {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NSError(domain: "Parity", code: 1, userInfo: [NSLocalizedDescriptionKey: "manifest root is not an object"]) }
        var result = defaults
        if let categories = object["categories"] as? [String: Any] {
            var rules = result.rules
            for (name, raw) in categories {
                guard let category = raw as? [String: Any] else { continue }
                let absolute = (category["absolute"] as? NSNumber)?.doubleValue
                let relative = (category["relative"] as? NSNumber)?.doubleValue
                let floor = (category["absolute_floor"] as? NSNumber)?.doubleValue
                let decimals = (category["decimals"] as? NSNumber)?.intValue
                rules[name] = Rule(category: name, absolute: absolute, relative: relative, absoluteFloor: floor, decimals: decimals)
            }
            result = ParityToleranceManifest(rules: rules, fields: result.fields)
        }
        if let entries = object["entries"] as? [[String: Any]] {
            var fields = result.fields
            for entry in entries {
                if let field = entry["field"] as? String, let category = entry["category"] as? String { fields[field] = category }
            }
            result = ParityToleranceManifest(rules: result.rules, fields: fields)
        }
        return result
    }

    public func rule(for field: String, expected: Any?, actual: Any?) -> Rule {
        if let category = fields[field], let rule = rules[category] { return rule }
        // Array members are flattened as `field[0]`; wildcard entries keep the
        // manifest auditable without enumerating every fixture's cardinality.
        for pattern in fields.keys.sorted(by: { $0.count > $1.count }) where pattern.contains("[*]") {
            guard wildcard(pattern: pattern, field: field), let category = fields[pattern], let rule = rules[category] else { continue }
            return rule
        }
        // Unlisted fields are intentionally exact. This is a fail-closed
        // default, not an epsilon that could hide a missing manifest entry.
        if expected is Bool || actual is Bool || expected is String || actual is String || expected is NSNull || actual is NSNull { return rules["exact"]! }
        return rules["exact"]!
    }

    private func wildcard(pattern: String, field: String) -> Bool {
        guard let marker = pattern.range(of: "[*]") else { return false }
        let prefix = String(pattern[..<marker.lowerBound])
        let suffix = String(pattern[marker.upperBound...])
        guard field.hasPrefix(prefix), field.hasSuffix(suffix) else { return false }
        let start = field.index(field.startIndex, offsetBy: prefix.count)
        let end = field.index(field.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return false }
        let member = String(field[start..<end])
        guard member.count >= 3, member.first == "[", member.last == "]" else { return false }
        return Int(member.dropFirst().dropLast()) != nil
    }
}

public enum AnalyticsParityComparator {
    public static func compare(expected: Data, actual: Data, manifest: ParityToleranceManifest = .defaults) throws -> ParityReport {
        let expectedObject = try JSONSerialization.jsonObject(with: expected)
        let actualObject = try JSONSerialization.jsonObject(with: actual)
        var fields: [String: (Any?, Any?)] = [:]
        flatten(expectedObject, path: "", into: &fields, side: 0)
        flatten(actualObject, path: "", into: &fields, side: 1)
        var differences: [ParityFieldDifference] = []
        for field in fields.keys.sorted() {
            let pair = fields[field]!
            let rule = manifest.rule(for: field, expected: pair.0, actual: pair.1)
            let (passed, delta) = compareValue(pair.0, pair.1, rule: rule)
            // Keep passing fields in the report as well as failures. CI output
            // is an auditable field-by-field record, rather than only a terse
            // failure list; missing fields remain failures below.
            differences.append(ParityFieldDifference(field: field, category: rule.category, expected: stringify(pair.0), actual: stringify(pair.1), delta: delta, passed: passed))
        }
        return ParityReport(passed: differences.allSatisfy(\.passed), differences: differences)
    }

    private static func flatten(_ value: Any, path: String, into fields: inout [String: (Any?, Any?)], side: Int) {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                flatten(dictionary[key] as Any, path: childPath, into: &fields, side: side)
            }
            return
        }
        if let array = value as? [Any] {
            if array.isEmpty { set(value, path: path, into: &fields, side: side); return }
            for (index, child) in array.enumerated() { flatten(child, path: "\(path)[\(index)]", into: &fields, side: side) }
            return
        }
        set(value, path: path, into: &fields, side: side)
    }

    private static func set(_ value: Any?, path: String, into fields: inout [String: (Any?, Any?)], side: Int) {
        var pair = fields[path] ?? (nil, nil)
        if side == 0 { pair.0 = value } else { pair.1 = value }
        fields[path] = pair
    }

    private static func compareValue(_ expected: Any?, _ actual: Any?, rule: ParityToleranceManifest.Rule) -> (Bool, Double?) {
        guard let expected, let actual else { return (expected == nil && actual == nil, nil) }
        if expected is NSNull || actual is NSNull {
            return (expected is NSNull && actual is NSNull, nil)
        }
        if let expectedNumber = number(expected), let actualNumber = number(actual) {
            switch rule.category {
            case "canonical-rounded":
                let decimals = rule.decimals ?? 0
                let factor = pow(10, Double(decimals))
                return ((expectedNumber * factor).rounded() == (actualNumber * factor).rounded(), actualNumber - expectedNumber)
            case "float-primitive", "normalized-score":
                let allowed = rule.absolute ?? 0
                return (abs(actualNumber - expectedNumber) <= allowed, actualNumber - expectedNumber)
            case "spectral-iterative":
                let floor = rule.absoluteFloor ?? 0
                let allowed = max(floor, (rule.relative ?? 0) * max(abs(expectedNumber), abs(actualNumber)))
                return (abs(actualNumber - expectedNumber) <= allowed, actualNumber - expectedNumber)
            default:
                return (actualNumber == expectedNumber, actualNumber - expectedNumber)
            }
        }
        if let expectedArray = expected as? [Any], let actualArray = actual as? [Any] { return (expectedArray.count == actualArray.count && zip(expectedArray, actualArray).allSatisfy { compareValue($0.0, $0.1, rule: rule).0 }, nil) }
        if let expectedString = expected as? String, let actualString = actual as? String { return (expectedString == actualString, nil) }
        if let expectedBool = expected as? Bool, let actualBool = actual as? Bool { return (expectedBool == actualBool, nil) }
        return (false, nil)
    }

    private static func number(_ value: Any) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "<missing>" }
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        if let value = value as? Bool { return value ? "true" : "false" }
        return String(describing: value)
    }
}

public enum AnalyticsParityRunner {
    public static func run(inputData: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: inputData) as? [String: Any] else { throw NSError(domain: "Parity", code: 3, userInfo: [NSLocalizedDescriptionKey: "fixture root must be an object"]) }
        let output = try run(input: object)
        return try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func run(input: [String: Any]) throws -> [String: Any] {
        guard let metric = input["metric"] as? String else { throw NSError(domain: "Parity", code: 4, userInfo: [NSLocalizedDescriptionKey: "fixture.metric is required"]) }
        switch metric {
        case "strain":
            let method = input["method"] as? String ?? "edwards"
            let source = (input["hr_max_source"] as? String) == "measured" ? HRMaxSource.measured : HRMaxSource.agePredicted
            let result = ActivityAnalytics.strain(
                hr: try numbers(input["hr"], name: "hr"),
                timestamps: try numbers(input["timestamps"], name: "timestamps"),
                restingHR: try optionalNumber(input["resting_hr"], name: "resting_hr"),
                maxHR: try optionalNumber(input["max_hr"], name: "max_hr"),
                source: source,
                method: method
            )
            let note = result.present
                ? "\(method == "banister" ? "Banister" : "Edwards") TRIMP → 0–100 strain (100·ln(TRIMP+1)/ln(7201)); wrist-HR ESTIMATE, not clinical"
                : "strain needs ≥600 HR samples (or ≥20 spanning ≥600 s) and HRmax>RHR"
            return metricMap(value: result.value?.strain, confidence: result.present ? 0.6 : 0, tier: "ESTIMATE", inputs: ["hr_series", "resting_hr", "max_hr"], note: note, present: result.present, algorithmVersion: "ana05.activity.v1")
        case "strainScoreMetric":
            let trimp = try optionalNumber(input["trimp"], name: "trimp")
            guard let trimp, trimp >= 0 else {
                return metricMap(value: nil, confidence: 0, tier: "ESTIMATE", inputs: ["trimp"], note: "no TRIMP available for a strain score", present: false, algorithmVersion: "ana05.strain.v1")
            }
            let value = min(21, log(trimp + 1) / log(1.5))
            return metricMap(value: value, confidence: 0.6, tier: "ESTIMATE", inputs: ["trimp"], note: "headline 0–21 strain = log-squash of raw TRIMP (min(21, ln(trimp+1)/ln(1.5))); wrist-HR estimate", present: true, algorithmVersion: "ana05.strain.v1")
        case "correctRr", "rrCorrection":
            let result = RRQuality.correct(
                try numbers(input["rr_ms"] ?? input["intervals_ms"], name: "rr_ms"),
                alpha: try optionalNumber(input["alpha"], name: "alpha") ?? 5.2,
                windowBeats: try optionalInt(input["window_beats"], name: "window_beats") ?? 91,
                minimumThresholdMilliseconds: try optionalNumber(input["min_threshold_ms"], name: "min_threshold_ms") ?? 100
            )
            return ["nn_ms": result.normalIntervalsMilliseconds.map(AnalyticsMath.round6), "nn_times_ms": result.normalTimesMilliseconds.map(AnalyticsMath.round6), "classes": result.classes.map(\.rawValue), "clean_fraction": AnalyticsMath.round6(result.cleanFraction), "dropped_count": result.droppedCount, "corrected_count": result.correctedCount, "present": !result.normalIntervalsMilliseconds.isEmpty, "algorithm_version": result.algorithmVersion]
        case "rrQualityGate":
            let result = RRQuality.gated(
                try numbers(input["rr_ms"] ?? input["intervals_ms"], name: "rr_ms"),
                alpha: try optionalNumber(input["alpha"], name: "alpha") ?? 5.2,
                windowBeats: try optionalInt(input["window_beats"], name: "window_beats") ?? 91,
                minimumThresholdMilliseconds: try optionalNumber(input["min_threshold_ms"], name: "min_threshold_ms") ?? 100,
                minimumCleanFraction: try optionalNumber(input["min_clean_fraction"], name: "min_clean_fraction") ?? RRQuality.minimumMetricCleanFraction,
                minimumIntervals: try optionalInt(input["min_intervals"], name: "min_intervals") ?? RRQuality.minimumMetricIntervals
            )
            return metricMap(value: result.value.map(rrQualityGateMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "ppgTrust":
            let result = PPGQuality.trust(try numbers(input["ppg"] ?? input["ppg_window"], name: "ppg"), heartRate: try number(input["hr_bpm"], name: "hr_bpm"), minimumSkewness: try optionalNumber(input["skew_min"], name: "skew_min") ?? -0.1)
            return ["trusted": result.trusted, "skewness": AnalyticsMath.round6(result.skewness), "reasons": result.reasons, "present": result.trusted, "algorithm_version": result.algorithmVersion]
        case "robustBaseline":
            let values = try numbers(input["values"], name: "values")
            let result = BaselineDerivation.robust(values, minimumValid: (input["min_valid"] as? NSNumber)?.intValue ?? 3)
            return ["center": result.center.map(AnalyticsMath.round6) ?? NSNull(), "scale": result.scale.map(AnalyticsMath.round6) ?? NSNull(), "n_valid": result.validCount, "n_window": result.windowCount, "sufficient": result.sufficient, "present": result.sufficient, "algorithm_version": AnalyticsAlgorithmVersion.baseline]
        case "gapAwareEwma":
            let result = Baselines.gapAwareEWMA(timesMilliseconds: try numbers(input["times_ms"], name: "times_ms"), values: try numbers(input["values"], name: "values"), halfLifeMilliseconds: try number(input["half_life_ms"], name: "half_life_ms"), maximumGapMilliseconds: (input["max_gap_ms"] as? NSNumber)?.doubleValue ?? 0)
            return ["points": result.map { ["value": AnalyticsMath.round6($0.value), "gap": $0.isGap] }, "present": !result.isEmpty, "algorithm_version": AnalyticsAlgorithmVersion.baseline]
        case "baselineUpdate":
            let configuration = try baselineConfiguration(input["configuration"] as? String ?? "hrv")
            let state: BaselineState?
            if let raw = input["state"] as? [String: Any] {
                state = try decodeBaselineState(raw)
            } else {
                state = nil
            }
            let value = input.keys.contains("value") ? (input["value"] is NSNull ? nil : try number(input["value"], name: "value")) : nil
            let result = Baselines.update(state, value: value, configuration: configuration)
            return baselineMap(result)
        case "baselineFoldHistory":
            let configuration = try baselineConfiguration(input["configuration"] as? String ?? "hrv")
            guard let values = input["values"] as? [Any] else { throw NSError(domain: "Parity", code: 8, userInfo: [NSLocalizedDescriptionKey: "values must be an array"]) }
            let nullable = try values.map { raw -> Double? in
                if raw is NSNull { return nil }
                return try number(raw, name: "values")
            }
            let result = Baselines.foldHistory(nullable, configuration: configuration)
            return baselineMap(result)
        case "baselineFoldPrior":
            let configuration = try baselineConfiguration(input["configuration"] as? String ?? "hrv")
            guard let targetString = input["target_day"] as? String,
                  let targetDay = ISO8601DateFormatter().date(from: targetString),
                  let rawSamples = input["samples"] as? [[String: Any]] else {
                throw NSError(domain: "Parity", code: 11, userInfo: [NSLocalizedDescriptionKey: "invalid dated baseline fixture"])
            }
            let samples = try rawSamples.map { raw -> DatedBaselineSample in
                guard let dayString = raw["day"] as? String,
                      let day = ISO8601DateFormatter().date(from: dayString) else {
                    throw NSError(domain: "Parity", code: 12, userInfo: [NSLocalizedDescriptionKey: "invalid baseline sample day"])
                }
                let value = raw["value"] is NSNull ? nil : try number(raw["value"], name: "sample.value")
                return DatedBaselineSample(day: day, value: value)
            }
            let result = Baselines.foldHistoryBefore(samples, targetDay: targetDay, configuration: configuration)
            return baselineMap(result)
        case "hrvTime":
            let result = HRVTime.derive(try numbers(input["nn_ms"] ?? input["rr_ms"], name: "nn_ms"), beatTimesMilliseconds: try optionalNumbers(input["nn_times_ms"], name: "nn_times_ms"))
            return metricMap(value: result.value.map(hrvTimeMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "nocturnalRmssd":
            let result = HRVTime.nocturnalRMSSD(
                try numbers(input["nn_ms"], name: "nn_ms"),
                beatTimesMilliseconds: try numbers(input["nn_times_ms"], name: "nn_times_ms"),
                windowMilliseconds: try optionalNumber(input["window_ms"], name: "window_ms") ?? 300_000,
                minimumBeatsPerWindow: try optionalInt(input["min_beats_per_window"], name: "min_beats_per_window") ?? 5,
                stageMaskPerSecond: try optionalBools(input["stage_mask_per_sec"], name: "stage_mask_per_sec")
            )
            return metricMap(value: result.value.map(AnalyticsMath.round6), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "sleepSessionWindowedRmssd":
            let result = HRVTime.sleepSessionWindowedRMSSD(
                rrMilliseconds: try numbers(input["rr_ms"], name: "rr_ms"),
                rrTimestampsMilliseconds: try numbers(input["rr_ts_ms"], name: "rr_ts_ms"),
                startSeconds: try int(input["start_sec"], name: "start_sec"),
                endSeconds: try int(input["end_sec"], name: "end_sec"),
                windowSeconds: try optionalInt(input["window_sec"], name: "window_sec") ?? 300
            )
            return metricMap(value: result.value.map(AnalyticsMath.round6), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "hrvFreq":
            let result = HRVFrequency.derive(
                intervals: try numbers(input["nn_ms"], name: "nn_ms"),
                beatTimesMilliseconds: try numbers(input["nn_times_ms"], name: "nn_times_ms"),
                artifactFraction: try number(input["artifact_fraction"], name: "artifact_fraction"),
                hfArtifactGate: try optionalNumber(input["hf_artifact_gate"], name: "hf_artifact_gate") ?? 0.15,
                gridPoints: try optionalInt(input["grid_points"], name: "grid_points") ?? 600
            )
            return metricMap(value: result.value.map(hrvFrequencyMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "nocturnalRhr":
            let result = NocturnalMetrics.restingHeartRate(try numbers(input["hr"], name: "hr"), windowSamples: (input["window_samples"] as? NSNumber)?.intValue ?? 1_800, minimumCoverage: (input["min_coverage"] as? NSNumber)?.doubleValue ?? 0.9)
            return metricMap(value: result.value.map(nocturnalMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "dailyNocturnalRhr":
            guard let localDay = input["local_day"] as? String,
                  let timeZoneID = input["time_zone"] as? String,
                  let rawSamples = input["samples"] as? [[String: Any]] else {
                throw NSError(domain: "Parity", code: 18, userInfo: [NSLocalizedDescriptionKey: "daily nocturnal fixture requires local_day, time_zone, and samples"])
            }
            let samples = try rawSamples.map { raw -> HRSample in
                let timestamp = try number(raw["ts_ms"] ?? raw["timestamp_ms"], name: "sample.ts_ms")
                let bpm = try number(raw["bpm"], name: "sample.bpm")
                return HRSample(timestampMilliseconds: timestamp, bpm: bpm)
            }
            let result = NocturnalMetrics.dailyRestingHeartRate(
                samples: samples,
                localDay: localDay,
                timeZoneID: timeZoneID,
                windowSamples: (input["window_samples"] as? NSNumber)?.intValue ?? 1_800,
                minimumCoverage: (input["min_coverage"] as? NSNumber)?.doubleValue ?? 0.9
            )
            return metricMap(value: result.value.map(dailyNocturnalMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "hrDip":
            let result = NocturnalMetrics.heartRateDip(daySamples: try numbers(input["day_hr"], name: "day_hr"), nightSamples: try numbers(input["night_hr"], name: "night_hr"), minimumSamples: (input["min_samples"] as? NSNumber)?.intValue ?? NocturnalMetrics.minimumDipSamples)
            return metricMap(value: result.value.map(dipMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "rsaRespRate":
            let result = Respiration.rsaRate(
                intervals: try numbers(input["nn_ms"], name: "nn_ms"),
                beatTimesMilliseconds: try numbers(input["nn_times_ms"], name: "nn_times_ms"),
                artifactFraction: try number(input["artifact_fraction"], name: "artifact_fraction"),
                agreementBPM: try optionalNumber(input["agree_brpm"], name: "agree_brpm") ?? 3,
                maximumArtifactFraction: try optionalNumber(input["max_artifact"], name: "max_artifact") ?? 0.3
            )
            return metricMap(value: result.value.map(respiratoryMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "riivRespRate":
            let result = Respiration.riivRate(adc: try numbers(input["adc"], name: "adc"), timestampsSeconds: try numbers(input["ts_sec"], name: "ts_sec"), validFraction: (input["valid_fraction"] as? NSNumber)?.doubleValue ?? 1)
            return metricMap(value: result.value.map(respiratoryMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "fuseRespRate":
            let rsa = try decodeRespMetric(input["rsa"], label: "rsa")
            let riiv = try decodeRespMetric(input["riiv"], label: "riiv")
            let result = Respiration.fuse(rsa: rsa, riiv: riiv, disagreementBPM: try optionalNumber(input["sd_gate_brpm"], name: "sd_gate_brpm") ?? 5)
            return metricMap(value: result.value.map(fusedRespirationMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "breathingRateVariability":
            let result = Respiration.variability(try numbers(input["brpm"], name: "brpm"))
            return metricMap(value: result.value.map(brvMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: result.inputsUsed, note: result.note, present: result.present, algorithmVersion: result.algorithmVersion)
        case "sleepCardioClassify":
            let features = SleepCardioEpochFeatures(
                motion: try numbers(input["motion"], name: "motion"),
                heartRate: try numbers(input["heart_rate"] ?? input["hr"], name: "heart_rate"),
                heartRateSD: try numbers(input["heart_rate_sd"] ?? input["hr_sd"], name: "heart_rate_sd"),
                rmssd: try numbers(input["rmssd"], name: "rmssd"),
                lfHF: try numbers(input["lf_hf"] ?? input["lfhf"], name: "lf_hf"),
                rk: try numbers(input["rk"], name: "rk"),
                sdnn: try numbers(input["sdnn"], name: "sdnn")
            )
            let epoch = try optionalInt(input["epoch_seconds"], name: "epoch_seconds") ?? 30
            let result = SleepCardioStager.classify(features, epochSeconds: epoch)
            return metricMap(value: result.value.map(sleepCardioMap), confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: ["cardio_epoch_features", "hr_1hz"], note: result.present ? "transparent cardio stager: motion + HR + robust RR axes; wrist estimate, not PSG" : (result.note ?? "too few epochs for cardiorespiratory staging"), present: result.present, algorithmVersion: "ana03.sleep.v1")
        case "sleepSegmentation":
            let rawAcceleration = try dictionaryArray(input["acceleration"], name: "acceleration")
            let rawHeartRate = try dictionaryArray(input["heart_rate"], name: "heart_rate")
            let rawRR = try dictionaryArray(input["rr"], name: "rr")
            let timeZoneIdentifier = try string(input["time_zone_identifier"], name: "time_zone_identifier")
            guard TimeZone(identifier: timeZoneIdentifier) != nil else {
                throw NSError(domain: "Parity", code: 45, userInfo: [NSLocalizedDescriptionKey: "unresolvable IANA time_zone_identifier: \(timeZoneIdentifier)"])
            }
            let acceleration = try rawAcceleration.map { raw in
                SleepAccelerationSample(
                    timestamp: try number(raw["timestamp"], name: "acceleration.timestamp"),
                    x: try number(raw["x"], name: "acceleration.x"),
                    y: try number(raw["y"], name: "acceleration.y"),
                    z: try number(raw["z"], name: "acceleration.z"),
                    valid: raw["valid"] as? Bool ?? true
                )
            }
            let heartRate = try rawHeartRate.map { raw in
                SleepHeartRateSample(
                    timestamp: try number(raw["timestamp"], name: "heart_rate.timestamp"),
                    bpm: try number(raw["bpm"], name: "heart_rate.bpm"),
                    valid: raw["valid"] as? Bool ?? true
                )
            }
            let rr = try rawRR.map { raw in
                SleepRRInterval(
                    timestamp: try number(raw["timestamp"], name: "rr.timestamp"),
                    milliseconds: try number(raw["milliseconds"] ?? raw["rr_ms"], name: "rr.milliseconds")
                )
            }
            let result = SleepAnalytics.segment(SleepInputSnapshot(
                acceleration: acceleration,
                heartRate: heartRate,
                rr: rr,
                timeZoneIdentifier: timeZoneIdentifier
            ))
            return metricMap(
                value: result.present ? sleepSegmentationMap(result) : nil,
                confidence: result.confidence,
                tier: AnalyticsTier.estimate.rawValue,
                inputs: ["accel_1hz", "hr_1hz", "rr_cleaned"],
                note: result.present ? "single-source sleep segmentation" : "no qualifying sleep window",
                present: result.present,
                algorithmVersion: "ana03.sleep.v1"
            )
        case "sleepHRFallback":
            let raw = try dictionaryArray(input["heart_rate"], name: "heart_rate")
            let samples = try raw.map { row in
                SleepHeartRateSample(timestamp: try number(row["timestamp"] ?? row["ts_sec"] ?? row["ts"], name: "heart_rate.timestamp"), bpm: try number(row["bpm"] ?? row["hr"], name: "heart_rate.bpm"), valid: (row["valid"] as? Bool) ?? true)
            }
            let baseline = try optionalNumbers(input["daytime_hr"], name: "daytime_hr") ?? []
            let result = SleepHRFallback.window(samples, daytimeBaseline: baseline, minDurationSeconds: try optionalInt(input["min_duration_seconds"], name: "min_duration_seconds") ?? 7_200, bridgeGapSeconds: try optionalInt(input["bridge_gap_seconds"], name: "bridge_gap_seconds") ?? 1_800, smoothingSeconds: try optionalInt(input["smoothing_seconds"], name: "smoothing_seconds") ?? 300)
            return metricMap(value: result.value.map(sleepFallbackMap), confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: baseline.isEmpty ? ["hr_1hz"] : ["hr_1hz", "daytime_hr"], note: result.present ? "HR-led candidate only; user confirmation required before staging" : (result.note ?? "no sustained nocturnal HR dip found"), present: result.present, algorithmVersion: "ana03.sleep.v1")
        case "sleepAccounting":
            let asleep = try bools(input["asleep"], name: "asleep")
            let stages = try optionalStringArray(input["stages"], name: "stages")?.map(canonicalSleepStage)
            let result = SleepAnalytics.accounting(asleep: asleep, stages: stages)
            return metricMap(value: result.value.map(sleepAccountingMap), confidence: result.confidence, tier: AnalyticsTier.high.rawValue, inputs: stages == nil ? ["in_bed_sleep_wake"] : ["in_bed_sleep_wake", "stages"], note: result.present ? "onset/offset/WASO/TST/efficiency; cycles ~90-min ultradian (REM-episode count when staged); 3-class only, never N1/N2/N3" : (result.note ?? "no sleep detected within the in-bed window"), present: result.present, algorithmVersion: "ana03.sleep.v1")
        case "sleepRegularity":
            let result = SleepAnalytics.sleepRegularityIndex(try bools(input["asleep"], name: "asleep"), epochsPerDay: try int(input["epochs_per_day"], name: "epochs_per_day"))
            return metricMap(value: result.value.map(sleepRegularityMap), confidence: result.confidence, tier: AnalyticsTier.high.rawValue, inputs: ["sleep_wake_epochs"], note: result.present ? "epoch-by-epoch 24-h concordance (Phillips 2017), SRI=200·agreement/cases−100; NOT SD-of-midsleep" : (result.note ?? "need ≥2 full days of clock-aligned sleep/wake epochs for SRI"), present: result.present, algorithmVersion: "ana03.sleep.v1")
        case "sleepHypnogram":
            let start = try int(input["start"], name: "start")
            let end = try int(input["end"], name: "end")
            guard end >= start else { throw NSError(domain: "Parity", code: 31, userInfo: [NSLocalizedDescriptionKey: "sleepHypnogram end precedes start"]) }
            let rawSegments = try dictionaryArray(input["stage_segments"], name: "stage_segments")
            var stages = [SleepStage](repeating: .wake, count: end - start)
            for raw in rawSegments {
                let segmentStart = try int(raw["start"], name: "stage_segments.start")
                let segmentEnd = try int(raw["end"], name: "stage_segments.end")
                guard segmentEnd >= segmentStart else { throw NSError(domain: "Parity", code: 32, userInfo: [NSLocalizedDescriptionKey: "stage segment end precedes start"]) }
                let stage = hypnogramSleepStage(try string(raw["stage"], name: "stage_segments.stage"))
                let lower = max(start, segmentStart)
                let upper = min(end, segmentEnd)
                if lower < upper {
                    for index in lower..<upper { stages[index - start] = stage }
                }
            }
            let result = SleepAnalytics.hypnogramMetrics(SleepSession(start: Double(start), end: Double(end), stages: stages))
            return metricMap(value: sleepHypnogramMap(result), confidence: 1, tier: AnalyticsTier.high.rawValue, inputs: ["sleep_stages"], note: "AASM hypnogram metrics from the shared staged session", present: true, algorithmVersion: "ana03.sleep.v1")
        case "sleepDayAssignment":
            let end = try number(input["sleep_end_timestamp"], name: "sleep_end_timestamp")
            let timeZoneID = try string(input["time_zone_identifier"], name: "time_zone_identifier")
            guard let window = SleepAnalytics.mainSleepDay(forEnd: end, timeZoneIdentifier: timeZoneID) else {
                return metricMap(value: nil, confidence: 0, tier: AnalyticsTier.high.rawValue, inputs: ["sleep_end", "time_zone"], note: "invalid sleep end or time zone", present: false, algorithmVersion: "ana03.sleep.v1")
            }
            return metricMap(value: sleepDayAssignmentMap(window), confidence: 1, tier: AnalyticsTier.high.rawValue, inputs: ["sleep_end", "time_zone"], note: "main sleep is assigned to the local calendar day on which it ends", present: true, algorithmVersion: "ana03.sleep.v1")
        case "readinessComposite":
            let rawInputs = try dictionaryArray(input["inputs"], name: "inputs")
            let readinessInputs = try rawInputs.map { row -> ReadinessInput in
                let metric = row["metric"] as? [String: Any]
                let value = try optionalNumber(metric?["value"], name: "input.metric.value") ?? (try optionalNumber(row["value"], name: "input.value"))
                return ReadinessInput(label: try string(row["label"], name: "input.label"), value: value, baseline: try numbers(row["baseline"], name: "input.baseline"), goodSign: try int(row["good_sign"], name: "input.good_sign"), weight: try number(row["weight"], name: "input.weight"))
            }
            let result = WellnessAnalytics.readinessComposite(readinessInputs, swcMultiplier: try optionalNumber(input["swc_multiplier"], name: "swc_multiplier") ?? 0.2, minBaseline: try optionalInt(input["min_baseline"], name: "min_baseline") ?? WellnessAnalytics.readinessCompositeMinBaseline)
            let note = result.present ? "Recovery v2: two inputs, guarded dispersion and early-history caution. Drivers describe the formula, not causes." : (result.note ?? "no readiness inputs present")
            return metricMap(value: result.value.map(readinessMap), confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: result.inputsUsed, note: note, drivers: result.drivers?.map(driverMap), present: result.present, algorithmVersion: WellnessAlgorithm.readinessVersion)
        case "stressIndex":
            let result = WellnessAnalytics.baevskyStressIndex(try numbers(input["rr_ms"] ?? input["nn_ms"], name: "rr_ms"), minRangeMilliseconds: try optionalNumber(input["min_range_ms"], name: "min_range_ms") ?? 20)
            return metricMap(value: result.value.map(stressMap), confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: ["rr_cleaned"], note: result.present ? "Baevsky Stress Index — median of ~5-min-window SI (AMo/(2·Mo·MxDMn)); resting autonomic tension, PRV — not psychological." : (result.note ?? "need ≥30 clean beats for a Stress Index histogram"), present: result.present, algorithmVersion: "ana04.wellness.v1")
        case "anomaly":
            let dates = try stringArray(input["dates"], name: "dates")
            let rawFeatures = try dictionaryArray(input["features"], name: "features")
            guard dates.count == rawFeatures.count else {
                throw NSError(domain: "Parity", code: 40, userInfo: [NSLocalizedDescriptionKey: "anomaly dates and features must have equal length"])
            }
            let features = try rawFeatures.map { raw in
                AnomalyFeatures(
                    restingHeartRate: try optionalNumber(raw["rhr"] ?? raw["resting_heart_rate"], name: "features.resting_heart_rate"),
                    hrv: try optionalNumber(raw["hrv"], name: "features.hrv"),
                    respiration: try optionalNumber(raw["resp"] ?? raw["respiration"], name: "features.respiration")
                )
            }
            let result = WellnessAnalytics.multivariateAnomaly(
                dates: dates,
                features: features,
                baselineDays: try optionalInt(input["baseline_days"], name: "baseline_days") ?? 28,
                minBaseline: try optionalInt(input["min_baseline"], name: "min_baseline") ?? 10,
                chiSquareGate: try optionalNumber(input["chi_square_gate"] ?? input["chi_sq_gate"], name: "chi_square_gate"),
                persistDays: try optionalInt(input["persist_days"], name: "persist_days") ?? 2,
                ridge: try optionalNumber(input["ridge"], name: "ridge") ?? 0.1
            )
            return metricMap(value: result.map(anomalyMap), confidence: result.isEmpty ? 0 : 0.6, tier: AnalyticsTier.estimate.rawValue, inputs: ["nightly_features", "prior_baseline"], note: "robust multivariate anomaly complement; no diagnosis", present: true, algorithmVersion: WellnessAnalytics.anomalyAlgorithmVersion)
        case "changePoint", "changepoint":
            let values = try numbers(input["values"], name: "values")
            let minimum = try optionalInt(input["min_segment"], name: "min_segment") ?? 7
            let result = WellnessAnalytics.segmentChangePoints(
                values,
                minSegment: minimum,
                penaltyMultiplier: try optionalNumber(input["penalty_multiplier"], name: "penalty_multiplier") ?? 1,
                penaltyOverride: try optionalNumber(input["penalty_override"], name: "penalty_override")
            )
            let note = result.present
                ? "binary segmentation w/ BIC-penalized change-in-mean; min-seg=\(minimum). Run on SMOOTHED aggregates only — do not celebrate regression-to-mean."
                : "series shorter than 2× min-segment; no change-point search"
            return metricMap(value: result.value.map(changePointMap), confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: ["daily_aggregate"], note: note, present: result.present, algorithmVersion: "ana04.wellness.v1")
        case "illnessCusum":
            let dates = try stringArray(input["dates"], name: "dates")
            let rhr = try nullableNumbers(input["resting_heart_rate"] ?? input["rhr"], name: "resting_heart_rate")
            guard dates.count == rhr.count else {
                throw NSError(domain: "Parity", code: 41, userInfo: [NSLocalizedDescriptionKey: "illnessCusum dates and resting_heart_rate must have equal length"])
            }
            let result = WellnessAnalytics.illnessCusum(
                dates: dates,
                restingHeartRate: rhr,
                baselineDays: try optionalInt(input["baseline_days"], name: "baseline_days") ?? 28,
                k: try optionalNumber(input["k"], name: "k") ?? 0.5,
                threshold: try optionalNumber(input["threshold"], name: "threshold") ?? 4,
                persistDays: try optionalInt(input["persist_days"], name: "persist_days") ?? 2,
                minBaseline: try optionalInt(input["min_baseline"], name: "min_baseline") ?? WellnessAnalytics.illnessCusumMinBaseline,
                returnZ: try optionalNumber(input["return_z"], name: "return_z") ?? 0.5,
                recoverDays: try optionalInt(input["recover_days"], name: "recover_days") ?? 2
            )
            return metricMap(value: result.map(illnessMap), confidence: result.isEmpty ? 0 : 0.6, tier: AnalyticsTier.estimate.rawValue, inputs: ["nightly_rhr", "prior_baseline"], note: "NightSignal/CUSUM illness signal; elevated RHR is not a diagnosis", present: true, algorithmVersion: "ana04.wellness.v1")
        case "staticTilt":
            let raw = try dictionaryArray(input["samples"] ?? input["epoch"], name: "samples")
            let samples = try raw.map { row in ActivityAccelerationSample(timestamp: try number(row["timestamp"] ?? row["ts_ms"] ?? row["ts"], name: "sample.timestamp"), x: try number(row["x"], name: "sample.x"), y: try number(row["y"], name: "sample.y"), z: try number(row["z"], name: "sample.z"), valid: (row["valid"] as? Bool) ?? true) }
            let result = ActivityAnalytics.staticTilt(samples, maxJitterG: try optionalNumber(input["max_jitter_g"], name: "max_jitter_g") ?? 0.05, minSamples: try optionalInt(input["min_samples"], name: "min_samples") ?? 3)
            return metricMap(value: result.value.map(staticTiltMap), confidence: result.confidence, tier: AnalyticsTier.high.rawValue, inputs: ["accel_1hz"], note: result.present ? "wrist gravity-tilt; body-position PROXY (static, low-motion only)" : (result.note ?? "epoch too short for a static-tilt estimate"), present: result.present, algorithmVersion: "ana05.activity.v1")
        case "energyFusion":
            let result = ActivityAnalytics.branchedEnergyFusion(timestamps: try numbers(input["timestamps"] ?? input["ts_ms"], name: "timestamps"), enmo: try numbers(input["enmo"], name: "enmo"), heartRate: try numbers(input["heart_rate"] ?? input["hr"], name: "heart_rate"), restingHR: try optionalNumber(input["resting_hr"], name: "resting_hr"), maxHR: try optionalNumber(input["max_hr"], name: "max_hr"), accelSaturationG: try optionalNumber(input["accel_saturation_g"], name: "accel_saturation_g") ?? 0.5, accelHigh: try optionalNumber(input["accel_high"], name: "accel_high") ?? 0.15, hrHigh: try optionalNumber(input["hr_high"], name: "hr_high") ?? 0.4)
            return metricMap(value: result.value.map(energyFusionMap), confidence: result.confidence, tier: result.tier.rawValue, inputs: ["enmo_1hz", "hr_1hz", "resting_hr?", "max_hr?"], note: result.value?.calibrated == true ? "Brage branched fusion w/ %HR-reserve; ESTIMATE EE, not kcal/METs" : "Brage branched fusion; RELATIVE EE index (no per-user HR calib)", present: result.present, algorithmVersion: "ana05.activity.v1")
        case "stepCounterReconcile":
            let raw = try dictionaryArray(input["readings"], name: "readings")
            let readings = try raw.map { row in StepCounterSample(timestamp: try number(row["timestamp"] ?? row["ts_sec"], name: "reading.timestamp"), cumulativeSteps: try int(row["cumulative_steps"] ?? row["steps"], name: "reading.cumulative_steps"), valid: (row["valid"] as? Bool) ?? true) }
            let result = ActivityAnalytics.reconcileStepCounter(readings, timeZoneIdentifier: input["time_zone_identifier"] as? String, backlogGapSeconds: try optionalNumber(input["backlog_gap_seconds"], name: "backlog_gap_seconds") ?? 86_400)
            return metricMap(value: result.value.map(stepCounterMap), confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: ["step_counter", "local_day", "counter_reset", "backlog"], note: result.note, present: result.present, algorithmVersion: "ana05.activity.v1")
        case "workoutDetect":
            let hrRaw = try dictionaryArray(input["heart_rate"] ?? input["hr"], name: "heart_rate")
            let hr = try hrRaw.map { row in WorkoutHRPoint(timestamp: try number(row["timestamp"] ?? row["ts"], name: "heart_rate.timestamp"), bpm: try number(row["bpm"] ?? row["hr"], name: "heart_rate.bpm"), valid: (row["valid"] as? Bool) ?? true) }
            let motionRaw = try dictionaryArray(input["motion"], name: "motion")
            let motion = try motionRaw.map { row in WorkoutMotionPoint(timestamp: try number(row["timestamp"] ?? row["ts"], name: "motion.timestamp"), intensity: try number(row["intensity"] ?? row["enmo"], name: "motion.intensity")) }
            let profile = try workoutProfile(input["profile"] as? [String: Any], fallback: input)
            let result = WorkoutAnalytics.detect(hr, motion: motion, restingHR: try optionalNumber(input["resting_hr"], name: "resting_hr"), maxHR: try optionalNumber(input["max_hr"], name: "max_hr"), age: try optionalNumber(input["age"], name: "age"), profile: profile)
            let sessions = (result.value ?? []).map(workoutSessionMap)
            return metricMap(value: sessions, confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: ["hr_1hz", "gravity_1hz", "profile", "max_hr", "age", "resting_hr"], note: "detected workouts (HR + motion gated, ≥5 min, ≥50% time in zone 2+); wrist-HR ESTIMATE, not medical advice", present: true, algorithmVersion: "ana06.workout.v1")
        case "hrRecovery":
            let result = WorkoutAnalytics.hrRecovery(try numbers(input["heart_rate"] ?? input["hr"], name: "heart_rate"), endIndex: try optionalInt(input["end_index"], name: "end_index"), recoverySeconds: try optionalInt(input["recovery_window_seconds"], name: "recovery_window_seconds") ?? 60, peakWindowSeconds: try optionalInt(input["peak_window_seconds"], name: "peak_window_seconds") ?? 30)
            let recoverySeconds = try optionalInt(input["recovery_window_seconds"], name: "recovery_window_seconds") ?? 60
            let note: String
            if result.present {
                note = "HRR-\(recoverySeconds)s = peak − HR@+\(recoverySeconds)s. Higher = faster parasympathetic reactivation (fitter). PRV not ECG."
            } else if result.note?.contains("too short") == true {
                note = "HR tail too short to reach +\(recoverySeconds)s recovery point"
            } else if result.note?.contains("no HR tail") == true {
                note = "no HR tail for HRR"
            } else if result.note?.contains("did not descend") == true {
                note = "HR did not descend after exercise end — likely still active"
            } else {
                note = result.note ?? "off-skin or missing HR around the recovery point"
            }
            return metricMap(value: result.value.map(hrRecoveryMap), confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: ["hr_1hz"], note: note, present: result.present, algorithmVersion: "ana06.workout.v1")
        case "dayCurves":
            let dates = try stringArray(input["dates"], name: "dates")
            let values = try numbers(input["values"], name: "values")
            let curves = WorkoutAnalytics.dayCurve(dates: dates, values: values, minimumHistory: try optionalInt(input["minimum_history"], name: "minimum_history") ?? 14)
            return metricMap(value: curves.map(dayCurveMap), confidence: curves.isEmpty ? 0 : 0.6, tier: AnalyticsTier.high.rawValue, inputs: ["daily_aggregate"], note: "date-scoped day curve; target day excluded from prior history", present: !curves.isEmpty, algorithmVersion: "ana06.workout.v1")
        case "boutCalories":
            let samples = try zip(numbers(input["timestamps"] ?? input["ts_sec"], name: "timestamps"), numbers(input["heart_rate"] ?? input["hr"], name: "heart_rate")).map { WorkoutHRPoint(timestamp: $0.0, bpm: $0.1) }
            guard let profile = try workoutProfile(input["profile"] as? [String: Any], fallback: input) else { throw NSError(domain: "Parity", code: 24, userInfo: [NSLocalizedDescriptionKey: "boutCalories requires a workout profile"]) }
            let result = WorkoutAnalytics.estimateBoutCalories(samples, profile: profile, hrMax: try optionalNumber(input["max_hr"], name: "max_hr"), restingHR: try optionalNumber(input["resting_hr"], name: "resting_hr"))
            return metricMap(value: result.value.map(boutCaloriesMap), confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: ["hr_bout", "workout_profile", "hrmax?", "resting_hr?"], note: result.note, present: result.present, algorithmVersion: "ana06.workout.v1")
        case "dailyEnergy":
            guard let profile = try workoutProfile(input["profile"] as? [String: Any], fallback: input) else { throw NSError(domain: "Parity", code: 25, userInfo: [NSLocalizedDescriptionKey: "dailyEnergy requires a workout profile"]) }
            let result = WorkoutAnalytics.dailyEnergy(try numbers(input["heart_rate"] ?? input["hr"], name: "heart_rate"), profile: profile, hrMax: try optionalNumber(input["max_hr"], name: "max_hr"), activeFraction: try optionalNumber(input["active_fraction"], name: "active_fraction") ?? 0.5, dayMinutes: try optionalInt(input["minutes"], name: "minutes") ?? 1_440)
            return metricMap(value: result.value.map(dailyEnergyMap), confidence: result.confidence, tier: AnalyticsTier.estimate.rawValue, inputs: ["hr_per_min", "workout_profile", "hrmax?"], note: result.note, present: result.present, algorithmVersion: "ana06.workout.v1")
        default:
            throw NSError(domain: "Parity", code: 5, userInfo: [NSLocalizedDescriptionKey: "unsupported metric: \(metric)"])
        }
    }

    private static func metricMap(value: Any?, confidence: Double, tier: String, inputs: [String], note: String?, drivers: [[String: Any]]? = nil, present: Bool, algorithmVersion: String) -> [String: Any] {
        var output: [String: Any] = ["value": value ?? "—", "confidence": AnalyticsMath.round6(confidence), "tier": tier, "inputs_used": inputs, "present": present, "algorithm_version": algorithmVersion]
        if let note { output["note"] = note }
        if let drivers { output["drivers"] = drivers }
        return output
    }
    private static func number(_ value: Any?, name: String) throws -> Double { if let value = value as? NSNumber { return value.doubleValue }; throw NSError(domain: "Parity", code: 6, userInfo: [NSLocalizedDescriptionKey: "\(name) must be numeric"]) }
    private static func optionalNumber(_ value: Any?, name: String) throws -> Double? {
        if value == nil || value is NSNull { return nil }
        return try number(value, name: name)
    }
    private static func int(_ value: Any?, name: String) throws -> Int {
        guard let value = value as? NSNumber else { throw NSError(domain: "Parity", code: 13, userInfo: [NSLocalizedDescriptionKey: "\(name) must be an integer"]) }
        return value.intValue
    }
    private static func optionalInt(_ value: Any?, name: String) throws -> Int? {
        if value == nil || value is NSNull { return nil }
        return try int(value, name: name)
    }
    private static func numbers(_ value: Any?, name: String) throws -> [Double] { guard let array = value as? [Any] else { throw NSError(domain: "Parity", code: 7, userInfo: [NSLocalizedDescriptionKey: "\(name) must be an array"]) }; return try array.map { try number($0, name: name) } }
    private static func optionalNumbers(_ value: Any?, name: String) throws -> [Double]? {
        guard let value, !(value is NSNull) else { return nil }
        return try numbers(value, name: name)
    }
    private static func nullableNumbers(_ value: Any?, name: String) throws -> [Double?] {
        guard let array = value as? [Any] else { throw NSError(domain: "Parity", code: 26, userInfo: [NSLocalizedDescriptionKey: "\(name) must be an array"]) }
        return try array.map { raw in
            if raw is NSNull { return nil }
            return try number(raw, name: name)
        }
    }
    private static func optionalBools(_ value: Any?, name: String) throws -> [Bool]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let array = value as? [Any] else { throw NSError(domain: "Parity", code: 14, userInfo: [NSLocalizedDescriptionKey: "\(name) must be an array"]) }
        return try array.map { raw in
            guard let bool = raw as? Bool else { throw NSError(domain: "Parity", code: 15, userInfo: [NSLocalizedDescriptionKey: "\(name) must contain booleans"]) }
            return bool
        }
    }
    private static func bools(_ value: Any?, name: String) throws -> [Bool] {
        guard let result = try optionalBools(value, name: name) else { throw NSError(domain: "Parity", code: 19, userInfo: [NSLocalizedDescriptionKey: "\(name) must be an array"]) }
        return result
    }
    private static func string(_ value: Any?, name: String) throws -> String {
        guard let value = value as? String else { throw NSError(domain: "Parity", code: 20, userInfo: [NSLocalizedDescriptionKey: "\(name) must be a string"]) }
        return value
    }
    private static func stringArray(_ value: Any?, name: String) throws -> [String] {
        guard let value = value as? [Any] else { throw NSError(domain: "Parity", code: 21, userInfo: [NSLocalizedDescriptionKey: "\(name) must be an array"]) }
        return try value.map { try string($0, name: name) }
    }
    private static func optionalStringArray(_ value: Any?, name: String) throws -> [String]? {
        guard let value, !(value is NSNull) else { return nil }
        return try stringArray(value, name: name)
    }
    private static func dictionaryArray(_ value: Any?, name: String) throws -> [[String: Any]] {
        guard let value = value as? [Any] else { throw NSError(domain: "Parity", code: 22, userInfo: [NSLocalizedDescriptionKey: "(name) must be an array"]) }
        return try value.map { raw in
            guard let dictionary = raw as? [String: Any] else { throw NSError(domain: "Parity", code: 23, userInfo: [NSLocalizedDescriptionKey: "(name) entries must be objects"]) }
            return dictionary
        }
    }
    private static func baselineConfiguration(_ name: String) throws -> MetricBaselineConfiguration {
        switch name {
        case "hrv": return Baselines.hrv
        case "resting_hr": return Baselines.restingHeartRate
        case "resp": return Baselines.respiration
        case "skin_temp": return Baselines.skinTemperature
        default: throw NSError(domain: "Parity", code: 9, userInfo: [NSLocalizedDescriptionKey: "unknown baseline configuration: \(name)"])
        }
    }
    private static func decodeBaselineState(_ raw: [String: Any]) throws -> BaselineState {
        guard let baseline = raw["baseline"] as? NSNumber, let spread = raw["spread"] as? NSNumber, let count = raw["n_valid"] as? NSNumber, let nights = raw["nights_since_update"] as? NSNumber, let statusName = raw["status"] as? String, let status = BaselineStatus(rawValue: statusName) else {
            throw NSError(domain: "Parity", code: 10, userInfo: [NSLocalizedDescriptionKey: "invalid baseline state"])
        }
        return BaselineState(baseline: baseline.doubleValue, spread: spread.doubleValue, validCount: count.intValue, nightsSinceUpdate: nights.intValue, status: status)
    }
    private static func baselineMap(_ result: BaselineState) -> [String: Any] {
        ["baseline": result.baseline, "spread": result.spread, "n_valid": result.validCount, "nights_since_update": result.nightsSinceUpdate, "status": result.status.rawValue, "present": result.validCount > 0, "algorithm_version": AnalyticsAlgorithmVersion.baseline]
    }
    private static func hrvTimeMap(_ value: HRVTimeValue) -> [String: Any] {
        var result: [String: Any] = ["n_beats": value.beatCount]
        if let value = value.rmssdMilliseconds { result["rmssd_ms"] = AnalyticsMath.round6(value) }
        if let value = value.sdnnMilliseconds { result["sdnn_ms"] = AnalyticsMath.round6(value) }
        if let value = value.sdannMilliseconds { result["sdann_ms"] = AnalyticsMath.round6(value) }
        if let value = value.sdnnIndexMilliseconds { result["sdnn_index_ms"] = AnalyticsMath.round6(value) }
        if let value = value.pNN50Percent { result["pnn50_pct"] = AnalyticsMath.round6(value) }
        return result
    }
    private static func hrvFrequencyMap(_ value: HRVFrequencyValue) -> [String: Any] {
        var result: [String: Any] = ["hf_gated": value.hfGated]
        if let field = value.ulf { result["ulf"] = AnalyticsMath.round6(field) }
        if let field = value.vlf { result["vlf"] = AnalyticsMath.round6(field) }
        if let field = value.lf { result["lf"] = AnalyticsMath.round6(field) }
        if let field = value.hf { result["hf"] = AnalyticsMath.round6(field) }
        if let field = value.total { result["total"] = AnalyticsMath.round6(field) }
        if let field = value.lfHF { result["lf_hf"] = AnalyticsMath.round6(field) }
        if let field = value.normalizedLF { result["nu_lf"] = AnalyticsMath.round6(field) }
        if let field = value.normalizedHF { result["nu_hf"] = AnalyticsMath.round6(field) }
        return result
    }
    private static func nocturnalMap(_ value: NocturnalRHRValue) -> [String: Any] { ["low30_mean_bpm": AnalyticsMath.round6(value.lowestThirtyMinuteMeanBPM), "p1_bpm": AnalyticsMath.round6(value.firstPercentileBPM), "valid_samples": value.validSampleCount] }
    private static func rrQualityGateMap(_ value: RRQualityGateValue) -> [String: Any] {
        [
            "nn_ms": value.normalIntervalsMilliseconds.map(AnalyticsMath.round6),
            "nn_times_ms": value.normalTimesMilliseconds.map(AnalyticsMath.round6),
            "classes": value.classes.map(\.rawValue),
            "clean_fraction": AnalyticsMath.round6(value.cleanFraction),
            "dropped_count": value.droppedCount,
            "corrected_count": value.correctedCount
        ]
    }
    private static func dailyNocturnalMap(_ value: DailyNocturnalRHRValue) -> [String: Any] {
        [
            "low30_mean_bpm": AnalyticsMath.round6(value.lowestThirtyMinuteMeanBPM),
            "p1_bpm": AnalyticsMath.round6(value.firstPercentileBPM),
            "valid_samples": value.validSampleCount,
            "local_day": value.localDay,
            "time_zone": value.timeZoneID,
            "day_start_ms": value.dayStartMilliseconds,
            "day_end_ms": value.dayEndMilliseconds,
            "day_duration_seconds": value.dayDurationSeconds
        ]
    }
    private static func dipMap(_ value: HRDipValue) -> [String: Any] { ["dip_pct": AnalyticsMath.round6(value.dipPercent), "day_mean_bpm": AnalyticsMath.round6(value.daytimeMeanBPM), "night_mean_bpm": AnalyticsMath.round6(value.nighttimeMeanBPM), "band": value.band] }
    private static func respiratoryMap(_ value: RespiratoryEstimate) -> [String: Any] {
        var result: [String: Any] = ["source": value.source, "brpm": value.breathsPerMinute.map(AnalyticsMath.round6) ?? NSNull()]
        if let field = value.peakHz { result["peak_hz"] = AnalyticsMath.round6(field) }
        if let field = value.power { result["power"] = AnalyticsMath.round6(field) }
        return result
    }
    private static func fusedRespirationMap(_ value: FusedRespiration) -> [String: Any] {
        var result: [String: Any] = [
            "brpm": value.breathsPerMinute.map(AnalyticsMath.round6) ?? NSNull(),
            "agreed": value.agreed,
            "decision": value.decision
        ]
        if let field = value.rsaBreathsPerMinute { result["rsa_brpm"] = AnalyticsMath.round6(field) }
        if let field = value.riivBreathsPerMinute { result["riiv_brpm"] = AnalyticsMath.round6(field) }
        return result
    }
    private static func brvMap(_ value: BreathingRateVariability) -> [String: Any] {
        var result: [String: Any] = ["mean_brpm": AnalyticsMath.round6(value.meanBreathsPerMinute), "sd_brpm": AnalyticsMath.round6(value.standardDeviationBreathsPerMinute), "cv": AnalyticsMath.round6(value.coefficientOfVariation), "n_windows": value.windowCount]
        if let field = value.trendSlope { result["trend_slope"] = AnalyticsMath.round6(field) }
        return result
    }

    private static func sleepCardioMap(_ value: SleepCardioStagingResult) -> [String: Any] {
        [
            "stages": value.stages.map(\.rawValue),
            "stages4": value.stages4.map(\.rawValue),
            "deep_flag": value.stages4.map { $0 == .deep },
            "epoch_sec": value.epochSeconds,
            "wake_pct": AnalyticsMath.round6(Double(value.stages.filter { $0 == .wake }.count) / Double(max(1, value.stages.count)) * 100),
            "nrem_pct": AnalyticsMath.round6(Double(value.stages.filter { $0 == .nrem }.count) / Double(max(1, value.stages.count)) * 100),
            "rem_pct": AnalyticsMath.round6(Double(value.stages.filter { $0 == .rem }.count) / Double(max(1, value.stages.count)) * 100)
        ]
    }
    private static func sleepSegmentationMap(_ value: SleepSegmentation) -> [String: Any] {
        var result: [String: Any] = [
            "stages": value.stages.map(\.rawValue),
            "stages4": value.stages4.map(\.rawValue),
            "epochs": value.stages.count,
            "confidence": AnalyticsMath.round6(value.confidence),
            "deep_low_confidence": true
        ]
        if let field = value.totalSleepSeconds { result["tst_sec"] = field }
        if let field = value.wasoSeconds { result["waso_sec"] = field }
        if let field = value.inBedSeconds { result["in_bed_sec"] = field }
        if let field = value.efficiencyPercent { result["efficiency_pct"] = AnalyticsMath.round6(field) }
        if let field = value.nremSeconds { result["nrem_sec"] = field }
        if let field = value.lightSeconds { result["light_sec"] = field }
        if let field = value.deepSeconds { result["deep_sec"] = field }
        if let field = value.remSeconds { result["rem_sec"] = field }
        if let field = value.wakeSeconds { result["wake_sec"] = field }
        return result
    }
    private static func sleepFallbackMap(_ value: SleepHRFallbackWindow) -> [String: Any] {
        ["onset_sec": AnalyticsMath.round6(value.onset), "offset_sec": AnalyticsMath.round6(value.offset), "duration_sec": value.durationSeconds, "threshold_bpm": AnalyticsMath.round6(value.thresholdBPM)]
    }
    private static func canonicalSleepStage(_ value: String) -> SleepStage {
        switch value.lowercased() {
        case "wake": return .wake
        case "rem": return .rem
        case "deep": return .deep
        case "light", "nrem": return .nrem
        default: return .nrem
        }
    }
    private static func sleepAccountingMap(_ value: SleepAccounting) -> [String: Any] {
        ["onset_idx": value.onsetIndex, "offset_idx": value.offsetIndex, "tst_sec": value.totalSleepSeconds, "waso_sec": value.wasoSeconds, "spt_sec": value.sleepPeriodSeconds, "efficiency_pct": AnalyticsMath.round6(value.efficiencyPercent), "cycles": value.cycles]
    }
    private static func sleepRegularityMap(_ value: SleepRegularity) -> [String: Any] {
        ["sri": AnalyticsMath.round6(value.score), "days": max(2, value.comparedPairs / max(1, value.epochsPerDay) + 1), "cases": value.comparedPairs]
    }
    private static func hypnogramSleepStage(_ value: String) -> SleepStage {
        switch value.lowercased() {
        case "wake": return .wake
        case "rem": return .rem
        case "deep": return .deep
        case "light", "nrem": return .light
        default: return .wake
        }
    }
    private static func sleepHypnogramMap(_ value: HypnogramMetrics) -> [String: Any] {
        [
            "tib_s": value.timeInBedSeconds,
            "tst_s": value.totalSleepSeconds,
            "spt_s": value.sleepPeriodSeconds,
            "sol_s": value.sleepOnsetLatencySeconds,
            "rem_latency_s": value.remLatencySeconds.map(AnalyticsMath.round6) ?? NSNull(),
            "waso_s": value.wasoSeconds,
            "efficiency": AnalyticsMath.round6(value.efficiency),
            "disturbances": value.disturbances,
            "deep_min": AnalyticsMath.round6(value.deepMinutes),
            "rem_min": AnalyticsMath.round6(value.remMinutes),
            "light_min": AnalyticsMath.round6(value.lightMinutes),
            "deep_pct": AnalyticsMath.round6(value.deepPercent),
            "rem_pct": AnalyticsMath.round6(value.remPercent),
            "light_pct": AnalyticsMath.round6(value.lightPercent)
        ]
    }
    private static func sleepDayAssignmentMap(_ value: SleepDayWindow) -> [String: Any] {
        func padded(_ number: Int, width: Int) -> String {
            let text = String(number)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let day = "\(padded(value.day.year, width: 4))-\(padded(value.day.month, width: 2))-\(padded(value.day.day, width: 2))"
        return [
            "day": day,
            "day_start_ms": Int((value.start * 1_000).rounded()),
            "day_end_ms": Int((value.end * 1_000).rounded()),
            "day_duration_seconds": value.lengthSeconds
        ]
    }
    private static func readinessMap(_ value: ReadinessValue) -> [String: Any] {
        ["score": AnalyticsMath.round6(value.score), "composite_z": AnalyticsMath.round6(value.compositeZ), "meaningful": value.meaningful]
    }
    private static func driverMap(_ value: AnalyticsDriver) -> [String: Any] {
        var result: [String: Any] = ["label": value.label, "contribution": AnalyticsMath.round6(value.contribution)]
        if let detail = value.detail { result["detail"] = detail }
        return result
    }
    private static func stressMap(_ value: StressIndex) -> [String: Any] {
        ["si": AnalyticsMath.round6(value.si), "level": value.level, "mode_s": AnalyticsMath.round6(value.modeSeconds), "amo_pct": AnalyticsMath.round6(value.amoPercent), "mxdmn_s": AnalyticsMath.round6(value.variationRangeSeconds)]
    }
    private static func anomalyMap(_ value: AnomalyDay) -> [String: Any] {
        var result: [String: Any] = [
            "date": value.date,
            "flagged": value.flagged,
            "candidate": value.candidate,
            "drivers": value.drivers.map(driverMap)
        ]
        if let mahalanobis = value.mahalanobis { result["mahalanobis"] = AnalyticsMath.round6(mahalanobis) }
        if let note = value.note { result["note"] = note }
        return result
    }
    private static func changePointMap(_ value: ChangePointSegmentation) -> [String: Any] {
        [
            "change_points": value.changePoints,
            "segment_means": value.segmentMeans.map(AnalyticsMath.round6),
            "segments": value.segments,
            "penalty": AnalyticsMath.round6(value.penalty)
        ]
    }
    private static func illnessMap(_ value: IllnessDay) -> [String: Any] {
        var result: [String: Any] = ["date": value.date, "state": value.state.rawValue]
        if let cusum = value.cusum { result["cusum"] = AnalyticsMath.round6(cusum) }
        if let z = value.z { result["z"] = AnalyticsMath.round6(z) }
        if let note = value.note { result["note"] = note }
        return result
    }
    private static func staticTiltMap(_ value: Tilt) -> [String: Any] {
        ["pitch_deg": AnalyticsMath.round6(value.pitchDeg), "roll_deg": AnalyticsMath.round6(value.rollDeg), "position": value.position.rawValue, "n": value.nSamples, "stillness": AnalyticsMath.round6(value.stillness)]
    }
    private static func energyFusionMap(_ value: EnergyFusion) -> [String: Any] {
        ["points": value.points.map { ["timestamp": AnalyticsMath.round6($0.timestamp), "index": AnalyticsMath.round6($0.index), "accel_component": AnalyticsMath.round6($0.accelComponent), "hr_component": AnalyticsMath.round6($0.heartRateComponent), "accel_weight": AnalyticsMath.round6($0.accelerationWeight), "branch": $0.branch] }, "relative_load": AnalyticsMath.round6(value.relativeLoad), "calibrated": value.calibrated]
    }
    private static func stepCounterMap(_ value: StepCounterResult) -> [String: Any] {
        ["days": value.days.map { ["day": ["era": $0.day.era, "year": $0.day.year, "month": $0.day.month, "day": $0.day.day], "steps": $0.steps, "reset_detected": $0.resetDetected, "backlog_steps": $0.backlogSteps] }, "total_steps": value.totalSteps, "reset_count": value.resetCount, "backlog_steps": value.backlogSteps]
    }
    private static func workoutProfile(_ raw: [String: Any]?, fallback: [String: Any]) throws -> WorkoutProfile? {
        guard let raw = raw ?? ((fallback["weight_kg"] != nil || fallback["height_cm"] != nil || fallback["sex"] != nil) ? fallback : nil) else { return nil }
        let sexName = (raw["sex"] as? String ?? "nonbinary").lowercased()
        let sex: ActivitySex = sexName == "male" ? .male : sexName == "female" ? .female : .nonbinary
        return WorkoutProfile(weightKG: try optionalNumber(raw["weight_kg"], name: "profile.weight_kg") ?? 70, heightCM: try optionalNumber(raw["height_cm"], name: "profile.height_cm") ?? 170, age: try optionalNumber(raw["age"], name: "profile.age") ?? 30, sex: sex)
    }
    private static func workoutSessionMap(_ value: ExerciseSession) -> [String: Any] {
        var result: [String: Any] = [
            "start": AnalyticsMath.round6(value.start), "end": AnalyticsMath.round6(value.end), "avg_hr": AnalyticsMath.round6(value.averageBPM), "peak_hr": AnalyticsMath.round6(value.peakBPM),
            "strain": value.strain.map(AnalyticsMath.round6) ?? NSNull(), "duration_s": AnalyticsMath.round6(value.durationSeconds), "avg_hrr_pct": value.zones?.averageHRReservePercent.map(AnalyticsMath.round6) ?? NSNull(),
            "hrmax": value.hrMax.map(AnalyticsMath.round6) ?? NSNull(), "hrmax_source": value.hrMaxSource, "calories_kcal": value.caloriesKcal.map(AnalyticsMath.round6) ?? NSNull(),
            "calories_kj": value.caloriesKcal.map { AnalyticsMath.round6($0 * 4.184) } ?? NSNull(), "calories_used_default_anchors": false, "sport": value.sport
        ]
        if let zones = value.zones {
            result["zone_time_pct"] = Dictionary(uniqueKeysWithValues: zones.zoneTimePercent.map { (String($0.key), AnalyticsMath.round6($0.value)) })
        } else {
            result["zone_time_pct"] = [:]
        }
        return result
    }
    private static func hrRecoveryMap(_ value: HRRecovery) -> [String: Any] {
        ["peak_hr": AnalyticsMath.round6(value.peakBPM), "hr_at_60s": AnalyticsMath.round6(value.heartRateAtRecovery), "drop_bpm": AnalyticsMath.round6(value.dropBPM), "drop_pct": AnalyticsMath.round6(value.dropPercent)]
    }
    private static func dayCurveMap(_ value: WorkoutDayCurve) -> [String: Any] {
        ["date": value.date, "value": AnalyticsMath.round6(value.value), "percentile_of_you": value.percentileOfYou.map(AnalyticsMath.round6) ?? NSNull(), "prior_count": value.priorCount]
    }
    private static func boutCaloriesMap(_ value: WorkoutEnergyEstimate) -> [String: Any] {
        ["kcal": AnalyticsMath.round6(value.kcal), "kj": AnalyticsMath.round6(value.kilojoules), "used_default_anchors": value.usedDefaultAnchors]
    }
    private static func dailyEnergyMap(_ value: WorkoutDailyEnergy) -> [String: Any] {
        ["total_kcal": AnalyticsMath.round6(value.totalKcal), "active_kcal": AnalyticsMath.round6(value.activeKcal), "basal_kcal": AnalyticsMath.round6(value.basalKcal), "used_default_hrmax": value.usedDefaultHRmax]
    }

    private static func decodeRespMetric(_ raw: Any?, label: String) throws -> AnalyticsMetric<RespiratoryEstimate> {
        guard let input = raw as? [String: Any] else {
            throw NSError(domain: "Parity", code: 16, userInfo: [NSLocalizedDescriptionKey: "\(label) must be an object"])
        }
        let inputs = input["inputs_used"] as? [String] ?? []
        let confidence = try optionalNumber(input["confidence"], name: "\(label).confidence") ?? 0
        let tier = input["tier"] as? String ?? AnalyticsTier.relative.rawValue
        guard let tierValue = AnalyticsTier(rawValue: tier) else {
            throw NSError(domain: "Parity", code: 17, userInfo: [NSLocalizedDescriptionKey: "\(label).tier is invalid"])
        }
        guard let value = input["value"] as? [String: Any] else {
            return .absent(tier: tierValue, inputsUsed: inputs, note: input["note"] as? String, algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        let estimate = RespiratoryEstimate(
            breathsPerMinute: try optionalNumber(value["brpm"], name: "\(label).value.brpm"),
            peakHz: try optionalNumber(value["peak_hz"], name: "\(label).value.peak_hz"),
            power: try optionalNumber(value["power"], name: "\(label).value.power"),
            source: value["source"] as? String ?? label,
            algorithmVersion: AnalyticsAlgorithmVersion.respiration
        )
        return AnalyticsMetric(value: estimate, confidence: confidence, tier: tierValue, inputsUsed: inputs, note: input["note"] as? String, algorithmVersion: AnalyticsAlgorithmVersion.respiration)
    }
}

public enum BaselineDerivation {
    public static func robust(_ values: [Double], minimumValid: Int = 3) -> RobustBaseline {
        let center = AnalyticsMath.median(values)
        return RobustBaseline(center: center, scale: AnalyticsMath.mad(values), validCount: values.count, windowCount: values.count, sufficient: values.count >= minimumValid)
    }
}

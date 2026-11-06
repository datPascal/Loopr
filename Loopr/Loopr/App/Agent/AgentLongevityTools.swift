import AIKit
import Foundation

// LV-09: the longevity read tools. Each one reads through `AgentReaders`, so the gate decides on every call and again
// after the read. A tool reports what the stores hold and never works out a verdict. Free text the person wrote
// (version notes, rebuttals, report notes, dose notes, prescriber) is not part of any row, so it cannot reach a result.

extension AgentToolExecutor {
    private static let flagNote = "Values, units, ranges and flags are the lab's own, as printed. A missing range or flag was not printed. Loopr does not judge a value. A value with needsReview true was scanned and the person has not checked it yet."

    // MARK: Protocol, adherence, experiments (Journal answers)

    func protocolTool() async throws -> String {
        let row = try await readers.protocolRecords { try await $0.activeProtocol() }
        guard let row else {
            return Self.json(["protocol": NSNull(), "note": "The person has no active Protocol."])
        }
        await session.add(source: AgentSource(id: "protocol", domain: .journalAnswers, label: "Protocol", count: row.rules.count, range: nil,
                                              recordIDs: row.rules.map(\.key), link: nil))
        return Self.json(["protocol": ["name": row.name, "version": row.version, "versionSaved": row.versionDay,
                                       "rules": row.rules.map(Self.ruleJSON)],
                          "versions": row.versions.map { ["number": $0.number, "saved": $0.day] as [String: Any] },
                          "note": "Rules are listed in the order the person sees them. A time of day is a local time. A target of kind done has no number."])
    }

    private static func ruleJSON(_ rule: AgentProtocolRuleRow) -> [String: Any] {
        var row: [String: Any] = ["key": rule.key, "title": rule.title, "group": rule.group, "checkedBy": rule.source,
                                  "target": rule.targetKind, "evening": rule.evening]
        if let v = rule.targetMetric { row["metric"] = v }
        if let v = rule.targetValue { row["value"] = Self.round(v, places: 2) }
        if let v = rule.targetUnit { row["unit"] = v }
        if let v = rule.time { row["time"] = v }
        return row
    }

    func adherenceTool(_ args: [String: Any]) async throws -> String {
        let range = try range(args)
        let data = try await readers.protocolRecords { try await $0.adherence(from: range.from, to: range.to, today: today) }
        guard let data else {
            return Self.json(["from": range.from, "to": range.to, "protocol": NSNull(), "note": "The person has no active Protocol."])
        }
        var titles: [String: String] = [:]
        var order: [String] = []
        var totals = ["kept": 0, "missed": 0, "pending": 0, "unknown": 0]
        let days = data.days.map { day -> [String: Any] in
            var row: [String: Any] = ["day": day.day, "version": day.version]
            var counts = ["kept": 0, "missed": 0, "pending": 0, "unknown": 0]
            for state in ["kept", "missed", "pending", "unknown"] {
                let keys = day.checks.filter { $0.state == state }.map(\.ruleKey)
                if !keys.isEmpty { row[state] = keys }
                counts[state] = keys.count
                totals[state, default: 0] += keys.count
            }
            for check in day.checks {
                if titles[check.ruleKey] == nil { order.append(check.ruleKey) }
                titles[check.ruleKey] = check.title
            }
            let decided = counts["kept", default: 0] + counts["missed", default: 0]
            if decided > 0 { row["keptShare"] = Self.round(Double(counts["kept", default: 0]) / Double(decided), places: 2) }
            return row
        }
        let decided = totals["kept", default: 0] + totals["missed", default: 0]
        var output: [String: Any] = ["from": range.from, "to": range.to, "protocol": data.protocolName,
                                     "rules": order.map { ["key": $0, "title": titles[$0] ?? $0] }, "days": days,
                                     "decidedRules": decided, "keptRules": totals["kept", default: 0],
                                     "note": "Each day lists rule keys under kept, missed, pending or unknown. Pending and unknown rules are not decided and are not misses. keptShare is kept divided by kept plus missed, and is left out when nothing was decided. Days that are not listed have no Protocol, because it started later."]
        if decided > 0 { output["keptShare"] = Self.round(Double(totals["kept", default: 0]) / Double(decided), places: 2) }
        if !data.days.isEmpty {
            await session.add(source: AgentSource(id: "adherence.\(range.from).\(range.to)", domain: .journalAnswers, label: "Protocol checks",
                count: data.days.count, range: AgentDayRange(from: data.days.first?.day ?? range.from, to: data.days.last?.day ?? range.to),
                recordIDs: data.days.map(\.day), link: nil))
        }
        return Self.json(output)
    }

    func experimentsTool(_ args: [String: Any]) async throws -> String {
        let range = try range(args)
        let rows = try await readers.experimentRecords { reader, bandMetrics in
            try await reader.experiments(from: range.from, to: range.to, today: today, withResults: bandMetrics)
        }
        let withheld = rows.contains { $0.result == nil }
        var output: [String: Any] = ["from": range.from, "to": range.to, "experiments": rows.map(Self.experimentJSON),
                                     "note": "These compare the person's own nights. They do not show cause. Report a result only as the result field gives it. Early is a first look and never a difference between the nights."]
        if withheld { output["resultsWithheld"] = AgentAccessError.off(.metrics).message }
        if !rows.isEmpty {
            await session.add(source: AgentSource(id: "experiments.\(range.from).\(range.to)", domain: .journalAnswers, label: "Experiments",
                count: rows.count, range: nil, recordIDs: rows.map(\.id), link: nil))
        }
        return Self.json(output)
    }

    private static func experimentJSON(_ row: AgentExperimentRow) -> [String: Any] {
        var design: [String: Any] = ["kind": row.design, "washoutNights": row.washout]
        if let length = row.designLength { design["length"] = length }
        var output: [String: Any] = [
            "id": row.id, "title": row.title, "intervention": row.intervention, "protocolRule": row.ruleKey, "design": design,
            "outcome": ["metric": row.outcomeKey, "title": row.outcomeTitle, "unit": row.outcomeUnit, "betterWhen": row.outcomeBenefit,
                        "fixedOnDay1": true] as [String: Any],
            "minimumNightsPerArm": row.minimumNightsPerArm, "plannedNights": row.plannedNights, "nightsCompleted": row.nightsCompleted,
            "startDay": row.startDay, "status": row.status, "running": row.status == "running", "stoppedEarly": row.stoppedEarly]
        if let end = row.endDay { output["endDay"] = end }
        guard let result = row.result else { return output }
        var value: [String: Any] = ["state": result.state, "onNights": result.onNights, "offNights": result.offNights]
        switch result.state {
        case "tooEarlyToSay": value["note"] = "Too early to say. The planned nights are not over."
        case "cannotReport": value["note"] = "No result yet. Loopr needs more nights from before day 1 to learn the person's usual night-to-night spread."
        case "notEnoughNights": value["note"] = "No result. An arm has fewer counted nights than the minimum."
        case "notCalled": value["note"] = "No label. The nights cannot tell a change from the person's usual spread."
        default:
            // A result needs a label, a difference and a range. Anything less is not shown as one.
            if let label = result.label, let difference = result.difference, let from = result.rangeFrom, let to = result.rangeTo {
                value["label"] = label
                value["difference"] = Self.round(difference, places: 2)
                value["likelyRange"] = [Self.round(from, places: 2), Self.round(to, places: 2)]
                value["unit"] = row.outcomeUnit
                value["differenceIs"] = "on nights minus off nights"
                if label == "Early" { value["labelNote"] = "A first look only. Do not say the nights differed." }
                if label == "No change" { value["labelNote"] = "The whole likely range sits inside the person's usual night-to-night spread." }
            } else {
                value["state"] = "notCalled"; value["note"] = "No label."
            }
        }
        output["result"] = value
        return output
    }

    // MARK: Supplements and medication

    func supplementsTool(_ args: [String: Any]) async throws -> String {
        let range = try range(args)
        let data = try await readers.supplements { try await $0.stackDoses(from: range.from, to: range.to) }
        func grouped(_ doses: [AgentStackDose]) -> [[String: Any]] {
            Dictionary(grouping: doses, by: \.day).sorted { $0.key < $1.key }.map { day, rows in
                ["day": day, "doses": rows.map { dose -> [String: Any] in
                    var row: [String: Any] = ["name": dose.name, "dose": dose.dose, "slot": dose.slot, "status": dose.status]
                    if let at = dose.at { row["at"] = at }
                    return row
                }]
            }
        }
        let all = data.supplements + data.medication
        if !all.isEmpty {
            let days = Set(all.map(\.day)).sorted()
            await session.add(source: AgentSource(id: "supplements.\(range.from).\(range.to)", domain: .supplements, label: "Supplements and medication",
                count: days.count, range: AgentDayRange(from: days.first ?? range.from, to: days.last ?? range.to),
                recordIDs: days, link: nil))
        }
        return Self.json(["from": range.from, "to": range.to, "supplements": grouped(data.supplements), "medication": grouped(data.medication),
                          "note": "Each dose is taken, skipped or notRecorded. notRecorded means the person has not said, so it is unknown and not a miss. Only active items from their start day are listed. Prescriber and notes are never part of this."])
    }

    // MARK: Blood tests

    func labsTool(_ args: [String: Any]) async throws -> String {
        let range = try range(args)
        let data = try await readers.labs { try await $0.labs(from: range.from, to: range.to) }
        let reports = data.reports.map { report -> [String: Any] in
            var row: [String: Any] = ["id": report.id, "day": report.day, "values": report.values.map(Self.labValueJSON)]
            if let lab = report.labName { row["lab"] = lab }
            if let fasting = report.fasting { row["fasting"] = fasting }
            return row
        }
        let clocks = data.clocks.map { clock -> [String: Any] in
            var row: [String: Any] = ["id": clock.id, "clock": clock.name, "value": clock.value, "lab": clock.labName, "day": clock.day]
            if let unit = clock.unit { row["unit"] = unit }
            return row
        }
        var output: [String: Any] = ["from": range.from, "to": range.to, "reports": reports, "clockResults": clocks, "note": Self.flagNote]
        if !data.otherDays.isEmpty { output["otherReportDays"] = data.otherDays }
        if !data.reports.isEmpty || !data.clocks.isEmpty {
            let days = (data.reports.map(\.day) + data.clocks.map(\.day)).sorted()
            await session.add(source: AgentSource(id: "labs.\(range.from).\(range.to)", domain: .labs, label: "Blood tests",
                count: data.reports.count + data.clocks.count, range: AgentDayRange(from: days.first ?? range.from, to: days.last ?? range.to),
                recordIDs: data.reports.map(\.id) + data.clocks.map(\.id), link: nil))
        }
        return Self.json(output)
    }

    private static func labValueJSON(_ value: AgentLabValueRow) -> [String: Any] {
        var row: [String: Any] = ["id": value.id, "name": value.name, "value": value.value, "entry": value.entry, "needsReview": value.needsReview]
        if let v = value.markerKey { row["marker"] = v }
        if let v = value.assay { row["assay"] = v }
        if let v = value.unit { row["unit"] = v }
        if let v = value.rangeMin { row["rangeMin"] = v }
        if let v = value.rangeMax { row["rangeMax"] = v }
        if let v = value.rangeText { row["rangeText"] = v }
        if let v = value.flag { row["flag"] = v }
        return row
    }

    // MARK: Capacity (Training)

    func capacityTool(_ args: [String: Any]) async throws -> String {
        let range = try range(args)
        let (data, bandMinutes, targets) = try await readers.capacity { reader, band, protocolTargets in
            (try await reader.capacity(from: range.from, to: range.to, today: today, withBandMinutes: band, withTargets: protocolTargets), band, protocolTargets)
        }
        let results = data.results.map { row -> [String: Any] in
            var entry: [String: Any] = ["id": row.id, "test": row.test, "title": row.title, "day": row.day, "value": Self.round(row.value, places: 2),
                                        "unit": row.unit, "source": row.source]
            if let side = row.side { entry["side"] = side }
            return entry
        }
        let goals = data.goals.map { goal -> [String: Any] in
            ["test": goal.test, "title": goal.title, "targetAtAge": goal.targetAge, "target": Self.round(goal.targetValue, places: 2), "unit": goal.unit, "setOn": goal.setDay]
        }
        let weeks = data.weeks.map { week -> [String: Any] in
            var row: [String: Any] = ["week": week.week, "firstDay": week.firstDay, "lastDay": week.lastDay,
                                      "strengthSessions": week.strengthSessions, "mobilitySessions": week.mobilitySessions,
                                      "bandDaysWithData": week.bandDaysWithData, "bandDaysInWeek": week.bandDaysInWeek]
            if let v = week.zone2Minutes { row["zone2Minutes"] = Self.round(v) }
            if let v = week.zone2Target { row["zone2Target"] = Self.round(v) }
            if let v = week.hardMinutes { row["hardMinutes"] = Self.round(v) }
            if let v = week.hardTarget { row["hardTarget"] = Self.round(v) }
            if let v = week.strengthTarget { row["strengthTarget"] = v }
            if let v = week.mobilityTarget { row["mobilityTarget"] = v }
            return row
        }
        var notes = ["Zone minutes are what the band measured. A week with bandDaysWithData below bandDaysInWeek counts only those days, so its minutes are a floor. A missing zone figure means no band data, not zero. A target is missing when the Protocol has no rule for it."]
        if !bandMinutes { notes.append("Zone minutes are left out because \(AgentDataDomain.metrics.title) is off in Your data.") }
        if !targets { notes.append("Weekly targets are left out because \(AgentDataDomain.journalAnswers.title) is off in Your data.") }
        if !data.results.isEmpty || !data.weeks.isEmpty {
            await session.add(source: AgentSource(id: "capacity.\(range.from).\(range.to)", domain: .training, label: "Capacity and dose",
                count: data.results.count + data.weeks.count, range: nil, recordIDs: data.results.map(\.id) + data.weeks.map(\.week), link: nil))
        }
        return Self.json(["from": range.from, "to": range.to, "results": results, "goals": goals, "weeklyDose": weeks, "note": notes.joined(separator: " ")])
    }

    // MARK: Ages

    func agesTool() async throws -> String {
        var output: [String: Any] = [:]
        var denial: AgentAccessError?
        var read = false

        do {
            let cardio = try await readers.cardioAge { try await $0.cardioAge(today: today) }
            read = true
            if let cardio, cardio.available, let years = cardio.years {
                var row: [String: Any] = ["available": true, "years": Self.round(years),
                                          "method": "Compares the person's VO2 max with the median VO2 max by age in a published reference curve. The age is where the person's VO2 max meets that median."]
                if let v = cardio.label { row["label"] = v }
                if let v = cardio.vo2Max { row["vo2Max"] = Self.round(v) }
                if let v = cardio.vo2MaxSource { row["vo2MaxSource"] = v }
                if let v = cardio.day { row["asOf"] = v }
                output["cardioAge"] = row
            } else {
                output["cardioAge"] = ["available": false, "note": "Cardio Age is not available. It needs a VO2 max from Apple Health or a lab test and the person's age."] as [String: Any]
            }
        } catch let error as AgentAccessError {
            denial = error
            output["cardioAge"] = ["available": false, "note": error.message] as [String: Any]
        }

        do {
            let blood = try await readers.bloodAge { try await $0.bloodAge() }
            read = true
            if let blood {
                output["bloodAge"] = ["available": true, "years": Self.round(blood.years), "method": "PhenoAge, from the person's own blood test values", "collectedOn": blood.collectedDay] as [String: Any]
            } else {
                output["bloodAge"] = ["available": false, "note": "Blood age is not available."] as [String: Any]
            }
        } catch let error as AgentAccessError {
            denial = denial ?? error
            output["bloodAge"] = ["available": false, "note": error.message] as [String: Any]
        }

        // Both parts refused: the call as a whole is refused, like any other read.
        if !read, let denial { throw denial }
        // DEC-02.12: Loopr Age has no validated model, so it is never given a value.
        output["looprAge"] = ["available": false, "note": "Loopr Age is not available."] as [String: Any]
        output["note"] = "Ages are estimates from the person's own data. Cardio Age follows VO2 max alone. Say Loopr Age is not available."
        var recordIDs: [String] = []
        if (output["cardioAge"] as? [String: Any])?["available"] as? Bool == true { recordIDs.append("cardioAge") }
        if (output["bloodAge"] as? [String: Any])?["available"] as? Bool == true { recordIDs.append("bloodAge") }
        if !recordIDs.isEmpty {
            await session.add(source: AgentSource(id: "ages", domain: recordIDs.contains("cardioAge") ? .metrics : .labs, label: "Ages",
                count: recordIDs.count, range: nil, recordIDs: recordIDs, link: nil))
        }
        return Self.json(output)
    }
}

import Foundation

/// Apply the preference from the event time, never subtract twice from an alarm.
public enum ReminderTiming {
    public static func apply(to proposal: Proposal, input: String, now: Date, leadMinutes: Int) -> Proposal {
        var result = proposal
        let count = proposal.actions.filter { $0.kind == .create }.count
        for index in result.actions.indices {
            var action = result.actions[index]
            let source = count == 1 ? input : (action.evidence ?? "")
            guard action.kind == .create, action.noReminder != true,
                  NaturalTaskIntent.wantsReminder(source), action.plannedHasTime == true,
                  let planned = action.plannedISO.flatMap(Dates.parse), planned > now else { continue }
            if hasSeparateReminderTime(source) || (source.contains("提前") && explicitLead(source) == nil) { continue }
            let minutes = explicitLead(source) ?? min(1440, max(0, leadMinutes))
            // An event still ahead with its lead window already open should alert now.
            let reminder = max(planned.addingTimeInterval(-Double(minutes) * 60), now.addingTimeInterval(1))
            action.reminderISO = Dates.iso(reminder)
            result.actions[index] = action
        }
        return result
    }

    static func hasSeparateReminderTime(_ input: String) -> Bool {
        let compact = input.filter { !$0.isWhitespace }
        if !compact.contains("提前"), let re = try? NSRegularExpression(pattern: #"[零一二两三四五六七八九十0-9]+(?:点|:|：)"#),
           re.numberOfMatches(in: compact, range: NSRange(compact.startIndex..., in: compact)) >= 2 { return true }
        let clauses = compact.components(separatedBy: CharacterSet(charactersIn: "，,。；;\n"))
        let timePattern = #"(?:[零一二两三四五六七八九十0-9]+(?:点|:|：)|今天|明天|后天|[0-9]+月[0-9]+[号日])"#
        return clauses.contains { !$0.contains("提醒") && $0.range(of: timePattern, options: .regularExpression) != nil }
            && clauses.contains { clause in
                clause.contains("提醒") && !clause.contains("提前")
                    && clause.range(of: timePattern, options: .regularExpression) != nil
            }
    }

    static func explicitLead(_ input: String) -> Int? {
        let text = input.filter { !$0.isWhitespace }
        if ["到时提醒", "到点提醒", "准时提醒", "按时提醒"].contains(where: text.contains) { return 0 }
        guard let re = try? NSRegularExpression(pattern: #"提前(半(?:个)?小时|[零一二两三四五六七八九十百0-9]+(?:分钟|小时))"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text) else { return nil }
        let duration = String(text[range])
        if duration.hasPrefix("半") { return 30 }
        let hours = duration.hasSuffix("小时")
        guard let number = LocalInterpreter.number(String(duration.dropLast(2))), number >= 0 else { return nil }
        let minutes = number.multipliedReportingOverflow(by: hours ? 60 : 1)
        return minutes.overflow ? nil : minutes.partialValue
    }
}

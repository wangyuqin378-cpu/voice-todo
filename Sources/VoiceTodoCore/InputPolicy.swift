import Foundation

enum InputPolicy {
    static func isUndoRequest(_ input: String) -> Bool {
        let text = (CommandText.body(input) ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { "？?\"“”‘’".contains($0) }) else { return false }
        return TaskReducer.normalized(text).range(of: #"^(?:刚才(?:弄错了|说错了))?(?:请)?(?:帮我)?撤销(?:一下|上一步|最近一次操作|刚才那条|刚才的操作)?$"#, options: .regularExpression) != nil
    }
    static let editMessage = "语音不修改已有事项。请在清单中点“…”编辑时间或提醒；要新增一条，请说“提醒我……”或“记下……”。"

    static func isEditRequest(_ input: String) -> Bool {
        let text = TaskReducer.normalized(input)
        guard !["不对", "说错", "改口", "不要修改", "不用改"].contains(where: text.contains) else { return false }
        return ["改成", "改为", "改一下", "推迟", "延后", "提前到", "改到", "挪到", "取消提醒", "关闭提醒"].contains(where: text.contains)
            || text.range(of: #"^(?:请)?(?:帮我|给我)?修改"#, options: .regularExpression) != nil
            || (text.contains("取消") && text.hasSuffix("提醒"))
    }

    static func canSupplyMissingReminder(_ input: String, task: TodoItem, question: FollowUp?) -> Bool {
        // Completing an unfinished creation is allowed. A new standalone request
        // never attaches itself to an existing similarly named task.
        guard let question, question.kind == .reminder, question.taskIDs == [task.id],
              task.needsReminder, task.reminderAt == nil,
              !NaturalTaskIntent.explicitRequest(CommandText.body(input) ?? input) else { return false }
        return true
    }
}

/// Verify relative calendar days independently from the model's ISO timestamps.
enum InputDateRules {
    static func validate(_ action: ProposedAction, input: String, now: Date, timeZone: String, singleCreation: Bool) throws {
        guard action.kind == .create || action.kind == .setReminder else { return }
        guard let zone = TimeZone(identifier: timeZone) else { throw UserFacingError("无法确定输入时的时区，未改变清单。") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var source: String
        if singleCreation || action.kind == .setReminder { source = input }
        else if let evidence = action.evidence, !evidence.isEmpty, input.contains(evidence) {
            let clauses = input.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!\n")).filter { $0.contains(evidence) }
            source = clauses.count == 1 ? clauses[0] : input
        } else {
            let clauses = input.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!\n"))
            let matching = clauses.filter { clause in action.title.map { TaskReducer.normalized(clause).contains(TaskReducer.normalized($0)) } ?? false }
            source = matching.count == 1 ? matching[0] : input
        }
        // A corrected single creation uses the final date, never the abandoned one.
        if singleCreation, let correction = source.range(of: "不对|说错了", options: [.regularExpression, .backwards]) {
            let corrected = String(source[correction.upperBound...])
            if !offsets(corrected).isEmpty { source = corrected }
        }
        let clauses = source.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!\n"))
        let reminderWords = clauses.filter { NaturalTaskIntent.wantsReminder($0) }
        let eventWords = clauses.filter { !NaturalTaskIntent.wantsReminder($0) && !TaskReducer.containsNegation($0.replacingOccurrences(of: "明天", with: "那天").replacingOccurrences(of: "后天", with: "那天")) }
        let reminderDays = Set(reminderWords.flatMap { offsets($0) })
        let eventDays = Set(eventWords.flatMap { offsets($0) })
        let allDays = offsets(source)
        func check(_ iso: String?, days: Set<Int>) throws {
            guard let iso, !days.isEmpty else { return }
            guard days.count == 1, let offset = days.first,
                  let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else {
                throw UserFacingError("这段话包含多个相对日期，请分条说明事项与日期，未改变清单。")
            }
            guard let proposed = Dates.parse(iso), calendar.isDate(day, inSameDayAs: proposed) else {
                throw UserFacingError("识别出的日期与原话不一致。按说话时的当地日期，应为\(Dates.planned(day, hasTime: false))。未改变清单，请重新说明。")
            }
        }
        try check(action.plannedISO, days: eventDays.isEmpty ? allDays : eventDays)
        // A lead reminder may legitimately fall on the previous calendar day.
        let reminderIsLead: Bool
        if action.kind == .create, action.plannedHasTime == true,
           let planned = action.plannedISO.flatMap(Dates.parse), let alarm = action.reminderISO.flatMap(Dates.parse),
           alarm <= planned, planned.timeIntervalSince(alarm) <= Double(max(1440, ReminderTiming.explicitLead(source) ?? 0)) * 60,
           !ReminderTiming.hasSeparateReminderTime(source) { reminderIsLead = true }
        else { reminderIsLead = false }
        if !reminderIsLead { try check(action.reminderISO, days: reminderDays.isEmpty ? allDays : reminderDays) }
        // Named calendar dates are verified too; invalid dates cannot silently roll over.
        if let re = try? NSRegularExpression(pattern: #"(?:[0-9]{4}年)?[一二三四五六七八九十0-9]+月[一二三四五六七八九十0-9]+[号日]"#) {
            let dates = re.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
                Range(match.range, in: source).map { String(source[$0]) }
            }
            if dates.count == 1, let word = dates.first {
                guard let expected = NaturalTaskIntent.day(word, now: now, timeZone: timeZone) else {
                    throw UserFacingError("原话中的日期无效或已过去，未改变清单。")
                }
                var targets = [action.plannedISO ?? action.reminderISO]
                if !reminderIsLead && !ReminderTiming.hasSeparateReminderTime(source) { targets.append(action.reminderISO) }
                for target in targets.compactMap({ $0 }) {
                    if let actual = Dates.parse(target), !calendar.isDate(expected, inSameDayAs: actual) {
                        throw UserFacingError("识别出的日期与原话不一致，未改变清单。")
                    }
                }
            }
        }
    }

    private static func offsets(_ text: String) -> Set<Int> {
        guard let regex = try? NSRegularExpression(pattern: "大后天|后天|明天|今天|明早|明晚|今晚") else { return [] }
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return ["今天":0,"今晚":0,"明天":1,"明早":1,"明晚":1,"后天":2,"大后天":3][String(text[range])]
        })
    }
}

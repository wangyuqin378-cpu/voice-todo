import Foundation

/// Conservative, whole-utterance grammar. Returning nil means use the semantic model,
/// never "no matching task". Every proposal still passes through TaskReducer.
public enum LocalInterpreter {
    public static func interpret(_ input: String, workspace: Workspace, question: FollowUp?,
                                 now: Date, timeZone: String, defaultReminderHour: Int = 9, defaultReminderLeadMinutes: Int = 10) -> Proposal? {
        guard let proposal = rawInterpret(input, workspace: workspace, question: question, now: now,
                                          timeZone: timeZone, defaultReminderHour: defaultReminderHour) else { return nil }
        return ReminderTiming.apply(to: proposal, input: input, now: now, leadMinutes: defaultReminderLeadMinutes)
    }
    private static func rawInterpret(_ input: String, workspace: Workspace, question: FollowUp?,
                                     now: Date, timeZone: String, defaultReminderHour: Int) -> Proposal? {
        guard !ConversationIntent.isDiscussion(input) else { return nil }
        let text = CommandText.body(input) ?? input.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.trimmingCharacters(in: CharacterSet(charactersIn: "。！! \n\t"))
        let normalized = TaskReducer.normalized(words)
        if let question, question.kind == .clarification, question.taskIDs.isEmpty,
           let title = question.suggestedTitle, question.reminderISO != nil || question.plannedISO != nil,
           TimedReminderRequest.ambiguousRemainder(question.originalInput) != nil {
            if ["是", "是的", "对", "对的", "好", "好的", "要", "确认"].contains(normalized) {
                return Proposal(actions: [.init(kind: .create, title: title, reminderISO: question.reminderISO,
                    noReminder: question.noReminder, resolvesQuestionID: question.id,
                    plannedISO: question.plannedISO, plannedHasTime: question.plannedHasTime)])
            }
            if TimedReminderRequest.isDecline(input) {
                return Proposal(actions: [.init(kind: .noop, resolvesQuestionID: question.id)])
            }
        }
        if CommandText.body(input) == nil, let rest = TimedReminderRequest.ambiguousRemainder(input) {
            if let candidate = TimedReminderRequest.split(rest, now: now, timeZone: timeZone) {
                return Proposal(actions: [.init(kind: .clarify, title: candidate.title, noReminder: true,
                    question: "记下\(Dates.display(candidate.date))的\(candidate.title)吗？回答“是”或“不用”。",
                    plannedISO: Dates.iso(candidate.date), plannedHasTime: true)])
            }
            return Proposal(actions: [.init(kind: .clarify, question: "你是想记下一件事吗？再说一下具体安排。")])
        }
        if InputPolicy.isUndoRequest(input) {
            return Proposal(actions: [.init(kind: .undo)])
        }
        if InputPolicy.isEditRequest(text) {
            return Proposal(actions: [.init(kind: .noop, question: InputPolicy.editMessage, evidence: input)])
        }
        if let question, question.kind == .chooseTask, question.intent == .complete,
           let id = CompletionMatch.selectedID(input, tasks: question.taskIDs.compactMap { id in workspace.tasks.first { $0.id == id } }) {
            return Proposal(actions: [.init(kind: .complete, taskID: id, candidates: [id], resolvesQuestionID: question.id)])
        }
        guard words.count <= 120, !words.contains(where: { "\"“”‘’「」『』？?；;\n".contains($0) }),
              !["不对", "算了", "改成", "改为", "等等", "如果", "假如", "每天", "每周", "每月", "他说", "她说", "比如", "例如", "其实", "但是", "然后", "以及", "并且"].contains(where: words.contains)
        else { return nil }
        if let proposal = CancellationRequest.interpret(input, workspace: workspace, question: question,
                                                        now: now, timeZone: timeZone) { return proposal }
        if let question, question.kind == .reminder, question.taskIDs.count == 1 {
            if normalized == "不用提醒" || normalized == "不需要提醒" {
                return Proposal(actions: [.init(kind: .setReminder, taskID: question.taskIDs[0], noReminder: true, resolvesQuestionID: question.id)])
            }
            if let date = time(words, now: now, timeZone: timeZone) {
                return Proposal(actions: [.init(kind: .setReminder, taskID: question.taskIDs[0], reminderISO: Dates.iso(date), resolvesQuestionID: question.id)])
            }
            if let day = NaturalTaskIntent.day(words, now: now, timeZone: timeZone),
               let date = NaturalTaskIntent.defaultReminder(on: day, hour: defaultReminderHour, now: now, timeZone: timeZone) {
                return Proposal(actions: [.init(kind: .setReminder, taskID: question.taskIDs[0], reminderISO: Dates.iso(date), resolvesQuestionID: question.id)])
            }
        }
        // Explicit reminders also use the event-aware path when the title has
        // no keyword from the background intent filter (e.g. 整理文件 / 喝水).
        // Otherwise the legacy alarm-only path loses plannedAt and the lead.
        if NaturalTaskIntent.candidate(text) || NaturalTaskIntent.wantsReminder(text),
           let proposal = NaturalTaskIntent.create(text, now: now, timeZone: timeZone, defaultReminderHour: defaultReminderHour) { return proposal }
        // Multi-clause instructions, negations and corrections go to the semantic path as a whole.
        let noReminder = words.hasSuffix("不用提醒")
        var single = noReminder ? String(words.dropLast(4)).trimmingCharacters(in: CharacterSet(charactersIn: "，, ")) : words
        guard !single.contains(where: { "，,、。！!".contains($0) }) else { return nil }
        if !noReminder, !TaskReducer.containsNegation(single), let title = completionTitle(single) {
            let matches = workspace.tasks.filter { CompletionMatch.matches(words, task: $0, now: now, timeZone: timeZone) }
            if matches.count != 1 {
                let related = workspace.tasks.filter { !$0.isCompleted && CompletionMatch.possiblyRelated(title, $0.title) }
                guard !related.isEmpty else { return nil }
                let names = related.enumerated().map { index, task in
                    "\(index + 1). \(task.title)" + ((task.plannedAt ?? task.reminderAt).map { " · " + Dates.planned($0, hasTime: task.plannedAt == nil || task.plannedHasTime != false) } ?? "")
                }.joined(separator: "\n")
                return Proposal(actions: [.init(kind: .clarify, candidates: related.map(\.id),
                    question: "还不能直接对应，未自动完成。请选具体事项，或说完整名称、序号：\n\(names)",
                    evidence: words, clarificationIntent: .complete)])
            }
            guard let task = matches.first else { return nil }
            let action = ProposedAction(kind: task.isCompleted ? .alreadyCompleted : .complete,
                                        taskID: task.id, candidates: [task.id], evidence: words)
            let proposal = Proposal(actions: [action])
            // In particular, a grammar match cannot bypass future/negative completion validation.
            guard (try? TaskReducer.apply(proposal, to: workspace, inputID: UUID().uuidString,
                                          input: input, answering: question?.id, now: now, timeZone: timeZone)) != nil else { return nil }
            return proposal
        }
        if let match = captures("^(.+?)提醒我(.+)$", single), !noReminder {
            guard let date = time(match[0], now: now, timeZone: timeZone), safeTitle(match[1]) else { return nil }
            return Proposal(actions: [.init(kind: .create, title: match[1], reminderISO: Dates.iso(date))])
        }
        if single.hasPrefix("提醒我"), !noReminder,
           let request = TimedReminderRequest.split(String(single.dropFirst(3)), now: now, timeZone: timeZone), safeTitle(request.title) {
            return Proposal(actions: [.init(kind: .create, title: request.title, reminderISO: Dates.iso(request.date))])
        }
        for prefix in ["创建待办", "添加待办", "新增待办", "创建todo", "创建to do", "记得", "提醒我", "记一下"] {
            if single.lowercased().hasPrefix(prefix) {
                single = String(single.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                guard safeTitle(single), !["今天", "明天", "后天", "下午", "上午", "晚上", "点", "分钟", "周"].contains(where: single.contains) else { return nil }
                return Proposal(actions: [.init(kind: .create, title: single, noReminder: noReminder || !NaturalTaskIntent.wantsReminder(input))])
            }
        }
        return nil
    }

    private static func safeTitle(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 60 && !["已经", "好了", "完成了", "做完", "交了", "买了", "发了", "取消", "撤销", "不要", "不用", "别", "没", "还要", "提醒", "和", "顺便"].contains(where: value.contains)
    }
    static func completionTitle(_ value: String) -> String? {
        guard !["明天", "后天", "今晚", "下周", "准备", "打算", "将要", "才", "再", "就", "应该", "可能"].contains(where: value.contains) else { return nil }
        if let m = captures("^(?:我)?(?:已经|已)?完成了(.+)$", value) { return m[0] }
        if let m = captures("^(?:我)?(?:已经|已)?(提交|购买|发送|支付|买|交|发|写|整理)(.+)了$", value) { return m[0] + m[1] }
        if let m = captures("^(.+?)(?:已经|已)?(提交|购买|发送|支付|买|交|发|写|整理)(?:好了|完了|到了|了)$", value) { return m[1] + m[0] }
        if let m = captures("^(.+?)(?:已经|已)?(?:完成了|完成|做完了|做完|好了)$", value) { return m[0] }
        return nil
    }

    public static func time(_ text: String, now: Date, timeZone: String, requireFuture: Bool = true) -> Date? {
        guard let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        if ["半小时后", "半个小时后"].contains(text) { return now.addingTimeInterval(1800) }
        if let m = captures("^([零一二两三四五六七八九十百0-9]+)(分钟|小时)后$", text),
           let count = number(m[0]), count > 0, count <= 1000 {
            return now.addingTimeInterval(Double(count * (m[1] == "分钟" ? 60 : 3600)))
        }
        guard let m = captures("^(" + NaturalTaskIntent.dayPattern + ")?(凌晨|早上|上午|中午|下午|晚上)?([零一二两三四五六七八九十0-9]+)(?:点|:|：)(半|[零一二两三四五六七八九十0-9]+分?)?$", text),
              var hour = number(m[2]) else { return nil }
        let period = m[1]
        if period.isEmpty, hour <= 12, !text.contains(":"), !text.contains("：") { return nil }
        if !period.isEmpty {
            guard hour >= (period == "凌晨" ? 0 : 1), hour <= 12 else { return nil }
            if ["下午", "晚上"].contains(period), hour < 12 { hour += 12 }
            if period == "中午", hour < 11 { return nil }
            if ["凌晨", "早上", "上午"].contains(period), hour == 12 { hour = 0 }
        }
        let minute = m[3] == "半" ? 30 : (m[3].isEmpty ? 0 : number(m[3].replacingOccurrences(of: "分", with: "")))
        guard (0...23).contains(hour), let minute, (0...59).contains(minute) else { return nil }
        guard let day = m[0].isEmpty ? now : NaturalTaskIntent.day(m[0], now: now, timeZone: timeZone) else { return nil }
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = hour; parts.minute = minute; parts.second = 0
        guard let date = calendar.date(from: parts), !requireFuture || date > now,
              calendar.component(.hour, from: date) == hour else { return nil }
        return date
    }
    static func number(_ value: String) -> Int? {
        if let n = Int(value) { return n }
        let digit: [Character:Int] = ["零":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        if value.count == 1, let c = value.first { return c == "十" ? 10 : digit[c] }
        let parts = value.split(separator: "十", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count <= 1 }) else { return nil }
        let tens = parts[0].first.flatMap { digit[$0] } ?? (parts[0].isEmpty ? 1 : -1)
        let ones = parts[1].first.flatMap { digit[$0] } ?? (parts[1].isEmpty ? 0 : -1)
        return tens > 0 && ones >= 0 ? tens * 10 + ones : nil
    }
    private static func captures(_ pattern: String, _ value: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let match = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: value).map { String(value[$0]) } ?? "" }
    }
}

public enum CommandText {
    public static func accepts(_ value: String) -> Bool {
        body(value) != nil || TimedReminderRequest.ambiguousRemainder(value) != nil || NaturalTaskIntent.candidate(value)
    }
    /// Explicit address at the start of the newly inserted segment. Quotes or ordinary
    /// conversation mentioning a todo elsewhere cannot enable cross-application capture.
    public static func body(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["随口清单", "水果清单", "清单"] {
            if text.hasPrefix(prefix) {
                let rest = String(text.dropFirst(prefix.count))
                guard let first = rest.first else { return nil }
                // Dictation chooses punctuation; addressing the app must not depend
                // on it inserting a comma after the wake phrase.
                let hasBoundary = "，,:：。 \n".contains(first)
                let startsCommand = ["创建", "添加", "新增", "记得", "提醒我", "记一下", "撤销", "取消", "删除", "删掉", "今天", "明天", "后天", "下周", "周", "星期", "上午", "下午", "晚上", "不用提醒"].contains(where: rest.hasPrefix)
                let completion = ["已经交了", "交好了", "买好了", "做完了", "完成了", "还没", "没完成"].contains(where: rest.contains)
                let shortReply = ["是", "是的", "对", "对的", "好", "好的", "要", "确认", "不用", "不用了", "不要", "不是", "取消", "不需要"].contains(TaskReducer.normalized(rest))
                guard hasBoundary || startsCommand || completion || shortReply else { return nil }
                let body = rest.trimmingCharacters(in: CharacterSet(charactersIn: "，,:： \n"))
                return body.isEmpty ? nil : (creation(body) ?? body)
            }
        }
        if let created = creation(text) { return created }
        // Explicit requests can be spoken naturally, without the app's name.
        if let re = try? NSRegularExpression(pattern: #"^(?:请|麻烦)?(?:(?:帮我|给我)提醒(?:我)?(?:一下)?|提醒我(?:一下)?)[，,:：\s]*(.+)$"#),
           let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) { return "提醒我" + text[range] }
        if let re = try? NSRegularExpression(pattern: #"^(?:今天|明天|后天|周|星期|上午|下午|晚上|半小时|[一二两三四五六七八九十0-9]+(?:分钟|小时)后).*提醒我.+$"#),
           re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return text }
        return nil
    }
    private static func creation(_ text: String) -> String? {
        if let re = try? NSRegularExpression(pattern: #"^(?:创建|添加|新增)[，,:：\s]*(?:一个)?(?:待办|代办|to[ -]?do)[，,:：\s]*"#, options: .caseInsensitive),
           let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            let body = String(text[range.upperBound...])
            return body.isEmpty ? nil : "创建待办" + body
        }
        return nil
    }
}

import Foundation

/// Cancellation uses the complete local index. A date narrows the target; it never
/// schedules a new reminder. Unsupported wording falls back to clarification.
enum CancellationRequest {
    struct Target {
        var title: String
        var date: Date?
        var hasTime = false
        var reminderOnly: Bool

        func exactTitle(_ task: TodoItem) -> Bool {
            TaskReducer.normalized(title) == TaskReducer.normalized(task.title)
        }

        func matches(_ task: TodoItem, timeZone: String) -> Bool {
            guard !task.isCompleted else { return false }
            let query = TaskReducer.normalized(title), name = TaskReducer.normalized(task.title)
            guard name == query || (query.count >= 2 && name.contains(query)) else { return false }
            guard let date else { return true }
            // Event time takes precedence over a notification sent in advance.
            guard let scheduled = task.plannedAt ?? task.reminderAt,
                  let zone = TimeZone(identifier: timeZone) else { return false }
            if hasTime {
                guard task.plannedAt == nil || task.plannedHasTime != false else { return false }
                return abs(scheduled.timeIntervalSince(date)) < 1
            }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            return calendar.isDate(scheduled, inSameDayAs: date)
        }
    }

    static func isRequest(_ input: String) -> Bool { body(input) != nil }

    static func parse(_ input: String, now: Date, timeZone: String) -> Target? {
        guard let (raw, reminderOnly) = body(input) else { return nil }
        // Longest time prefix first, retaining half hours and minutes.
        if raw.count > 2 {
            for count in stride(from: min(30, raw.count - 1), through: 2, by: -1) {
                let prefix = String(raw.prefix(count))
                if let date = LocalInterpreter.time(prefix, now: now, timeZone: timeZone, requireFuture: false) {
                    let title = stripConnector(String(raw.dropFirst(count)))
                    guard safeTitle(title) else { continue }
                    return Target(title: title, date: date, hasTime: true, reminderOnly: reminderOnly)
                }
            }
        }
        if let day = capture("^(" + NaturalTaskIntent.dayPattern + ")", raw),
           let date = NaturalTaskIntent.day(day, now: now, timeZone: timeZone) {
            let title = stripConnector(String(raw.dropFirst(day.count)))
            guard safeTitle(title) else { return nil }
            return Target(title: title, date: date, reminderOnly: reminderOnly)
        }
        guard safeTitle(raw) else { return nil }
        return Target(title: raw, reminderOnly: reminderOnly)
    }

    static func interpret(_ input: String, workspace: Workspace, question: FollowUp?, now: Date, timeZone: String) -> Proposal? {
        if let question, question.kind == .chooseTask,
           question.intent == .cancelTask || (question.intent == .setReminder && question.noReminder == true),
           let id = selectedID(input, tasks: question.taskIDs.compactMap { id in workspace.tasks.first { $0.id == id } }) {
            return Proposal(actions: [.init(kind: question.intent == .cancelTask ? .cancelTask : .setReminder,
                taskID: id, noReminder: question.intent == .setReminder ? true : nil,
                candidates: [id], resolvesQuestionID: question.id)])
        }
        guard let target = parse(input, now: now, timeZone: timeZone) else { return nil }
        let matches = workspace.tasks.filter { target.matches($0, timeZone: timeZone) }
        if target.reminderOnly, !matches.isEmpty {
            return Proposal(actions: [.init(kind: .noop, question: InputPolicy.editMessage, evidence: input)])
        }
        guard let task = matches.first else {
            // A new plan ending in “不用提醒” still belongs to the creation path.
            if target.reminderOnly, !["取消", "删除", "删掉"].contains(where: input.contains) { return nil }
            return Proposal(actions: [.init(kind: .noop, question: "没有找到对应的待办：\(target.title)。清单没有变化。", evidence: input)])
        }
        if matches.count > 1 || !target.exactTitle(task) {
            let names = matches.enumerated().map { index, task in
                let date = task.plannedAt ?? task.reminderAt
                return "\(index + 1). \(task.title)" + (date.map { " · \(Dates.planned($0, hasTime: task.plannedAt == nil || task.plannedHasTime != false))" } ?? "")
            }.joined(separator: "\n")
            return Proposal(actions: [.init(kind: .clarify, noReminder: target.reminderOnly ? true : nil,
                candidates: matches.map(\.id), question: "\(target.reminderOnly ? "取消哪一条的提醒" : "取消哪一条事项")？可以说“第一条”。\n\(names)",
                evidence: input, clarificationIntent: target.reminderOnly ? .setReminder : .cancelTask)])
        }
        return Proposal(actions: [.init(kind: target.reminderOnly ? .setReminder : .cancelTask, taskID: task.id,
            noReminder: target.reminderOnly ? true : nil, candidates: [task.id], evidence: input)])
    }

    static func selectedID(_ input: String, tasks: [TodoItem]) -> String? {
        let text = TaskReducer.normalized(CommandText.body(input) ?? input)
        let ordinals = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        for (index, task) in tasks.enumerated() where !task.isCompleted {
            let number = index + 1
            var answers = ["第\(number)条", "第\(number)个", "\(number)"]
            if index < ordinals.count { answers += ["第\(ordinals[index])条", "第\(ordinals[index])个"] }
            if answers.contains(text) { return task.id }
        }
        let matching = tasks.filter { !$0.isCompleted && TaskReducer.normalized($0.title) == text }
        return matching.count == 1 ? matching.first?.id : nil
    }

    /// Use the entire clause, not a positive substring cut out of a negation.
    static func validatedTarget(evidence: String?, input: String, now: Date, timeZone: String) throws -> Target {
        guard let evidence, !evidence.isEmpty, input.contains(evidence),
              !["不对", "说错", "弄错", "算了", "其实", "改成", "改为", "保留", "先别", "不要取消", "不用取消", "不取消", "别取消", "没有取消", "还没取消", "不要删", "别删", "不用删"].contains(where: input.contains) else {
            throw UserFacingError("取消意思还不明确，清单没有变化，请再说一次最终操作。")
        }
        let clauses = input.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!\n"))
        // Also allow punctuation between the app's address and the command.
        let source = CommandText.body(input) ?? input
        let evidenceBody = CommandText.body(evidence) ?? evidence
        if TaskReducer.normalized(source) == TaskReducer.normalized(evidenceBody),
           let target = parse(source, now: now, timeZone: timeZone) { return target }
        for clause in clauses where TaskReducer.normalized(clause) == TaskReducer.normalized(evidence) {
            if let target = parse(clause, now: now, timeZone: timeZone) { return target }
        }
        throw UserFacingError("没有找到明确的取消表述，清单没有变化。")
    }

    private static func body(_ input: String) -> (String, Bool)? {
        var text = input.filter { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: "。！!"))
        for prefix in ["随口清单", "水果清单", "清单"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "，,:：")); break
        }
        guard text.count <= 120,
              !["不对", "说错", "弄错", "算了", "其实", "改成", "改为", "如果", "假如", "他说", "她说", "比如", "例如", "是否", "可能", "打算", "准备", "不要取消", "不用取消", "不取消", "不想取消", "别取消", "未取消", "没取消", "没有取消", "不删除", "别删", "不要删", "不用删"].contains(where: text.contains),
              !text.contains(where: { "，,、；;。！？?\"“”‘’「」『』".contains($0) }) else { return nil }
        if let title = capture(#"^(.+?)(?:不用提醒|不需要提醒|不要提醒)(?:了)?$"#, text) {
            guard !["创建", "添加", "新增", "记", "安排", "提醒我", "帮我", "给我", "请", "麻烦"].contains(where: title.hasPrefix) else { return nil }
            return (stripConnector(title), true)
        }
        let raw = capture(#"^(?:请|麻烦你?)?(?:帮我|给我|替我)?(?:取消掉|取消|删除|删掉)(?:一下)?(.+?)(?:吧)?$"#, text)
            ?? capture(#"^(?:请|麻烦你?)?(?:帮我|给我|替我)?把(.+?)(?:取消掉|取消|删除|删掉)(?:了|吧)?$"#, text)
            ?? capture(#"^(.+?)(?:已经)?取消(?:了|掉了)$"#, text)
        guard var title = raw, !title.isEmpty else { return nil }
        var reminderOnly = false
        if title.hasPrefix("提醒我") { title = String(title.dropFirst(3)); reminderOnly = true }
        if title.hasSuffix("提醒") { title = String(title.dropLast(2)); reminderOnly = true }
        title = stripConnector(title)
        guard !title.isEmpty else { return nil }
        return (title, reminderOnly)
    }
    private static func stripConnector(_ text: String) -> String {
        var result = text
        if result.hasPrefix("的") { result.removeFirst() }
        if result.hasSuffix("的") { result.removeLast() }
        return result
    }
    private static func safeTitle(_ title: String) -> Bool {
        !title.isEmpty && title.count <= 60 && !["取消", "删除", "删掉", "提醒", "不用", "不要", "不需要", "没有", "还没", "吗", "和", "然后", "以及", "并且", "或者", "今天", "明天", "后天", "昨天", "周", "月", "号", "日", "点", "上午", "下午", "晚上", "中午", ":", "："].contains(where: title.contains)
    }
    private static func capture(_ pattern: String, _ value: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

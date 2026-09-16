import Foundation

/// Lexical agreement, not model confidence. Keep every distinguishing noun;
/// only normalize completion grammar and a small set of equivalent verbs.
enum CompletionMatch {
    static func selectedID(_ input: String, tasks: [TodoItem]) -> String? {
        if let id = CancellationRequest.selectedID(input, tasks: tasks) { return id }
        let text = TaskReducer.normalized(input)
        guard let parts = groups(#"^(第[一二三四五六七八九十0-9]+(?:条|个))(?:已经|已)?(?:完成了|做完了|交好了|交了|买好了|买了)$"#, text) else { return nil }
        return CancellationRequest.selectedID(parts[0], tasks: tasks)
    }
    /// A later negative predicate about this object, or an omitted object,
    /// cannot be cut away by a model choosing only the earlier positive clause.
    static func contradicts(_ clause: String, title: String, allowOmittedObject: Bool = true) -> Bool {
        let text = TaskReducer.normalized(clause)
        guard let parts = groups(#"^(?:其实|等等|等一下|我)?(.*?)(?:还没有|还没|没有|尚未|还未|没|未)(交|提交|买|购买|发|发送|写|付|支付|寄|报|取|填|签|洗|整理|完成|做完|做好)(?:好|完|了)?$"#, text) else { return false }
        let object = parts[0]
        if object.isEmpty { return allowOmittedObject }
        let verb = ["完成", "做完", "做好"].contains(parts[1]) ? "" : parts[1]
        return canonical(verb + object) == canonical(title)
    }
    /// Broad overlap is used only to ask, or prevent a duplicate completion log.
    /// It must never authorize completion.
    static func possiblyRelated(_ a: String, _ b: String) -> Bool {
        func object(_ value: String) -> String {
            canonical(value).replacingOccurrences(of: #"^(?:整理|交|买|发|写|付|寄|报|取|填|签|洗)"#, with: "", options: .regularExpression)
        }
        let a = object(a), b = object(b)
        return a.count >= 2 && b.count >= 2 && (a.contains(b) || b.contains(a))
    }
    static func candidates(evidence: String?, input: String, tasks: [TodoItem], now: Date, timeZone: String) -> [TodoItem] {
        guard let evidence, !evidence.isEmpty, input.contains(evidence) else { return [] }
        let source = (CommandText.body(input) ?? input).replacingOccurrences(of: "？", with: "？，").replacingOccurrences(of: "?", with: "?,")
        let clauses = source.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!\n"))
        // Match the whole source clause, so “材料交好了” cut from
        // “签证材料交好了” cannot be used to complete a different task.
        return tasks.filter { task in
            if clauses.contains(where: { $0.contains(evidence) && matches($0, task: task, now: now, timeZone: timeZone) }) { return true }
            // A correction may omit the object after naming it in the preceding
            // negative sentence. Require that exact object and a correction marker.
            guard let index = clauses.lastIndex(where: { $0.contains(evidence) }), index > 1,
                  let correction = clauses[..<index].lastIndex(where: { ["不对", "说错了"].contains(TaskReducer.normalized($0)) }),
                  correction > 0, contradicts(clauses[correction - 1], title: task.title, allowOmittedObject: false),
                  let predicate = groups(#"^(?:刚刚|刚|已经|已)*(交|提交|买|购买|发|发送|写|付|支付|寄|报|取|填|签|洗|整理)(?:好了|完了|了)$"#, TaskReducer.normalized(clauses[index])) else { return false }
            return canonical(task.title).hasPrefix(canonical(predicate[0]))
        }
    }

    static func matches(_ input: String, task: TodoItem, now: Date, timeZone: String) -> Bool {
        guard !TaskReducer.containsNegation(input) else { return false }
        var text = TaskReducer.normalized(CommandText.body(input) ?? input)
        text = text.replacingOccurrences(of: #"^(?:我)?(?:刚刚|刚|已经|已)?把"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^我(?:已经|已|刚刚|刚)?(?:把)?"#, with: "", options: .regularExpression)
        let aspect = #"(?:已经|已|刚刚|刚|早就|也|都|全部|终于)*"#
        let verbs = "提交|购买|发送|支付|整理|收拾|打扫|交|买|发|写|付|寄|报|取|填|签|洗|打|回|收"
        var titles: [String] = []
        if let m = groups("^给(.+?)的电话" + aspect + "打(?:完|好)?了$", text) { titles.append("给" + m[0] + "打电话") }
        if let m = groups("^(.+?)" + aspect + "(?:发|发送)给(.+?)了$", text) { titles.append("给" + m[1] + "发送" + m[0]) }
        if let m = groups("^" + aspect + "(?:完成了|完成|做完了|搞定了)(.+)$", text) { titles.append(m[0]) }
        if let m = groups("^(.+?)" + aspect + "(?:完成了|完成|做完了|做完|做好了|搞定了|办妥了|好了)$", text) { titles.append(m[0]) }
        if let m = groups("^(.+?)" + aspect + "(" + verbs + ")(?:好了|完了|到了|出去了|了)$", text) { titles.append(m[1] + m[0]) }
        if let m = groups("^" + aspect + "(" + verbs + ")(.+?)(?:了)$", text) { titles.append(m[0] + m[1]) }
        let name = canonical(task.title)
        for title in titles {
            if canonical(title) == name { return true }
            // Explicit date qualifiers may distinguish otherwise identical titles.
            if let parts = groups(#"^(今天|明天|后天|周[一二三四五六日天]|星期[一二三四五六日天])的?(.+)$"#, title),
               canonical(parts[1]) == name,
               let date = NaturalTaskIntent.day(parts[0], now: now, timeZone: timeZone),
               sameDay(date, task: task, timeZone: timeZone) { return true }
            if let parts = groups(#"^(\d{1,2})月(\d{1,2})[号日]的?(.+)$"#, title),
               canonical(parts[2]) == name, let scheduled = task.plannedAt ?? task.reminderAt,
               let zone = TimeZone(identifier: timeZone) {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                if calendar.component(.month, from: scheduled) == Int(parts[0]),
                   calendar.component(.day, from: scheduled) == Int(parts[1]) { return true }
            }
        }
        return false
    }

    private static func canonical(_ title: String) -> String {
        var result = TaskReducer.normalized(title)
        for (from, to) in [("提交", "交"), ("购买", "买"), ("发送", "发"), ("支付", "付")] where result.hasPrefix(from) {
            result = to + result.dropFirst(from.count); break
        }
        // “旅行计划书已完成” and “写旅行计划” keep the same full object.
        if result.hasSuffix("计划书") { result.removeLast() }
        if result.hasPrefix("写"), result.hasSuffix("计划") { result.removeFirst() }
        return result
    }
    private static func sameDay(_ date: Date, task: TodoItem, timeZone: String) -> Bool {
        guard let scheduled = task.plannedAt ?? task.reminderAt, let zone = TimeZone(identifier: timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.isDate(date, inSameDayAs: scheduled)
    }
    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

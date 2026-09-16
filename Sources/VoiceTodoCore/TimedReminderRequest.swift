import Foundation

/// A concrete time plus an action is only a candidate when addressed as a request.
/// An unclear verb such as "明确" produces a question, never an implicit task.
public enum TimedReminderRequest {
    public static func isDecline(_ text: String) -> Bool {
        ["不用", "不用了", "不要", "不是", "取消", "不需要", "不用提醒", "不需要提醒"]
            .contains(TaskReducer.normalized(CommandText.body(text) ?? text))
    }
    public static func ambiguousRemainder(_ input: String) -> String? {
        let text = compact(input)
        guard text.count <= 120,
              !["不", "没", "别", "如果", "假如", "每天", "每周", "或者", "他说", "她说", "比如", "例如", "？", "?", "\"", "“", "”"].contains(where: text.contains),
              let re = try? NSRegularExpression(pattern: #"^(?:请)?(?:帮我|给我)(?:明确|确认)(?:一下)?[，,:：]*(.+)$"#),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let rest = String(text[range])
        guard ["今天", "明天", "后天", "周", "星期"].contains(where: rest.hasPrefix),
              rest.contains("点") || rest.contains(":") || rest.contains("：") else { return nil }
        return rest
    }

    public static func split(_ input: String, now: Date, timeZone: String) -> (date: Date, title: String)? {
        let text = compact(input).trimmingCharacters(in: CharacterSet(charactersIn: "，,:：。！!"))
        guard text.count > 2, text.count <= 120 else { return nil }
        // Longest prefix first so "三点半" and "三点十五分" keep their minutes.
        for count in stride(from: min(30, text.count - 1), through: 2, by: -1) {
            let time = String(text.prefix(count))
            guard let date = LocalInterpreter.time(time, now: now, timeZone: timeZone) else { continue }
            var title = String(text.dropFirst(count)).trimmingCharacters(in: CharacterSet(charactersIn: "，,:："))
            if title.hasPrefix("的") { title.removeFirst() }
            for prefix in ["我要", "我有个", "我有一场", "要", "有个", "有一场"] where title.hasPrefix(prefix) { title.removeFirst(prefix.count); break }
            guard !title.isEmpty, title.count <= 60,
                  !["，", ",", "、", "。", "不", "没", "或者", "然后", "明天", "后天", "提醒", "点", "半", "分", "?", "？"].contains(where: title.contains) else { continue }
            return (date, title)
        }
        return nil
    }
    private static func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
}

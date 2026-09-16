import Foundation

/// A cheap local filter keeps ordinary dictation out of the task pipeline.
/// The model handles whole-utterance ambiguity after this filter, without a popup.
public enum NaturalTaskIntent {
    static let dayPattern = #"(?:今天|明天|后天|周[一二三四五六日天]|星期[一二三四五六日天]|(?:[0-9]{4}年)?[一二三四五六七八九十0-9]+月[一二三四五六七八九十0-9]+[号日])"#
    static let suffixReminderPattern = #"[，,。]?\s*(?:请|麻烦)?(?:提前(?:半(?:个)?小时|[零一二两三四五六七八九十百0-9]+(?:分钟|小时))|到时|到点|准时|按时)?(?:(?:帮我|给我)提醒(?:我)?|提醒我)(?:一下)?(?:吧)?$"#
    static func reminderSuffix(_ input: String) -> String? { match(suffixReminderPattern, input) }

    public static func wantsReminder(_ input: String) -> Bool {
        let text = compact(input)
        return text.contains("提醒") && !["不用提醒", "不要提醒", "不需要提醒", "别提醒"].contains(where: text.contains)
    }
    public static func explicitRequest(_ input: String) -> Bool {
        let text = compact(input).trimmingCharacters(in: CharacterSet(charactersIn: "。！!"))
        return match(#"^(?:请|麻烦你?)?(?:(?:帮我|给我|替我)(?:安排|记|记录|提醒|取消|删除|删掉)|(?:安排|记一下|记下|记住|记得|记录|提醒我|创建|添加|新增|撤销|取消|删除|删掉))"#, text) != nil
            || reminderSuffix(text) != nil
            || CancellationRequest.isRequest(text)
            || addressed(text)
    }
    public static func addressed(_ input: String) -> Bool {
        ["清单", "随口清单", "水果清单"].contains(where: compact(input).hasPrefix) && CommandText.body(input) != nil
    }
    public static func candidate(_ input: String) -> Bool {
        let text = compact(input)
        guard !text.isEmpty, !["他说", "她说", "跟朋友说", "比如", "例如", "假如", "如果", "转写", "转录", "翻译", "这句话", "这段话", "？", "?", "“", "”", "\""].contains(where: text.contains),
              !["天气好了", "今天天气好了", "心情好了", "网络好了", "信号好了"].contains(TaskReducer.normalized(text)) else { return false }
        if explicitRequest(text) || InputPolicy.isEditRequest(text) { return true }
        let clauses = text.split(whereSeparator: { "，,。；;\n".contains($0) })
        if clauses.count > 1 { return clauses.contains { candidate(String($0)) } }
        if match("^(?:我)?" + dayPattern, text) != nil,
           !negatesCreation(text),
           ["面试", "开会", "会议", "交", "买", "取", "写", "发", "电话", "预约", "复诊", "见", "还书", "缴费", "报销"].contains(where: text.contains) { return true }
        if !TaskReducer.containsNegation(text), LocalInterpreter.completionTitle(text.trimmingCharacters(in: .punctuationCharacters)) != nil { return true }
        return false
    }

    public static func create(_ input: String, now: Date, timeZone: String, defaultReminderHour: Int) -> Proposal? {
        var text = compact(input).trimmingCharacters(in: CharacterSet(charactersIn: "。！!"))
        guard text.count <= 120, !["不对", "改成", "算了", "每天", "每周", "如果", "假如", "他说", "她说", "比如", "例如", "然后", "以及", "并且", "或者", "？", "?", "“", "”", "\"", "；", ";", "\n"].contains(where: text.contains) else { return nil }
        let reminder = wantsReminder(text)
        // A trailing time-only reminder clause belongs to the preceding event.
        // It never edits an existing item and never becomes a task named “提醒我”.
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。"))
        if clauses.count == 2, let suffix = reminderSuffix(clauses[1]) {
            let timeText = String(clauses[1].dropLast(suffix.count))
            if !timeText.isEmpty {
                let alarm = LocalInterpreter.time(timeText, now: now, timeZone: timeZone)
                    ?? day(timeText, now: now, timeZone: timeZone).flatMap { defaultReminder(on: $0, hour: defaultReminderHour, now: now, timeZone: timeZone) }
                if let alarm, let event = create(clauses[0], now: now, timeZone: timeZone, defaultReminderHour: defaultReminderHour),
                   event.actions.count == 1, var action = event.actions.first, action.kind == .create {
                    action.reminderISO = Dates.iso(alarm); action.noReminder = false
                    return Proposal(actions: [action])
                }
            }
        }
        if let suffix = reminderSuffix(text) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "，,。"))
        }
        let noReminder = ["不用提醒", "不需要提醒", "不要提醒"].first { text.hasSuffix($0) }
        if let noReminder { text = String(text.dropLast(noReminder.count)).trimmingCharacters(in: CharacterSet(charactersIn: "，,")) }
        for ending in ["就好了", "就行了", "就行", "吧"] where text.hasSuffix(ending) { text = String(text.dropLast(ending.count)); break }
        if let prefix = match(#"^(?:请|麻烦你?)?(?:(?:帮我|给我|替我))?(?:安排(?:一下)?|记录(?:一下)?|记一下|记下|记住|记得|提醒我(?:一下)?)[，,:：]*"#, text) {
            text.removeFirst(prefix.count)
        } else if match("^(?:我)?" + dayPattern, text) == nil, match(#"^(?:我)?(?:凌晨|早上|上午|中午|下午|晚上|[0-9]{1,2}[:：])"#, text) == nil { return nil }
        if text.hasPrefix("我") { text.removeFirst() }
        if reminder, let range = text.range(of: "提醒我") { text.removeSubrange(range) }
        guard !negatesCreation(text), !text.contains(where: { "，,、。".contains($0) }) else { return nil }
        // A time attached to an event is not permission to send a notification.
        if let split = TimedReminderRequest.split(text, now: now, timeZone: timeZone), safeTitle(split.title) {
            let relativeAlarm = text.range(of: #"^(?:半(?:个)?小时|[零一二两三四五六七八九十百0-9]+(?:分钟|小时))后"#, options: .regularExpression) != nil
            return Proposal(actions: [.init(kind: .create, title: split.title,
                reminderISO: reminder ? Dates.iso(split.date) : nil, noReminder: !reminder,
                plannedISO: relativeAlarm ? nil : Dates.iso(split.date), plannedHasTime: relativeAlarm ? nil : true)])
        }
        if let dayWord = match("^" + dayPattern, text),
           let day = day(dayWord, now: now, timeZone: timeZone) {
            var title = String(text.dropFirst(dayWord.count))
            if let start = match(#"^(?:我)?(?:有(?:一场|一个|个|场)?|需要|要|得)?"#, title) { title.removeFirst(start.count) }
            if title.hasPrefix("的") { title.removeFirst() }
            guard safeTitle(title), !["点", "上午", "下午", "晚上", "中午", ":", "："].contains(where: title.contains) else { return nil }
            let alarm = reminder ? defaultReminder(on: day, hour: defaultReminderHour, now: now, timeZone: timeZone) : nil
            return Proposal(actions: [.init(kind: .create, title: title, reminderISO: alarm.map(Dates.iso),
                noReminder: !reminder, plannedISO: Dates.iso(day), plannedHasTime: false)])
        }
        guard safeTitle(text), !["今天", "明天", "后天", "点", "分钟", "上午", "下午", "晚上", "周", "月", "号"].contains(where: text.contains) else { return nil }
        return Proposal(actions: [.init(kind: .create, title: text, noReminder: !reminder)])
    }
    public static func day(_ text: String, now: Date, timeZone: String) -> Date? {
        guard let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        if let re = try? NSRegularExpression(pattern: #"^(?:([0-9]{4})年)?([一二三四五六七八九十0-9]+)月([一二三四五六七八九十0-9]+)[号日]$"#),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            func group(_ i: Int) -> String { Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
            guard let month = LocalInterpreter.number(group(2)), let day = LocalInterpreter.number(group(3)),
                  (1...12).contains(month), (1...31).contains(day) else { return nil }
            let explicitYear = Int(group(1)), currentYear = calendar.component(.year, from: now)
            for year in (explicitYear ?? currentYear)...(explicitYear ?? currentYear + 8) {
                guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                      calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { continue }
                if date >= calendar.startOfDay(for: now) { return date }
            }
            return nil
        }
        var offset = ["今天": 0, "明天": 1, "后天": 2][text]
        if offset == nil, let last = text.last, text.hasPrefix("周") || text.hasPrefix("星期"),
           let weekday = ["日":1, "天":1, "一":2, "二":3, "三":4, "四":5, "五":6, "六":7][String(last)] {
            offset = (weekday - calendar.component(.weekday, from: now) + 7) % 7
        }
        guard let offset else { return nil }
        return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))
    }
    public static func defaultReminder(on day: Date, hour: Int, now: Date, timeZone: String) -> Date? {
        guard (0...23).contains(hour), let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), date > now else { return nil }
        return date
    }
    private static func negatesCreation(_ text: String) -> Bool {
        ["不用", "不要", "不需要", "别", "还没", "没有", "未完成", "可能", "也许", "是否", "吗"].contains(where: text.contains)
    }
    private static func safeTitle(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 60 && !["已经", "好了", "完成", "做完", "交了", "买了", "发了", "取消", "撤销", "提醒", "顺便", "和", "的时间", "如何", "怎么", "什么"].contains(where: text.contains)
    }
    private static func compact(_ input: String) -> String { input.filter { !$0.isWhitespace } }
    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(m.range, in: text) else { return nil }
        return String(text[range])
    }
}

public enum ExternalFeedback {
    public static func shouldShow(_ result: AppliedResult, previous: Workspace, proposal: Proposal) -> Bool {
        result.workspace.tasks != previous.tasks || result.workspace.questions != previous.questions
            || proposal.actions.contains { $0.kind == .alreadyCompleted || $0.kind == .undo
                || ($0.kind == .noop && (CancellationRequest.isRequest($0.evidence ?? "") || InputPolicy.isEditRequest($0.evidence ?? ""))) }
    }
}

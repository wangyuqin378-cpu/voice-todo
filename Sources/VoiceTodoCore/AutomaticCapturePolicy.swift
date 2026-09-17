import Foundation

/// A broad relevance filter, not a wake phrase. Only a live reply lease admits
/// short answers; the interpreter and reducer still decide what can be applied.
public enum AutomaticCapturePolicy {
    public static func accepts(_ input: String, answering: Bool = false) -> Bool {
        let text = input.filter { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.!！:：;；"))
        guard !text.isEmpty, text.count <= 25_000 else { return false }
        if answering && text.count <= 100 {
            if LocalInterpreter.time(text, now: .now, timeZone: TimeZone.current.identifier, requireFuture: false) != nil || NaturalTaskIntent.day(text, now: .now, timeZone: TimeZone.current.identifier) != nil { return true }
            if ["是", "是的", "对", "对的", "好", "好的", "嗯", "可以", "确认", "不用", "不用了", "不用提醒", "不需要提醒", "不要", "不是", "都还没做完"].contains(text) { return true }
            if text.range(of: #"^(?:(?:今天|明天|后天|周[一二三四五六日天]|星期[一二三四五六日天])?(?:凌晨|早上|上午|中午|下午|晚上)?[0-9零一二两三四五六七八九十点半分:：]+|今天|明天|后天|(?:不?是)?第[0-9一二三四五六七八九十]+[个条项](?:已经)?(?:好了|交了|完成了)?|不?是.{1,30}那[个条项])$"#, options: .regularExpression) != nil { return true }
        }
        if let body = CommandText.body(input), !body.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty { return true }
        // Quotations and instructions about wording are not personal plans.
        guard !["他说", "她说", "跟朋友说", "比如", "例如", "这句话", "这段话", "这段文案", "转写", "转录", "翻译", "在开头写", "“", "”", "「", "」", "\""].contains(where: text.contains) else { return false }
        if ["提醒我", "帮我提醒", "给我提醒", "记一下", "记下", "记住", "记得", "记录", "帮我安排", "给我安排", "待办", "todo", "to-do"].contains(where: text.lowercased().contains) {
            return !["提醒我", "帮我记录一下", "不用提醒", "不要提醒"].contains(text)
        }
        if InputPolicy.isUndoRequest(input) || CancellationRequest.isRequest(input) || InputPolicy.isEditRequest(input) { return true }
        let ordinary = ["天气好了", "今天天气好了", "心情好了", "网络好了", "信号好了"]
        if ordinary.contains(text) { return false }
        if ["完成了", "做完了", "交好了", "买好了", "买到了", "已经", "好了", "搞定", "办妥", "提交了", "交了", "发了", "付了", "支付了", "寄了", "报了", "取了", "收了", "洗了", "回了", "填了", "签了", "结束了", "处理完了"].contains(where: text.contains) { return true }
        // A time plus an activity, or a first-person intention, can be a task.
        // The AI sees the whole utterance, including negations and corrections.
        let time = #"今天|明天|后天|今晚|今早|稍后|等会|周[一二三四五六日天末]|星期[一二三四五六日天]|下周|下个月|[0-9一二三四五六七八九十]+月|[0-9一二两三四五六七八九十]+点"#
        let activity = #"面试|会议|开会|交|买|取|写|发|电话|预约|复诊|见|还书|缴费|报销|看医生|跑步|健身|接|寄|续费|检查|整理|准备|订|提交|联系|复习|看牙|搬家|浇花|吃药"#
        if text.range(of: time, options: .regularExpression) != nil,
           text.range(of: activity, options: .regularExpression) != nil { return true }
        if text.range(of: time.replacingOccurrences(of: "今天|", with: ""), options: .regularExpression) != nil {
            let remainder = text.replacingOccurrences(of: time, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"[0-9零一二两三四五六七八九十百半点分时刻号日:：]|凌晨|早上|上午|中午|下午|晚上"#, with: "", options: .regularExpression)
            if remainder.count >= 2, !["天气", "真好", "心情"].contains(where: remainder.contains) { return true }
        }
        if text.range(of: #"(?:我|我们)(?:还)?(?:要|得|需要|打算|计划|准备)(?!怎么|如何|什么).+"#, options: .regularExpression) != nil { return true }
        // Keep the established local grammar as an additional permissive path,
        // without treating generic UI instructions such as “新增一个按钮” as tasks.
        return !["新增", "添加", "创建", "安排"].contains(where: text.hasPrefix) && NaturalTaskIntent.candidate(input)
    }
}

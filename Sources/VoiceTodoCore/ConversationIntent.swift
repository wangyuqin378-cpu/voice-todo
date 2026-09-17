import Foundation

/// High-confidence discussion cues, shared by capture and mutation validation.
/// This is a veto for undecided plans, not a required command prefix or a full
/// semantic classifier. Unrecognized language still uses the usual interpreter.
public enum ConversationIntent {
    public static func isDiscussion(_ input: String) -> Bool {
        let text = (CommandText.body(input) ?? input).filter { !$0.isWhitespace }
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        // Talking about a command does not issue it.
        if matches(#"(?:如果|假如|要是)(?:我|用户)(?:说|输入|讲)|(?:这句话|这段话).*(?:会不会|是否|怎么|为什么)"#) { return true }

        // A deliberate request to save a conditional note remains valid. The
        // request may occur anywhere: “如果下雨就带伞，这件事帮我记下”.
        if matches(#"提醒我|(?:帮我|给我|替我)记录|(?:帮我|给我|替我)?(?:记下|记一下|记住|记录一下|记录下|记上)|(?:加到|加入|放进|记到|列入)(?:我的)?(?:待办|清单)"#) {
            return false
        }
        if matches(#"(?:^|[，,。；;！？?!])(?:那|那么|嗯|哦)?(?:我|我们)?(?:如果|假如|要是|倘若|假使|假设(?=我|明天|后天|周|下周|要|有|没有|能|不能|住|多|少))"#) {
            return true
        }
        // Advice and itinerary design are requests to an assistant, not a
        // decision to carry out the activities mentioned in that request.
        if matches(#"(?:^|[，,。；;])(?:那|那么)?(?:我|我们)?(?:应该)?(?:怎么|如何|怎样|要不要|是否)"#)
            || matches(#"(?:帮我|给我|替我)(?:再)?(?:规划|设计|推荐|比较|对比|分析).*(?:行程|旅行|旅游|路线|攻略|方案|酒店|住宿)"#)
            || matches(#"(?:帮我|给我)(?:重新|再)?安排(?:一下)?(?:行程|路线|方案|攻略)"#)
            || matches(#"(?:我想|我希望|考虑|要不要).*(?:呢|怎么样|好不好)(?:[，,。；;！？?!]|$)"#) {
            return true
        }
        return false
    }
}

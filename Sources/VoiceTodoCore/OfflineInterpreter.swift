import Foundation

/// Additional deterministic paths. Uncertain language stays available for manual
/// review; lack of an AI credential is never permission to guess an operation.
public enum OfflineInterpreter {
    public static let recoveryMessage = "这句话暂时无法自动整理，原话已保留，清单没有变化。请在“未处理记录”中修改文字或手动添加事项；完成和取消也可直接在清单操作，无需配置 AI。"

    public static func interpret(_ input: String, workspace: Workspace, question: FollowUp?,
                                 now: Date, timeZone: String, defaultReminderHour: Int = 9,
                                 defaultReminderLeadMinutes: Int = 10, allowPlainCreation: Bool = false) -> Proposal? {
        let text = (CommandText.body(input) ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 6_000, !ConversationIntent.isDiscussion(input) else { return nil }
        func checked(_ proposal: Proposal) -> Proposal? {
            let adjusted = ReminderTiming.apply(to: proposal, input: input, now: now, leadMinutes: defaultReminderLeadMinutes)
            return (try? TaskReducer.apply(adjusted, to: workspace, inputID: UUID().uuidString,
                input: input, answering: question?.id, now: now, timeZone: timeZone)) == nil ? nil : adjusted
        }
        // Do not split corrections, quotations, conditions or negative clauses:
        // accepting only the positive half can complete the wrong thing.
        guard !text.contains(where: { "\"“”‘’「」『』？?".contains($0) }),
              !["不对", "算了", "改成", "改为", "等等", "等一下", "说错", "如果", "假如", "他说", "她说", "比如", "例如", "其实", "但是", "每天", "每周", "每月"].contains(where: text.contains),
              !["还没", "没有", "未完成", "没完成", "差一点", "差点", "快做完", "别勾", "不要完成", "不用完成", "可能", "也许"].contains(where: text.contains)
        else { return nil }

        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if clauses.count > 1 {
            guard question == nil, clauses.count <= 50 else { return nil }
            var actions: [ProposedAction] = []
            for clause in clauses {
                guard input.contains(clause), let proposal = LocalInterpreter.interpret(clause, workspace: workspace,
                    question: nil, now: now, timeZone: timeZone, defaultReminderHour: defaultReminderHour,
                    defaultReminderLeadMinutes: defaultReminderLeadMinutes)
                    ?? interpret(clause, workspace: workspace, question: nil, now: now, timeZone: timeZone,
                        defaultReminderHour: defaultReminderHour, defaultReminderLeadMinutes: defaultReminderLeadMinutes,
                        allowPlainCreation: allowPlainCreation),
                      !proposal.actions.contains(where: { $0.kind == .undo || $0.kind == .setReminder }) else { return nil }
                actions += proposal.actions.map { action in var value = action; value.evidence = clause; return value }
            }
            return checked(Proposal(actions: actions))
        }

        let matches = workspace.tasks.filter { CompletionMatch.matches(text, task: $0, now: now, timeZone: timeZone) }
        if matches.count == 1, let item = matches.first {
            return checked(Proposal(actions: [.init(kind: item.isCompleted ? .alreadyCompleted : .complete,
                taskID: item.id, candidates: [item.id], evidence: text)]))
        }
        if let title = LocalInterpreter.completionTitle(text.trimmingCharacters(in: .punctuationCharacters)),
           matches.isEmpty, !workspace.tasks.contains(where: { CompletionMatch.possiblyRelated(title, $0.title) }) {
            return checked(Proposal(actions: [.init(kind: .logCompleted, title: title, candidates: [], evidence: text)]))
        }
        // Plain text explicitly entered in the app can be a task title. Never
        // apply this convenience to background dictation or a pending answer.
        if allowPlainCreation, question == nil, !NaturalTaskIntent.explicitRequest(text),
           !InputPolicy.isEditRequest(text),
           let proposal = NaturalTaskIntent.create("记下" + text, now: now, timeZone: timeZone,
               defaultReminderHour: defaultReminderHour) {
            return checked(proposal)
        }
        return nil
    }
}

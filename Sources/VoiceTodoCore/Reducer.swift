import Foundation

public enum TaskReducer {
    public static func apply(_ proposal: Proposal, to original: Workspace, inputID: String,
                             input: String, answering questionID: String? = nil,
                             now: Date = .now, inputDate: Date? = nil,
                             timeZone: String = TimeZone.current.identifier,
                             manuallySelectedTaskID: String? = nil) throws -> AppliedResult {
        if original.appliedInputs.contains(inputID) {
            return AppliedResult(workspace: original, messages: ["这段输入已经处理过了"], duplicate: true)
        }
        guard !proposal.actions.isEmpty, proposal.actions.count <= 100 else {
            throw UserFacingError("没有得到可执行的结果，原话已保留，请重试或修改文字。")
        }
        let question = original.questions.first { $0.id == questionID }
        if proposal.actions.contains(where: { $0.kind == .undo }) {
            guard proposal.actions.count == 1 else { throw UserFacingError("请单独说撤销，其他内容已保留。") }
            guard InputPolicy.isUndoRequest(input) else { throw UserFacingError("没有听到明确的撤销指令，清单没有变化。请单独说“撤销”。") }
            var result = try undo(original)
            result.workspace.appliedInputs.insert(inputID)
            return result
        }
        var state = original
        var messages: [String] = []
        for action in proposal.actions {
            try InputDateRules.validate(action, input: input, now: inputDate ?? now, timeZone: timeZone, singleCreation: proposal.actions.filter { $0.kind == .create }.count == 1)
            if let resolvedID = action.resolvesQuestionID {
                guard resolvedID == question?.id else {
                    throw UserFacingError("这条回答对应的问题已经变化，原话已保留，请重试。")
                }
                if let question, !question.taskIDs.isEmpty {
                    if let id = action.taskID, !question.taskIDs.contains(id) {
                        throw UserFacingError("这条操作不对应正在回答的任务，旧问题已保留。")
                    }
                    if action.kind == .create {
                        throw UserFacingError("新增事项不能替代已有任务的问题，原话已保留。")
                    }
                    if action.kind == .clarify, let candidates = action.candidates,
                       !Set(candidates).isSubset(of: Set(question.taskIDs)) {
                        throw UserFacingError("追问的任务范围不一致，原话已保留。")
                    }
                }
            }
            if action.noReminder == true, let time = action.reminderISO, !time.isEmpty {
                throw UserFacingError("提醒时间与不用提醒相互冲突，原话已保留。")
            }
            switch action.kind {
            case .create:
                let title = try checkedTitle(action.title)
                guard !["提醒我", "提醒我一下", "提醒", "帮我提醒一下"].contains(Self.normalized(title)) else {
                    throw UserFacingError("提醒请求缺少事项名称，未改变清单，请说明要提醒什么。")
                }
                let source = proposal.actions.filter { $0.kind == .create }.count > 1 ? (action.evidence ?? input) : input
                // A model-supplied alarm is not evidence that one was requested.
                // A follow-up can inherit the explicit request from its question.
                let reminderContext = input + (action.resolvesQuestionID == question?.id ? (question?.originalInput ?? "") : "")
                let mentionsReminder = ["提醒", "通知我", "叫我", "叫醒我"].contains(where: reminderContext.contains)
                let proposedReminder = try checkedReminder(action.reminderISO, now: now)
                let reminder = mentionsReminder ? proposedReminder : nil
                let needsTime = mentionsReminder && reminder == nil && action.noReminder != true
                    && (action.noReminder == false || NaturalTaskIntent.wantsReminder(source))
                let planned: Date?
                if let iso = action.plannedISO {
                    guard let date = Dates.parse(iso) else { throw UserFacingError("事项日期无效，原话已保留。") }
                    planned = date
                } else { planned = nil }
                let item = TodoItem(title: title, createdAt: now, reminderAt: reminder,
                                    needsReminder: needsTime, originalInput: input, plannedAt: planned, plannedHasTime: action.plannedHasTime)
                state.tasks.append(item)
                if needsTime {
                    state.questions.append(FollowUp(kind: .reminder, question: "“\(title)”什么时候提醒你？",
                                                    taskIDs: [item.id], originalInput: input))
                }
                let planText = planned.map { " · " + Dates.planned($0, hasTime: action.plannedHasTime == true) } ?? ""
                messages.append("已记下：\(title)" + planText + (reminder.map { " · \(Dates.display($0))提醒" } ?? (needsTime ? " · 待补提醒时间" : "")))
            case .complete:
                let index = try taskIndex(action.taskID, in: state)
                let id = state.tasks[index].id
                let fromSelection = action.resolvesQuestionID != nil && question?.kind == .chooseTask
                    && question?.intent == .complete && question?.taskIDs.contains(id) == true
                if fromSelection {
                    guard !containsNegation(input), !changesRequestedOperation(input) else {
                        throw UserFacingError("这句话不只是选择已完成的事项，没有勾选任何任务。")
                    }
                    let candidates = question!.taskIDs.compactMap { id in state.tasks.first { $0.id == id } }
                    guard manuallySelectedTaskID == id || CompletionMatch.selectedID(input, tasks: candidates) == id else {
                        throw UserFacingError("请点击具体事项，或说完整名称、候选序号；没有自动勾选。")
                    }
                } else {
                    try checkCompletionEvidence(action.evidence, input: input, title: state.tasks[index].title)
                    let matches = CompletionMatch.candidates(evidence: action.evidence, input: input,
                        tasks: state.tasks, now: inputDate ?? now, timeZone: timeZone)
                    guard action.candidates == [id], matches.map(\.id) == [id] else {
                        throw UserFacingError("完成内容与原事项不够对应，或存在同名事项。请说完整名称和日期，或直接在清单勾选；没有自动完成。")
                    }
                }
                if state.tasks[index].isCompleted { messages.append("已经完成过：\(state.tasks[index].title)"); continue }
                state.tasks[index].completedAt = now
                state.tasks[index].needsReminder = false
                removeCompletedTaskFromQuestions(id, in: &state)
                messages.append("已完成原待办：\(state.tasks[index].title)")
            case .cancelTask:
                let index = try taskIndex(action.taskID, in: state)
                let task = state.tasks[index]
                guard !task.isCompleted else { throw UserFacingError("这件事已在已完成列表，没有取消任何待办。") }
                if action.resolvesQuestionID != nil, let question, question.kind == .chooseTask,
                   question.intent == .cancelTask {
                    let candidates = question.taskIDs.compactMap { id in state.tasks.first { $0.id == id } }
                    guard manuallySelectedTaskID == task.id || CancellationRequest.selectedID(input, tasks: candidates) == task.id else {
                        throw UserFacingError("这句话不是明确的取消选择，清单没有变化。")
                    }
                } else {
                    let target = try CancellationRequest.validatedTarget(evidence: action.evidence, input: input,
                        now: inputDate ?? now, timeZone: timeZone)
                    let matches = state.tasks.filter { target.matches($0, timeZone: timeZone) }
                    guard !target.reminderOnly, target.exactTitle(task), matches.map(\.id) == [task.id], action.candidates == [task.id] else {
                        throw UserFacingError("还不能唯一确定要取消哪件事，清单没有变化，请补充名称和日期。")
                    }
                }
                state.tasks.remove(at: index)
                removeCompletedTaskFromQuestions(task.id, in: &state)
                messages.append("已取消：\(task.title)" + ((task.plannedAt ?? task.reminderAt).map { " · \(Dates.planned($0, hasTime: task.plannedAt == nil || task.plannedHasTime != false))" } ?? "")
                    + (task.reminderAt != nil ? "，已取消提醒" : ""))
            case .logCompleted:
                let title = try checkedTitle(action.title)
                try checkCompletionEvidence(action.evidence, input: input, title: title)
                guard CompletionMatch.candidates(evidence: action.evidence, input: input,
                    tasks: [TodoItem(title: title)], now: inputDate ?? now, timeZone: timeZone).count == 1 else {
                    throw UserFacingError("完成记录与原话不够对应，未补建记录，请补充完整名称。")
                }
                let same = state.tasks.filter { normalized($0.title) == normalized(title) }
                if let done = same.first(where: \.isCompleted) {
                    messages.append("已经完成过：\(done.title)"); continue
                }
                guard same.isEmpty, (action.candidates ?? []).isEmpty,
                      !state.tasks.contains(where: { CompletionMatch.possiblyRelated(title, $0.title) }) else {
                    throw UserFacingError("找到了相似的原待办，请明确要完成的任务，未补建记录。")
                }
                state.tasks.append(TodoItem(title: title, createdAt: now, completedAt: now, originalInput: input))
                messages.append("已补记完成记录：\(title)")
            case .setReminder:
                let index = try taskIndex(action.taskID, in: state)
                guard !state.tasks[index].isCompleted else { throw UserFacingError("这件事已经完成，不需要再设提醒。") }
                guard manuallySelectedTaskID == state.tasks[index].id || InputPolicy.canSupplyMissingReminder(input, task: state.tasks[index], question: question) else {
                    throw UserFacingError(InputPolicy.editMessage)
                }
                if action.noReminder == true, CancellationRequest.isRequest(input) {
                    let target = try CancellationRequest.validatedTarget(evidence: action.evidence ?? input, input: input,
                        now: inputDate ?? now, timeZone: timeZone)
                    guard target.reminderOnly, target.exactTitle(state.tasks[index]),
                          state.tasks.filter({ target.matches($0, timeZone: timeZone) }).map(\.id) == [state.tasks[index].id] else {
                        throw UserFacingError("还不能确定要取消哪条提醒，清单没有变化。")
                    }
                }
                let reminder = try checkedReminder(action.reminderISO, now: now)
                guard reminder != nil || action.noReminder == true else { throw UserFacingError("还需要一个具体的提醒时间，也可以说不用提醒。") }
                state.tasks[index].reminderAt = reminder
                state.tasks[index].reminderRevision = UUID().uuidString
                state.tasks[index].needsReminder = false
                let id = state.tasks[index].id
                state.questions.removeAll { $0.taskIDs.contains(id) && $0.kind == .reminder }
                messages.append("\(state.tasks[index].title) · " + (reminder.map { "\(Dates.display($0))提醒" } ?? "不提醒"))
            case .clarify:
                guard let text = action.question?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw UserFacingError("需要补充信息，但没有生成有效问题。原话已保留。")
                }
                let candidates = action.candidates ?? []
                guard Set(candidates).count == candidates.count,
                      candidates.allSatisfy({ id in state.tasks.contains { $0.id == id && !$0.isCompleted } }) else {
                    throw UserFacingError("候选任务已经发生变化，请重试。")
                }
                let inherited = action.resolvesQuestionID != nil ? question : nil
                let intent = action.clarificationIntent ?? inherited?.intent ?? .other
                guard intent != .setReminder else { throw UserFacingError(InputPolicy.editMessage) }
                if intent == .cancelTask {
                    guard inherited?.intent != .cancelTask else {
                        throw UserFacingError("请说候选的序号或完整任务名称，清单没有变化。")
                    }
                    let target = try CancellationRequest.validatedTarget(evidence: action.evidence, input: input,
                        now: inputDate ?? now, timeZone: timeZone)
                    let matches = state.tasks.filter { target.matches($0, timeZone: timeZone) }.map(\.id)
                    guard !target.reminderOnly, !candidates.isEmpty, Set(matches) == Set(candidates) else {
                        throw UserFacingError("取消候选与原话不一致，清单没有变化。")
                    }
                }
                if intent == .complete, inherited?.intent != .complete {
                    try checkCompletionEvidence(action.evidence, input: input)
                } else if intent == .complete, containsNegation(input) || changesRequestedOperation(input) {
                    throw UserFacingError("回答改变了完成意图，未勾选任何任务，请再说完整的操作。")
                }
                if let time = action.reminderISO { _ = try checkedReminder(time, now: now) }
                let follow = FollowUp(kind: candidates.isEmpty ? .clarification : .chooseTask,
                                      question: text, taskIDs: candidates, originalInput: inherited?.originalInput ?? input,
                                      intent: intent, reminderISO: action.noReminder == true ? nil : (action.reminderISO ?? inherited?.reminderISO),
                                      noReminder: action.reminderISO != nil ? false : (action.noReminder ?? inherited?.noReminder),
                                      suggestedTitle: try action.title.map { try checkedTitle($0) } ?? inherited?.suggestedTitle,
                                      plannedISO: action.plannedISO ?? inherited?.plannedISO,
                                      plannedHasTime: action.plannedHasTime ?? inherited?.plannedHasTime)
                if let resolvedID = action.resolvesQuestionID, let index = state.questions.firstIndex(where: { $0.id == resolvedID }) {
                    state.questions.insert(follow, at: index)
                } else { state.questions.append(follow) }
                messages.append(text)
            case .alreadyCompleted:
                let index = try taskIndex(action.taskID, in: state)
                guard state.tasks[index].isCompleted else { throw UserFacingError("任务状态不一致，未改变任何任务，请重试。") }
                try checkCompletionEvidence(action.evidence ?? input, input: input, title: state.tasks[index].title)
                guard CompletionMatch.candidates(evidence: action.evidence ?? input, input: input,
                    tasks: state.tasks, now: inputDate ?? now, timeZone: timeZone).map(\.id) == [state.tasks[index].id] else {
                    throw UserFacingError("无法唯一对应已完成的事项，请补充完整名称和日期。")
                }
                messages.append("已经完成过：\(state.tasks[index].title)")
            case .noop:
                if let question, action.resolvesQuestionID == question.id,
                   question.kind == .clarification, question.taskIDs.isEmpty,
                   question.suggestedTitle != nil,
                   TimedReminderRequest.ambiguousRemainder(question.originalInput) != nil,
                   TimedReminderRequest.isDecline(input) {
                    state.questions.removeAll { $0.id == question.id }
                }
                messages.append(action.question ?? "没有改变任何任务")
            case .undo: break
            }
            if let resolvedID = action.resolvesQuestionID, action.kind != .noop {
                state.questions.removeAll { $0.id == resolvedID }
            }
        }
        if state.tasks != original.tasks || state.questions != original.questions {
            state.undo.append(UndoEntry(tasks: original.tasks, questions: original.questions,
                                        summary: messages.joined(separator: "；")))
            state.undo = Array(state.undo.suffix(30))
            state.lastActivity = Activity(messages.joined(separator: "；"), date: now)
        }
        state.appliedInputs.insert(inputID)
        return AppliedResult(workspace: state, messages: messages, duplicate: false)
    }

    public static func undo(_ original: Workspace) throws -> AppliedResult {
        var state = original
        guard let entry = state.undo.popLast() else { throw UserFacingError("暂时没有可以撤销的操作。") }
        state.tasks = entry.tasks; state.questions = entry.questions
        // Restoring a completed or cancelled task creates a new notification generation,
        // including reminders already delivered before cancellation.
        for index in state.tasks.indices where !state.tasks[index].isCompleted && state.tasks[index].reminderAt != nil {
            let previous = original.tasks.first { $0.id == state.tasks[index].id }
            if previous == nil || previous?.isCompleted == true || previous?.reminderAt != state.tasks[index].reminderAt {
                state.tasks[index].reminderRevision = UUID().uuidString
            }
        }
        let summary = "已撤销：\(entry.summary)"
        state.lastActivity = Activity(summary)
        return AppliedResult(workspace: state, messages: [summary], duplicate: false)
    }

    public static func manualEdit(_ item: TodoItem, in original: Workspace, summary: String) throws -> Workspace {
        var state = original
        _ = try checkedTitle(item.title)
        let previous = original.tasks.first { $0.id == item.id }
        if !item.isCompleted, let reminder = item.reminderAt, reminder != previous?.reminderAt, reminder <= .now {
            throw UserFacingError("提醒时间已经过去，请选择未来的时间。")
        }
        if previous == item { return original }
        state.undo.append(UndoEntry(tasks: original.tasks, questions: original.questions, summary: summary))
        state.undo = Array(state.undo.suffix(30))
        if let index = state.tasks.firstIndex(where: { $0.id == item.id }) { state.tasks[index] = item }
        else { state.tasks.append(item) }
        if item.isCompleted { removeCompletedTaskFromQuestions(item.id, in: &state) }
        else if !item.needsReminder { state.questions.removeAll { $0.kind == .reminder && $0.taskIDs.contains(item.id) } }
        state.lastActivity = Activity(summary)
        return state
    }

    /// The user selected the exact row. No language matching is needed.
    public static func cancelTask(_ id: String, in original: Workspace) throws -> Workspace {
        var state = original
        let index = try taskIndex(id, in: state)
        let item = state.tasks[index]
        guard !item.isCompleted else { throw UserFacingError("这件事已经完成，未取消任何待办。") }
        let summary = "已取消：\(item.title)" + (item.reminderAt == nil ? "" : "，已取消提醒")
        state.undo.append(UndoEntry(tasks: original.tasks, questions: original.questions, summary: summary))
        state.undo = Array(state.undo.suffix(30))
        state.tasks.remove(at: index)
        removeCompletedTaskFromQuestions(id, in: &state)
        state.lastActivity = Activity(summary)
        return state
    }

    /// A clicked candidate resolves the stored operation, never an assumed completion.
    public static func selectTask(_ id: String, questionID: String, in state: Workspace,
                                  inputID: String, now: Date = .now) throws -> AppliedResult {
        if state.appliedInputs.contains(inputID) {
            return AppliedResult(workspace: state, messages: ["这段输入已经处理过了"], duplicate: true)
        }
        guard let question = state.questions.first(where: { $0.id == questionID }),
              question.kind == .chooseTask, question.taskIDs.contains(id),
              let task = state.tasks.first(where: { $0.id == id && !$0.isCompleted }) else {
            throw UserFacingError("候选任务已经发生变化，请重新选择。")
        }
        switch question.intent {
        case .cancelTask:
            return try apply(Proposal(actions: [.init(kind: .cancelTask, taskID: id, resolvesQuestionID: questionID)]),
                             to: state, inputID: inputID, input: "选择任务", answering: questionID, now: now, manuallySelectedTaskID: id)
        case .complete:
            return try apply(Proposal(actions: [.init(kind: .complete, taskID: id, resolvesQuestionID: questionID)]),
                             to: state, inputID: inputID, input: "选择任务", answering: questionID, now: now, manuallySelectedTaskID: id)
        case .setReminder:
            if question.reminderISO != nil || question.noReminder == true {
                return try apply(Proposal(actions: [.init(kind: .setReminder, taskID: id,
                    reminderISO: question.reminderISO, noReminder: question.noReminder, resolvesQuestionID: questionID)]),
                    to: state, inputID: inputID, input: "选择任务", answering: questionID, now: now, manuallySelectedTaskID: id)
            }
            var next = state
            let prompt = "“\(task.title)”什么时候提醒你？"
            next.questions.removeAll { $0.id == questionID }
            next.questions.insert(.init(kind: .reminder, question: prompt, taskIDs: [id], originalInput: question.originalInput, intent: .setReminder), at: 0)
            next.undo.append(.init(tasks: state.tasks, questions: state.questions, summary: prompt))
            next.undo = Array(next.undo.suffix(30)); next.appliedInputs.insert(inputID)
            next.lastActivity = Activity(prompt, date: now)
            return AppliedResult(workspace: next, messages: [prompt], duplicate: false)
        default:
            throw UserFacingError("请再说完整的操作，例如“签证材料已经交了”或“明天三点提醒我交签证材料”。")
        }
    }

    private static func removeCompletedTaskFromQuestions(_ id: String, in state: inout Workspace) {
        for index in state.questions.indices where state.questions[index].taskIDs.contains(id) {
            state.questions[index].taskIDs.removeAll { $0 == id }
        }
        state.questions.removeAll { $0.kind != .clarification && $0.taskIDs.isEmpty }
    }
    private static func changesRequestedOperation(_ input: String) -> Bool {
        ["提醒", "改", "推迟", "提前", "取消", "删除", "恢复", "撤销", "重做", "重新"].contains(where: input.contains)
    }

    public static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    public static func containsNegation(_ text: String) -> Bool {
        // “计划/准备” can name the work itself. Only remove those nouns when followed
        // by an explicit completed predicate; “计划明天交”“准备把材料交了” stay blocked.
        var inspected = text.lowercased().replacingOccurrences(
            of: #"(计划(?:书|表)?|准备(?:工作)?)(?=(?:(?:已经|已|刚刚|刚|早就|也|都|全部|终于))*(?:写好了|写完了|做好了|做完了|完成了|搞定了|提交好了|交好了|改好了|改完了)|(?:已经|已|刚刚|刚|早就)(?:完成|搞定|做好|写好|做完|写完))"#,
            with: "事项", options: .regularExpression)
        // A future date in the task name is different from a future action.
        inspected = inspected.replacingOccurrences(
            of: #"(明天|后天|大后天|今晚|明早|明晚|下周[一二三四五六日天]?|下个?月|明年|下次)的"#,
            with: "那次的", options: .regularExpression)
        let words = ["还没", "没有", "没完成", "未完成", "差一点", "差点", "快完成", "快做完", "快好了", "快要", "准备", "打算", "计划", "没做", "尚未", "还未", "别勾", "不要勾", "不要完成", "不用完成", "没交", "没发", "没买", "没付", "没寄", "没提交", "没报", "如果", "假如", "是否", "了吗", "了没", "可能", "应该", "也许", "等会", "待会", "稍后", "将要", "明天", "后天", "今晚", "明早", "明晚", "下周", "下个月", "下月", "明年", "下次", "做完了再", "完成了再", "？", "?", "not done", "haven't"]
        return words.contains { inspected.contains($0) }
    }

    private static func checkCompletionEvidence(_ evidence: String?, input: String, title: String? = nil) throws {
        guard let evidence, !evidence.isEmpty, input.contains(evidence) else {
            throw UserFacingError("没有找到明确的完成表述，未勾选任务。请再说具体一点。")
        }
        // Preserve question marks on their clause so a question cannot become a statement.
        let clauses = input.replacingOccurrences(of: "？", with: "？，")
            .replacingOccurrences(of: "?", with: "?,")
            .components(separatedBy: CharacterSet(charactersIn: "，,。；;！!\n"))
        let matching = clauses.filter { $0.contains(evidence) }
        guard !matching.isEmpty, matching.contains(where: { !containsNegation($0) }) else {
            throw UserFacingError("这句话里包含未完成或计划中的意思，未勾选任务。")
        }
        guard matching.contains(where: { clause in
            !containsNegation(clause) && hasCompletionStatement(clause)
        }) else { throw UserFacingError("只听到了事项名称，没有明确的完成状态，未勾选任务。") }
        if let evidenceIndex = clauses.lastIndex(where: { $0.contains(evidence) }) {
            let later = Array(clauses.dropFirst(evidenceIndex + 1))
            if let title, later.contains(where: { CompletionMatch.contradicts($0, title: title) }) {
                throw UserFacingError("后面的表述与完成状态矛盾，未勾选任务，请再说一次最终状态。")
            }
            if let correction = later.firstIndex(where: { clause in ["不对", "说错", "弄错", "其实"].contains(where: clause.contains) }),
               later.dropFirst(correction).contains(where: containsNegation) {
                throw UserFacingError("检测到后面的改口，未勾选任务，请再说一次最终状态。")
            }
        }
    }

    private static func hasCompletionStatement(_ clause: String) -> Bool {
        let completed = ["已经", "已完成", "已提交", "已发送", "已支付", "做完", "搞定", "办妥", "买到", "提交成功", "好了", "完了", "到了", "出去了",
                         "交了", "买了", "发了", "付了", "寄了", "报了", "取了", "写了", "打了", "做了", "收了", "洗了", "回了", "填了", "签了", "提交了", "完成了", "支付了", "发送了"]
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return completed.contains(where: trimmed.contains)
            || (trimmed.hasSuffix("完成") && !trimmed.hasPrefix("完成"))
    }

    private static func taskIndex(_ id: String?, in state: Workspace) throws -> Int {
        guard let id, let index = state.tasks.firstIndex(where: { $0.id == id }) else {
            throw UserFacingError("没有读取到对应任务，原话已保留，未补建完成记录。")
        }
        return index
    }
    private static func checkedTitle(_ title: String?) throws -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, title.count <= 300 else { throw UserFacingError("任务名称为空或过长，原话已保留。") }
        return title
    }
    private static func checkedReminder(_ value: String?, now: Date) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }
        guard let date = Dates.parse(value), date > now else {
            throw UserFacingError("提醒时间不明确或已经过去，请说一个未来的具体时间。")
        }
        return date
    }
}

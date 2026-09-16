import Foundation
import VoiceTodoCore

struct CaptureStatus: Equatable {
    var title: String
    var symbol: String
    var needsAttention = false
}

enum TaskPresentation {
    static func schedule(_ item: TodoItem) -> [String] {
        if let completed = item.completedAt { return ["完成于 " + Dates.display(completed)] }
        if let planned = item.plannedAt, let reminder = item.reminderAt,
           item.plannedHasTime == true, Calendar.current.isDate(planned, equalTo: reminder, toGranularity: .minute) {
            return ["安排在 \(Dates.display(planned)) · 到时提醒"]
        }
        var lines: [String] = []
        if let date = item.plannedAt { lines.append("安排在 " + Dates.planned(date, hasTime: item.plannedHasTime == true)) }
        if item.needsReminder { lines.append("提醒时间待补充") }
        else if let date = item.reminderAt { lines.append("提醒于 " + Dates.display(date)) }
        else if item.plannedAt != nil { lines.append("不提醒") }
        return lines
    }
}

enum CaptureRecovery {
    static func issue(questionID: String?, context: CaptureContext?, workspace: Workspace) -> String? {
        guard let questionID else { return nil }
        guard let question = workspace.questions.first(where: { $0.id == questionID }) else {
            return "原问题已处理或已失效。请改写成完整指令，说明事项名称和要做的操作。"
        }
        if let saved = context?.question, saved != question {
            return "原问题的内容已变化。请根据当前事项改写成完整指令。"
        }
        if let tasks = context?.relatedTasks,
           tasks.contains(where: { saved in workspace.tasks.first { $0.id == saved.id } != saved }) {
            return "相关事项已经变化。请核对当前状态，再改写成完整指令。"
        }
        return nil
    }

    static func isUnboundReply(_ text: String) -> Bool {
        ["是的", "是", "对", "对的", "好的", "好", "嗯", "嗯嗯", "没错", "可以", "确认", "不用提醒", "不用了", "不需要"].contains(TaskReducer.normalized(CommandText.body(text) ?? text))
    }
}

extension AppState {
    var captureStatus: CaptureStatus {
        if phase == .processing { return .init(title: "正在处理这句话…", symbol: "ellipsis.bubble") }
        if phase == .finishing || (receivingInputMethod && inputMethodFinishing) {
            return .init(title: "录音已结束，正在整理…", symbol: "ellipsis.bubble")
        }
        if phase == .listening || receivingInputMethod {
            if fnStarting { return .init(title: "正在打开麦克风…", symbol: "mic") }
            return .init(title: "正在听 · 再按一次结束，Esc 取消", symbol: "waveform")
        }
        if !errorMessage.isEmpty { return .init(title: "上次处理未成功 · 可查看原因", symbol: "exclamationmark.bubble", needsAttention: true) }
        if let outcome = lastVoiceOutcome { return .init(title: outcome, symbol: "bubble.left", needsAttention: outcome.contains("未听到")) }
        if !hotkeyConnected && !demo { return .init(title: "语音按键未连接 · 检查设置", symbol: "keyboard.badge.ellipsis", needsAttention: true) }
        if (!settings.useInputMethod || settings.fnLocalSpeech) && !microphoneAllowed && !demo {
            return .init(title: "需要允许麦克风 · 检查设置", symbol: "mic.slash", needsAttention: true)
        }
        if settings.useInputMethod && !settings.fnLocalSpeech && !inputMethodAllowed && !demo {
            return .init(title: "需要允许接收转写 · 检查设置", symbol: "exclamationmark.bubble", needsAttention: true)
        }
        if !pending.isEmpty { return .init(title: "有 \(pending.count) 条未处理", symbol: "exclamationmark.bubble", needsAttention: true) }
        if question != nil { return .init(title: "有问题待补充 · 打开清单继续", symbol: "bubble.left.and.bubble.right") }
        return .init(title: settings.useInputMethod ? "Fn · 开头说“提醒我”或“帮我记录一下”" : "\(settings.hotkey.label)说一句 · 再按结束", symbol: "checkmark.bubble")
    }

    func recoveryIssue(_ capture: InputCapture) -> String? {
        CaptureRecovery.issue(questionID: capture.questionID, context: captureContexts[capture.id], workspace: workspace)
    }
}

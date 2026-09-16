import SwiftUI
import VoiceTodoCore

private let ink = Color(red: 0.19, green: 0.40, blue: 0.33)

struct TaskRow: View {
    var state: AppState
    let item: TodoItem
    var edit: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Button { state.toggle(item) } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(item.isCompleted ? ink : .secondary)
                    .frame(width: 28, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(item.isCompleted ? "恢复\(item.title)" : "完成\(item.title)")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 15)).strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                ForEach(TaskPresentation.schedule(item), id: \.self) { line in
                    Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("编辑事项", action: edit)
                if !item.isCompleted {
                    if item.reminderAt != nil || item.needsReminder {
                        Button("关闭提醒，保留事项") { state.disableReminder(item) }
                    }
                    Divider()
                    Button("取消此事项", role: .destructive) { state.cancelTask(item) }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(item.title)的更多操作").help("编辑、关闭提醒或取消事项")
        }.padding(.vertical, 12).disabled(state.busy)
    }
}

struct RecentActivityView: View {
    var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.errorMessage.isEmpty {
                Label(state.errorMessage, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
            }
            if !state.message.isEmpty, let activity = state.workspace.lastActivity, state.message != activity.summary {
                Text(state.message).font(.system(size: 13)).foregroundStyle(ink).lineLimit(2)
            }
            if let activity = state.workspace.lastActivity {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近操作 · \(activity.date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(activity.summary).font(.system(size: 13)).lineLimit(3).textSelection(.enabled)
                }
            } else if !state.message.isEmpty {
                Text(state.message).font(.system(size: 13)).foregroundStyle(ink).lineLimit(3)
            }
            if let undo = state.workspace.undo.last {
                HStack(alignment: .center) {
                    Text("可撤销 · \(undo.summary)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("撤销此操作") { state.undo() }.disabled(state.busy)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PendingRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("未处理记录").font(.title3.bold())
                    Text("这些文字已保留，尚未执行成功。").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("返回清单") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if state.pending.isEmpty {
                ContentUnavailableView("全部处理好了", systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(state.pending, id: \.id) { capture in recoveryCard(capture) }
                    }
                }
            }
            if !state.errorMessage.isEmpty { Text(state.errorMessage).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3) }
        }.padding(24).frame(width: 560, height: 560).tint(ink)
    }
    private func recoveryCard(_ capture: InputCapture) -> some View {
        let context = state.captureContexts[capture.id]
        let problem = state.recoveryIssue(capture)
        return VStack(alignment: .leading, spacing: 10) {
            Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
            if let question = context?.question {
                Text("当时的问题：\(question.question)").font(.system(size: 13, weight: .medium))
                if let tasks = context?.relatedTasks, !tasks.isEmpty {
                    Text("相关事项：" + tasks.map { task in
                        task.title + ((task.plannedAt ?? task.reminderAt).map { " · " + Dates.display($0) } ?? "")
                    }.joined(separator: "；")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if capture.questionID != nil {
                Text("这是一条旧回答，未保存当时的问题内容。").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text((capture.questionID == nil ? "原话：" : "你的回答：") + capture.text).font(.system(size: 14)).textSelection(.enabled)
            if let context, context.originalText != capture.text {
                DisclosureGroup("修改前的原话") { Text(context.originalText).font(.system(size: 12)).textSelection(.enabled) }
            }
            if !capture.issue.isEmpty { Text(capture.issue).font(.system(size: 13)).foregroundStyle(.secondary) }
            if let problem { Label(problem, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange) }
            Text("直接重试沿用说话当天的日期；修改后按这次提交的日期理解。").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("重试原话") { state.retry(capture) }.disabled(problem != nil)
                Button(problem == nil ? "修改文字" : "改为完整指令") { state.editCapture(capture) }
                Spacer()
                Button("忽略此记录") { state.dismissCapture(capture) }
            }.disabled(state.busy)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

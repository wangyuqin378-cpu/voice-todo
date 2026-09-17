import SwiftUI
import VoiceTodoCore

private let accent = Color(red: 0.19, green: 0.40, blue: 0.33)

struct MainView: View {
    @Bindable var state: AppState
    var openSettings: () -> Void
    @State private var completed = false
    @State private var search = ""
    @State private var editing: TodoItem?
    @State private var showManual = false
    private var items: [TodoItem] {
        state.workspace.tasks.filter { $0.isCompleted == completed && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
            .sorted {
                if completed { return ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                return ($0.plannedAt ?? $0.reminderAt ?? .distantFuture, $0.createdAt) < ($1.plannedAt ?? $1.reminderAt ?? .distantFuture, $1.createdAt)
            }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "checkmark.bubble.fill").font(.system(size: 30)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("随口清单").font(.system(size: 23, weight: .semibold))
                    Text("想到了说一句，做完了也说一句。").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }.help("设置").accessibilityLabel("设置")
            }
            HStack {
                Label(state.captureStatus.title, systemImage: state.captureStatus.symbol)
                    .font(.system(size: 12)).foregroundStyle(state.captureStatus.needsAttention ? .orange : .secondary)
                Spacer()
                if !state.pending.isEmpty {
                    Button("查看 \(state.pending.count) 条未处理") { state.showPending = true }.controlSize(.small)
                }
            }
            HStack {
                Picker("任务状态", selection: $completed) {
                    Text("待办  \(state.workspace.tasks.filter { !$0.isCompleted }.count)").tag(false)
                    Text("已完成  \(state.workspace.tasks.filter(\.isCompleted).count)").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索", text: $search).textFieldStyle(.plain).frame(width: 120).accessibilityLabel("搜索任务")
            }
            if state.phase == .listening || state.phase == .finishing { RecorderControls(state: state) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty { emptyList }
                    ForEach(items) { item in
                        TaskRow(state: state, item: item, edit: { editing = item })
                        Divider().opacity(0.5)
                    }
                }
            }.frame(maxHeight: .infinity)
            if let question = state.question { QuestionView(state: state, question: question) }
            RecentActivityView(state: state)
            if !state.understandingNotice.isEmpty {
                Button(state.understandingNotice) { openSettings() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if state.waitingForAI { AIWaitingView(state: state) }
            composer
            if !state.reminderWarning.isEmpty {
                Button(state.reminderWarning) { openSettings() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.orange)
            }
            if !state.hotkeyConnected && !state.demo {
                Button("语音按键未连接 · 检查设置") { openSettings() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.orange)
            }
            if state.demo { Text("界面预览 · 示例数据").font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(minWidth: 570, minHeight: 570).background(Color(nsColor: .windowBackgroundColor)).tint(accent)
            .sheet(item: $editing) { item in
                EditView(item: item, isNew: false, state: state) { state.edit($0, mustExist: true, expected: item) }
            }
            .sheet(isPresented: $showManual) {
                EditView(item: TodoItem(title: ""), isNew: true, state: state) { state.edit($0, message: "已手动添加") }
            }
            .sheet(isPresented: $state.showPending) { PendingRecoveryView(state: state) }
    }
    private var emptyList: some View {
        VStack(spacing: 12) {
            Image(systemName: completed ? "checkmark.circle" : "waveform").font(.system(size: 32, weight: .light)).foregroundStyle(accent)
            Text(search.isEmpty ? (completed ? "做完的事，会留在这里。" : "把惦记的事，说出来。") : "没有找到这件事").font(.system(size: 15, weight: .medium))
            if search.isEmpty && !completed {
                Text(state.settings.useInputMethod ? "用语音输入说“明天下午三点面试，提醒我一下”。\n做完说“面试完成了”，无需固定开头。" : "轻按\(state.settings.hotkey.label)开始，再按结束。\n也可以按住说话，松开结束。")
                    .multilineTextAlignment(.center).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 40)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.settings.useInputMethod {
                Text("说确定的安排、提醒或完成，无需固定开头。假设和询问方案不自动记下。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let id = state.editingCaptureID, let capture = state.pending.first(where: { $0.id == id }) {
                HStack {
                    Text(state.recoveryIssue(capture) == nil ? "正在修改未处理记录" : "请改写为完整指令，原问题已变化").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("放弃此次修改") { state.editingCaptureID = nil; state.draft = "" }.controlSize(.small)
                }
            }
            ZStack(alignment: .topLeading) {
                if state.draft.isEmpty {
                    Text(state.question == nil ? "手动输入例：材料交好了，明天下午三点提醒我买牛奶" : "回答上面的问题，或说一件新事情…")
                        .foregroundStyle(.secondary).padding(.top, 5).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $state.draft).font(.system(size: 13)).scrollContentBackground(.hidden).frame(height: 56).accessibilityLabel("输入待办或完成情况")
            }
            HStack {
                Button { state.toggleRecording() } label: {
                    Label(state.phase == .listening || state.receivingInputMethod ? (state.receivingInputMethod && !state.settings.fnLocalSpeech ? "取消接收" : "结束并处理") : "开始录音",
                          systemImage: state.phase == .listening || state.receivingInputMethod ? "stop.fill" : "mic.fill")
                }.disabled(state.phase == .finishing || state.inputMethodFinishing || (state.phase == .processing && !state.receivingInputMethod))
                Spacer()
                Button("手动添加") { showManual = true }.disabled(state.busy)
                Button("处理文字") { state.submitDraft() }.buttonStyle(.borderedProminent).tint(accent)
                    .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.busy)
                    .keyboardShortcut(.return, modifiers: .command).help("⌘ Return 整理并处理")
            }
        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct QuestionView: View {
    var state: AppState
    let question: FollowUp
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(question.question, systemImage: "bubble.left").font(.system(size: 13, weight: .medium))
            if question.kind == .chooseTask {
                ForEach(question.taskIDs, id: \.self) { id in
                    if let task = state.workspace.tasks.first(where: { $0.id == id }) {
                        Button(task.title + ((task.plannedAt ?? task.reminderAt).map {
                            " · " + Dates.planned($0, hasTime: task.plannedAt == nil || task.plannedHasTime != false)
                        } ?? "")) { state.choose(id, questionID: question.id) }
                    }
                }
            }
            HStack {
                Text(state.settings.useInputMethod
                     ? "用 Fn 说“清单”加上你的回答，例如“清单，明天下午三点”"
                     : "按住同一个键回答").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if question.kind == .reminder { Button("不用提醒") { state.submit("不用提醒", answerID: question.id) }.font(.system(size: 11)) }
            }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)).disabled(state.busy)
    }
}

struct EditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: TodoItem
    let isNew: Bool
    var state: AppState
    var sourceText: String? = nil
    var save: (TodoItem) -> Bool
    @State private var wantsReminder = false
    @State private var date = Date.now.addingTimeInterval(3600)
    @State private var hasPlannedDate = false
    @State private var hasPlannedTime = false
    @State private var plannedDate = Date.now
    @State private var reminderManuallySet = false
    private func suggestNewReminder() {
        guard isNew, wantsReminder, hasPlannedDate, !reminderManuallySet else { return }
        let suggested = hasPlannedTime
            ? plannedDate.addingTimeInterval(-Double(state.settings.defaultReminderLeadMinutes * 60))
            : NaturalTaskIntent.defaultReminder(on: plannedDate, hour: state.settings.defaultReminderHour, now: .now, timeZone: TimeZone.current.identifier)
        if let suggested { date = max(suggested, Date.now.addingTimeInterval(60)) }
    }
    private var selectedMinute: Date { Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date }
    private var reminderChanged: Bool { item.needsReminder || wantsReminder != (item.reminderAt != nil) || (wantsReminder && date != item.reminderAt) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "添加一件事" : "修改这件事").font(.title3.bold())
            if let sourceText {
                Text("参考原话，手动填写一件事。原记录仍会保留，整理完后可忽略；完成或取消请直接在清单操作。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView { Text(sourceText).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 90)
            }
            TextField("任务名称", text: $item.title).textFieldStyle(.roundedBorder)
            if !item.isCompleted {
                Toggle("事项日期", isOn: $hasPlannedDate)
                if hasPlannedDate {
                    DatePicker("安排在", selection: $plannedDate, displayedComponents: hasPlannedTime ? [.date, .hourAndMinute] : [.date])
                    Toggle("包含具体时刻", isOn: $hasPlannedTime)
                }
                Toggle("提醒我", isOn: $wantsReminder)
                if wantsReminder {
                    DatePicker("提醒时间", selection: Binding(get: { date }, set: { date = $0; reminderManuallySet = true }), displayedComponents: [.date, .hourAndMinute])
                    if selectedMinute <= .now { Text(reminderChanged ? "请选择未来的提醒时间。" : "这是原来的提醒时间；只改标题不会重新安排提醒。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !state.errorMessage.isEmpty { Text(state.errorMessage).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer(); Button("放弃修改") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !item.isCompleted {
                        item.plannedAt = hasPlannedDate ? (hasPlannedTime ? Calendar.current.dateInterval(of: .minute, for: plannedDate)?.start : Calendar.current.startOfDay(for: plannedDate)) : nil
                        item.plannedHasTime = hasPlannedDate ? hasPlannedTime : nil
                    }
                    if !item.isCompleted && reminderChanged {
                        let newDate = wantsReminder ? selectedMinute : nil
                        if newDate != item.reminderAt { item.reminderRevision = UUID().uuidString }
                        item.reminderAt = newDate; item.needsReminder = false
                    }
                    if save(item) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (wantsReminder && reminderChanged && selectedMinute <= .now))
            }
        }.padding(24).frame(width: 410).onAppear {
            wantsReminder = item.reminderAt != nil; date = item.reminderAt ?? date
            hasPlannedDate = item.plannedAt != nil; hasPlannedTime = item.plannedHasTime == true
            plannedDate = item.plannedAt ?? plannedDate
        }
        .onChange(of: wantsReminder) { suggestNewReminder() }
        .onChange(of: plannedDate) { suggestNewReminder() }
        .onChange(of: hasPlannedDate) { suggestNewReminder() }
        .onChange(of: hasPlannedTime) { suggestNewReminder() }
    }
}

struct SettingsView: View {
    @Bindable var state: AppState
    @Bindable var settings: AppSettings
    @State private var apiKey = ""
    @State private var changingAI = false
    @State private var newBaseURL = ""
    @State private var newModel = ""
    @State private var newProtocol: AIProtocol = .automatic
    var close: () -> Void
    private var entryMode: Binding<Int> {
        Binding(get: { !settings.useInputMethod ? 2 : (settings.fnLocalSpeech ? 0 : 1) }, set: { value in
            settings.useInputMethod = value != 2
            settings.fnLocalSpeech = value == 0
            state.changedInputMethod()
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(settings.onboardingDone ? "设置" : "先准备好，再说第一句").font(.system(size: 24, weight: .semibold))
                voiceSettings
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("事项和提醒分开").font(.headline)
                        Text("只记事项时不会提醒。明确说“提醒我”，才安排通知。").font(.system(size: 13))
                        Picker("有具体时间时", selection: $settings.defaultReminderLeadMinutes) {
                            Text("提前 5 分钟").tag(5)
                            Text("提前 10 分钟（默认）").tag(10)
                            Text("提前 15 分钟").tag(15)
                            Text("提前 30 分钟").tag(30)
                            Text("提前 1 小时").tag(60)
                            Text("到时间提醒").tag(0)
                        }
                        Text("例如下午 1 点面试，默认 12:50 提醒。明确指定提醒时间时按原话；不足提前量时立即提醒。仅对新建事项生效。").font(.system(size: 12)).foregroundStyle(.secondary)
                        Picker("只给日期时，提醒时间", selection: $settings.defaultReminderHour) {
                            Text("上午 9:00").tag(9)
                            Text("上午 10:00").tag(10)
                            Text("问我具体时间").tag(-1)
                        }
                        Text("例如“提醒我明天报销”，会按这里的时间提醒，并显示具体时间。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                permissions
                aiSettings
                HStack {
                    Text("原始录音不保存。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(settings.onboardingDone ? "完成" : "进入清单") { settings.onboardingDone = true; close() }
                        .buttonStyle(.borderedProminent).tint(accent)
                }
            }.padding(26)
        }.frame(width: 570, height: 750).tint(accent)
            .task {
                newBaseURL = settings.baseURL; newModel = settings.model; newProtocol = settings.apiProtocol
                if !state.demo { await state.refreshPermissions() }
            }
    }
    private var voiceSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("说一句，记下或勾掉").font(.headline)
                Text(settings.useInputMethod ? "轻按 Fn 开始，再按一次结束；按住说话也可以，松开结束。Esc 取消。" : "轻按\(settings.hotkey.label)开始，再按一次结束；也可以按住说话，松开结束。Esc 取消。")
                    .font(.system(size: 13))
                Text("普通转写不弹窗、不保存。识别到事项操作后显示结果；未成功的文字可在清单中处理。").font(.system(size: 13)).foregroundStyle(.secondary)
                if settings.useInputMethod {
                    Text("不用固定开头：个人安排、提醒、完成、取消都可自然表达，提醒放在句尾也可以。识别到相关意图才处理，普通聊天保持安静；简单事项直接在本机处理，复杂表达才请 AI 帮忙，无需为每句话等待网络。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Text("同名事项也会新增。已有事项的时间和提醒请在清单中手动编辑；语音完成需名称完整对应且唯一匹配。").font(.system(size: 13)).foregroundStyle(.secondary)
                Label(state.captureStatus.title, systemImage: state.captureStatus.symbol).font(.system(size: 13))
                Toggle("需要追问时读出问题", isOn: $settings.speakQuestions)
                DisclosureGroup("语音入口与诊断") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("使用方式", selection: entryMode) {
                            Text("Fn · 本机识别（推荐）").tag(0)
                            Text("Fn · 接收输入法文字（试验）").tag(1)
                            Text("独立录音按键").tag(2)
                        }.disabled(state.busy || state.receivingInputMethod)
                        if !settings.useInputMethod {
                            Picker("录音按键", selection: $settings.hotkey) { ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) } }
                                .onChange(of: settings.hotkey) { state.changedHotkey() }
                        }
                        Text(settings.fnLocalSpeech && settings.useInputMethod ? "Fn 同时启动本机识别，原输入法照常工作；仅本次录音使用麦克风，不读取其他应用文本。" : "接收方式的支持程度取决于输入法和当前输入框。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(state.inputMethodStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(state.hotkeyConnected ? "键盘入口已连接" : "键盘入口未连接").font(.system(size: 12))
                        if let detected = state.lastHotkeyDetected {
                            Text("最近按键：\(detected.formatted(date: .omitted, time: .standard))").font(.system(size: 12))
                        }
                        Text(state.captureDiagnosticSummary).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("诊断只记录步骤，不保存转写内容。键盘已连接不代表已经成功记下一件事。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var permissions: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("语音与提醒权限").font(.headline)
                if !settings.useInputMethod || settings.fnLocalSpeech {
                    permission("麦克风", detail: "仅在你主动录音时使用", allowed: state.microphoneAllowed, action: state.requestMicrophone)
                } else {
                    permission("辅助功能", detail: "接收当前输入框的转写文字", allowed: state.inputMethodAllowed, action: state.requestInputMethod)
                }
                permission("输入监控", detail: "识别录音按键，不保存键盘输入", allowed: state.hotkeyAllowed, action: state.requestHotkey)
                permission("系统通知", detail: "关闭时仍可记事，但不能弹出提醒", allowed: state.notificationsAllowed, action: state.requestNotifications)
                if !settings.useInputMethod || settings.fnLocalSpeech {
                    HStack {
                        Text(state.modelStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("检查中文模型") { state.installModel() }
                    }
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var aiSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI 增强（可选）").font(.headline)
                Text("不填 API Key 也能创建、完成、取消和提醒。无法自动理解的原话会保留，可修改或手动整理。").font(.system(size: 13)).foregroundStyle(.secondary)
                Text("简单提醒、完成等操作先在本机处理。只有本机无法理解时才请求 AI，最多等待 8 秒，可随时停止；超时原话保留。调用 AI 时会发送本次文字及清单中的事项名称、日期和完成状态；原始录音不会上传。").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("当前模型：\(settings.model)").font(.system(size: 13))
                if AIKey.hasLocalReference {
                    Text("使用本机已有配置，无需再次填写 API Key。").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                HStack {
                    Button(state.checkingConnection ? "正在检查…" : "检查当前连接") { state.checkLocalConnection() }.disabled(state.checkingConnection || state.demo)
                    Text(state.connectionStatus).font(.system(size: 12)).foregroundStyle(state.connectionOK ? accent : .secondary)
                }
                DisclosureGroup("更换 AI 配置", isExpanded: $changingAI) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("密钥只在连接检查成功后替换，保存在系统钥匙串。").font(.system(size: 12)).foregroundStyle(.secondary)
                        SecureField("新的 API Key", text: $apiKey).accessibilityLabel("新的 AI API Key")
                        Picker("接口类型", selection: $newProtocol) {
                            ForEach(AIProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Text("Key 是访问凭证，不决定模型。请填写服务商提供的地址和模型；不要求模型名称包含 flash。自动模式识别官方 Claude 地址，其他地址默认 OpenAI 兼容接口。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("接口地址（HTTPS）", text: $newBaseURL)
                        TextField("模型名称", text: $newModel)
                        Button("检查并保存新密钥") { state.checkConnection(key: apiKey, configuration: .init(baseURL: newBaseURL, model: newModel, apiProtocol: newProtocol)) }
                            .disabled(state.checkingConnection || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.demo)
                    }.textFieldStyle(.roundedBorder).padding(.top, 10)
                }.disabled(state.checkingConnection)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func permission(_ name: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) { Text(name).font(.system(size: 13)); Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer()
            if allowed { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).accessibilityLabel("\(name)已允许") }
            else { Button("允许", action: action).disabled(state.demo).accessibilityLabel("允许\(name)") }
        }
    }
}

struct AIWaitingView: View {
    var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(state.aiWaitingMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("停止等待") { state.stopWaitingForAI() }.controlSize(.small)
        }
    }
}

struct OverlayView: View {
    var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: state.phase == .listening ? "waveform" : (state.errorMessage.isEmpty ? "checkmark.bubble" : "exclamationmark.circle"))
                    .foregroundStyle(state.phase == .listening ? .orange : accent)
                Text(state.busy ? phaseText(state.phase) : (!state.errorMessage.isEmpty ? "未处理成功" : (state.overlayQuestion != nil ? "再补充一句" : "处理结果"))).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { state.cancelRecording() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭浮窗")
            }
            if state.phase == .listening || state.phase == .finishing || state.phase == .processing {
                if state.phase == .processing {
                    Text(state.transcript).font(.system(size: 15)).lineLimit(5)
                    if state.waitingForAI { AIWaitingView(state: state) }
                    else { Text("正在本机处理").font(.system(size: 11)).foregroundStyle(.secondary) }
                } else { RecorderControls(state: state) }
            } else {
                if !state.errorMessage.isEmpty { Text(state.errorMessage).font(.system(size: 13)).foregroundStyle(.red).lineLimit(4) }
                if !state.message.isEmpty { Text(state.message).font(.system(size: 13)).lineLimit(5) }
                if state.errorMessage.isEmpty, let question = state.overlayQuestion { QuestionView(state: state, question: question) }
                HStack {
                    Button("查看清单") { state.openList?() }.font(.system(size: 11))
                    if state.errorMessage.isEmpty, state.message == state.workspace.undo.last?.summary {
                        Button("撤销此操作") { state.undo() }.font(.system(size: 12))
                    }
                    Spacer()
                    if let elapsed = state.elapsed { Text(String(format: "%.1f 秒", elapsed)).font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
            }
        }.padding(18).frame(width: 380).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 1)).padding(10).tint(accent)
    }
}

struct RecorderControls: View {
    var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(state.recordingReady && state.phase == .listening ? Color.red : .orange).frame(width: 9, height: 9)
                Text(state.phase == .finishing ? "录音已结束，正在整理" : (state.recordingReady ? "正在录音" : "正在打开麦克风…"))
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if let started = state.recordingStartedAt, state.phase == .listening {
                    Text(started, style: .timer).monospacedDigit().font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
            Text(state.transcript.isEmpty ? "说要做的事，或已经做完的事…" : state.transcript)
                .font(.system(size: 15)).foregroundStyle(state.transcript.isEmpty ? .secondary : .primary).lineLimit(4)
            if state.phase == .listening {
                Text(state.holdToTalk ? "松开录音键结束，也可以点击下面的按钮。" : "再轻按一次录音键，或点击“结束并处理”。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { state.endRecording() } label: { Label("结束并处理", systemImage: "stop.fill").font(.system(size: 14, weight: .medium)) }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.large).disabled(state.phase != .listening)
                Button("取消 · Esc") { state.cancelRecording() }.controlSize(.large)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

private func phaseText(_ phase: AppState.Phase) -> String {
    switch phase { case .idle: "准备好了"; case .listening: "正在听"; case .finishing: "正在整理语音"; case .processing: "正在理解并处理" }
}

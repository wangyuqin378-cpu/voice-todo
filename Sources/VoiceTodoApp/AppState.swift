import AppKit
import Observation
import VoiceTodoCore

@MainActor @Observable final class AppState {
    enum Phase { case idle, listening, finishing, processing }
    var workspace: Workspace
    var pending: [InputCapture] = []
    var captureContexts: [String: CaptureContext] = [:]
    var showPending = false
    var phase: Phase = .idle
    var transcript = ""
    var message = ""
    var errorMessage = ""
    var reminderWarning = ""
    var connectionStatus = "尚未检查"
    var connectionOK = false
    var checkingConnection = false
    var microphoneAllowed = SpeechService.microphoneAllowed
    var hotkeyAllowed = GlobalHotkey.allowed
    var hotkeyConnected = false
    var inputMethodAllowed = InputMethodBridge.allowed
    var inputMethodStatus = "Fn 后台接收 · 只处理开头口令"
    var receivingInputMethod = false
    var inputMethodFinishing = false
    var fnStarting = false
    var lastVoiceOutcome: String?
    var captureDiagnosticSummary = "尚无接收记录"
    var lastHotkeyDetected: Date?
    var hotkeyDiagnostic = ""
    var recordingReady = false
    var recordingStartedAt: Date?
    var holdToTalk = false
    var notificationsAllowed = false
    var modelStatus = "简体中文 · 本机识别"
    var elapsed: Double?
    var draft: String { didSet { settings.defaults.set(draft, forKey: "composer.draft") } }
    var editingCaptureID: String? { didSet { settings.defaults.set(editingCaptureID, forKey: "composer.captureID") } }
    let settings: AppSettings
    let demo: Bool
    @ObservationIgnored let repository: Repository
    @ObservationIgnored let speech = SpeechService()
    @ObservationIgnored let speaker = QuestionSpeaker()
    @ObservationIgnored let hotkey = GlobalHotkey()
    @ObservationIgnored let inputMethod = InputMethodBridge()
    @ObservationIgnored let fnSpeech: FnSpeechCapture
    @ObservationIgnored let notifications: any TaskNotifications
    @ObservationIgnored var showOverlay: (() -> Void)?
    @ObservationIgnored var hideOverlay: (() -> Void)?
    @ObservationIgnored var openList: (() -> Void)?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var releaseRequested = false
    @ObservationIgnored private var recordingLimit: Task<Void, Never>?
    @ObservationIgnored private var releasedAt: Date?
    var question: FollowUp? { workspace.questions.first }
    var overlayQuestionID: String?
    var overlayQuestion: FollowUp? { workspace.questions.first { $0.id == overlayQuestionID } }
    var busy: Bool { phase != .idle }

    init(repository: Repository, settings: AppSettings, demo: Bool = false, notifications: (any TaskNotifications)? = nil, captureDiagnostics: CaptureDiagnostics? = nil, hotkeyDiagnostics: HotkeyDiagnostics? = nil, fnSpeechCapture: FnSpeechCapture? = nil) throws {
        self.repository = repository; self.settings = settings; self.demo = demo
        self.notifications = notifications ?? NotificationService()
        inputMethod.diagnostics = captureDiagnostics
        fnSpeech = fnSpeechCapture ?? FnSpeechCapture()
        fnSpeech.diagnostics = captureDiagnostics
        draft = settings.defaults.string(forKey: "composer.draft") ?? ""
        editingCaptureID = settings.defaults.string(forKey: "composer.captureID")
        workspace = try repository.load()
        pending = try repository.pending()
        captureContexts = Dictionary(uniqueKeysWithValues: pending.compactMap { capture in
            (try? repository.captureContext(for: capture)).map { (capture.id, $0) }
        })
        if demo {
            workspace = Workspace(tasks: [
                TodoItem(title: "交项目材料", reminderAt: Date.now.addingTimeInterval(86400)),
                TodoItem(title: "买牛奶", reminderAt: Date.now.addingTimeInterval(3600)),
                TodoItem(title: "整理这周的报销", needsReminder: true),
                TodoItem(title: "给家里打电话", completedAt: .now)
            ])
            settings.onboardingDone = true
        }
        captureDiagnosticSummary = captureDiagnostics?.summary ?? "尚无接收记录"
        captureDiagnostics?.onChange = { [weak self] in self?.captureDiagnosticSummary = $0 }
        inputMethod.applicationActivated(NSWorkspace.shared.frontmostApplication)
        speech.onText = { [weak self] in self?.transcript = $0 }
        speech.onFailure = { [weak self] text in self?.recoverRecording(message: text) }
        hotkey.onStart = { [weak self] in
            guard let self, !self.busy else { return false }
            self.startRecording(fromShortcut: true, holding: true)
            return self.recordingID != nil
        }
        hotkey.onTap = { [weak self] in
            guard let self else { return }
            if self.phase == .listening { self.endRecording() }
            else { self.startRecording(fromShortcut: true) }
        }
        hotkey.onLatch = { [weak self] in self?.holdToTalk = false }
        hotkey.onEnd = { [weak self] in self?.endRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        hotkey.onDetected = { [weak self] in self?.lastHotkeyDetected = .now }
        hotkey.onDiagnostic = { [weak self] in self?.hotkeyDiagnostic = $0 }
        hotkey.onConnection = { [weak self] connected in
            guard let self else { return }
            self.hotkeyConnected = connected
            hotkeyDiagnostics?.connection(connected, detail: self.hotkey.connectionDetail, inputMethodEnabled: self.hotkey.useInputMethod)
        }
        hotkey.onReceipt = { source, outcome, fnDown, aheadBy in
            hotkeyDiagnostics?.receive(source: source, outcome: outcome, fnDown: fnDown, timestampAheadBy: aheadBy)
        }
        hotkey.onFnPress = { [weak self] in
            guard let self, !self.demo else { return }
            if self.settings.fnLocalSpeech {
                guard self.phase != .listening && self.phase != .finishing else { return }
                self.fnSpeech.press()
            } else { self.inputMethod.press() }
        }
        hotkey.onFnRelease = { [weak self] in
            guard let self else { return }
            if self.settings.fnLocalSpeech { self.fnSpeech.release() }
            else { self.inputMethod.release() }
        }
        hotkey.onExternalCancel = { [weak self] in self?.inputMethod.cancel(); self?.fnSpeech.cancel() }
        hotkey.onManualCopy = { [weak self] in self?.inputMethod.manualCopy() }
        inputMethod.onBegin = { [weak self] in
            guard let self else { return }
            self.speaker.stop(); self.receivingInputMethod = true; self.inputMethodFinishing = false
            self.lastVoiceOutcome = nil
            if !self.busy { self.message = ""; self.errorMessage = ""; self.elapsed = nil }
            self.hideOverlay?()
        }
        inputMethod.onEnd = { [weak self] in
            guard let self else { return }
            self.receivingInputMethod = false
            if !self.busy { self.hideOverlay?() }
        }
        inputMethod.onFinished = { [weak self] in self?.inputMethodFinishing = true }
        inputMethod.onStatus = { [weak self] in self?.inputMethodStatus = $0 }
        inputMethod.onProblem = { [weak self] text in
            self?.inputMethodStatus = text
            self?.lastVoiceOutcome = text
        }
        inputMethod.currentQuestionID = { [weak self] in self?.overlayQuestion?.id }
        inputMethod.onCommand = { [weak self] text, id, questionID in self?.enqueueExternal(text, id: id, answerID: questionID) }
        fnSpeech.currentQuestionID = { [weak self] in self?.overlayQuestion?.id }
        fnSpeech.onBegin = { [weak self] in
            guard let self else { return }
            self.speaker.stop(); self.hideOverlay?()
            self.lastVoiceOutcome = nil
            if !self.busy { self.message = ""; self.errorMessage = ""; self.elapsed = nil }
        }
        fnSpeech.onState = { [weak self] phase in
            self?.receivingInputMethod = phase != .idle
            self?.inputMethodFinishing = phase == .finishing
            self?.fnStarting = phase == .starting
        }
        fnSpeech.onStatus = { [weak self] text in
            self?.inputMethodStatus = text
            if text.contains("未听到文字") { self?.lastVoiceOutcome = "本次未听到文字 · 可再说一次" }
            else if text.contains("普通转写") { self?.lastVoiceOutcome = "开头没有清单口令 · 未保存" }
        }
        fnSpeech.onCommand = { [weak self] text, id, questionID in self?.enqueueExternal(text, id: id, answerID: questionID) }
        fnSpeech.onFailure = { [weak self] text, id, message, questionID in
            guard let self else { return }
            self.lastVoiceOutcome = message
            // Background dictation without an explicit opening stays quiet,
            // including partial speech interrupted before recognition finishes.
            guard AutomaticCapturePolicy.accepts(text) else { return }
            do {
                let capture = try self.repository.capture(text, questionID: questionID, id: "external-" + id)
                try self.repository.fail(capture, message: message)
                try self.reloadPending()
                self.errorMessage = message
            } catch { self.errorMessage = "语音候选文字未能保存，请重试。" }
            self.showOverlay?()
        }
        self.notifications.onStatus = { [weak self] in self?.reminderWarning = $0 ?? "" }
        self.notifications.onOpen = { [weak self] in self?.openList?() }
    }

    func activate() {
        guard !demo else { return }
        if settings.fnLocalSpeech { inputMethodStatus = "Fn 本机识别 · 只处理开头口令" }
        hotkey.choice = settings.hotkey
        hotkey.useInputMethod = settings.useInputMethod
        hotkeyConnected = hotkey.install()
        processNextQueued()
        Task { await refreshPermissions(); await notifications.reconcile(workspace.tasks) }
    }
    func refreshPermissions() async {
        guard !demo else { return }
        microphoneAllowed = SpeechService.microphoneAllowed
        hotkeyAllowed = GlobalHotkey.allowed
        inputMethodAllowed = InputMethodBridge.allowed
        hotkey.useInputMethod = settings.useInputMethod
        let notificationStatus = await notifications.authorization()
        notificationsAllowed = notificationStatus == .authorized || notificationStatus == .provisional
        hotkey.choice = settings.hotkey; hotkeyConnected = hotkey.install()
    }
    func reconcile() { if !demo { Task { await refreshPermissions(); await notifications.reconcile(workspace.tasks) } } }
    func changedHotkey() { hotkey.reset(); hotkey.choice = settings.hotkey }
    func changedInputMethod() {
        hotkey.reset(); inputMethod.cancel(); fnSpeech.cancel()
        hotkey.useInputMethod = settings.useInputMethod
        inputMethodStatus = settings.fnLocalSpeech ? "Fn 同时本机识别 · 只在录音期间使用麦克风" : "Fn 后台接收 · 识别到待办后才显示"
    }
    var awaitingFnReply: Bool { settings.fnLocalSpeech ? fnSpeech.awaitingReply : inputMethod.awaitingReply }
    func requestInputMethod() {
        InputMethodBridge.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func sleep() { cancelRecording(); hotkey.reset(clearHeldKeys: true) }

    func startRecording(fromShortcut: Bool = false, holding: Bool = false) {
        guard !busy else { return }
        fnSpeech.cancel(); inputMethod.cancel()
        speaker.stop(); message = ""; errorMessage = ""; transcript = ""; elapsed = nil
        if demo { message = "这是界面预览，实际录音请使用正式窗口。"; showOverlay?(); return }
        guard microphoneAllowed else { errorMessage = "请在设置中允许麦克风访问。"; showOverlay?(); return }
        let token = UUID(); recordingID = token; releaseRequested = false; recordingReady = false
        recordingStartedAt = .now; holdToTalk = holding
        phase = .listening; showOverlay?()
        recordingLimit = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, recordingID == token, !recordingReady else { return }
            recoverRecording(message: "麦克风或语音模型启动超时，请检查设备后重试。")
        }
        recordingTask = Task {
            do {
                guard recordingID == token, !Task.isCancelled else { return }
                if releaseRequested {
                    recordingID = nil; recordingLimit?.cancel(); phase = .idle
                    message = "本次录音尚未启动，请重新说一次。"; showOverlay?(); processNextQueued(); return
                }
                try await speech.start()
                guard recordingID == token, !Task.isCancelled else { return }
                recordingReady = true
                if fromShortcut { settings.shortcutExperienced = true }
                recordingLimit?.cancel()
                if releaseRequested { finishRecording(token) }
                else {
                    recordingLimit = Task {
                        try? await Task.sleep(for: .seconds(90))
                        guard !Task.isCancelled, recordingID == token else { return }
                        endRecording()
                    }
                }
            } catch {
                guard recordingID == token else { return }
                recordingID = nil; speech.cancel(); phase = .idle
                errorMessage = friendly(error); showOverlay?(); processNextQueued()
            }
        }
    }
    func endRecording() {
        guard let token = recordingID, phase == .listening else { return }
        releaseRequested = true; releasedAt = .now
        speech.stopInput()
        phase = .finishing
        if recordingReady { finishRecording(token) }
    }
    private func finishRecording(_ token: UUID) {
        recordingLimit?.cancel()
        Task {
            do {
                let words = try await speech.finish()
                guard recordingID == token else { return }
                recordingID = nil; phase = .idle
                if words.isEmpty { message = "没有听清。轻按录音键开始，说完后再轻按一次结束。"; showOverlay?(); processNextQueued() }
                else { submit(words) }
            } catch {
                guard recordingID == token else { return }
                recoverRecording(message: "语音识别没有完整结束，已识别文字已保留，请检查后重试。")
            }
        }
    }
    private func recoverRecording(message: String) {
        let words = speech.text
        recordingID = nil; recordingTask?.cancel(); recordingLimit?.cancel(); speech.cancel(); phase = .idle
        recordingReady = false; releasedAt = nil
        do {
            if !words.isEmpty {
                let input = try repository.capture(words, questionID: question?.id)
                try repository.fail(input, message: message)
                try reloadPending()
            }
            errorMessage = message
        } catch { errorMessage = "文字保存失败：\(friendly(error))。请复制浮窗中的原文。" }
        showOverlay?()
        processNextQueued()
    }
    func cancelRecording() {
        inputMethod.cancel()
        fnSpeech.cancel()
        guard phase == .listening || phase == .finishing else { speaker.stop(); hideOverlay?(); return }
        recordingID = nil; recordingTask?.cancel(); recordingLimit?.cancel(); speech.cancel(); speaker.stop()
        recordingReady = false; releasedAt = nil
        phase = .idle; transcript = ""; message = "已取消录音"; hideOverlay?(); processNextQueued()
    }
    func toggleRecording() {
        if fnSpeech.active { fnSpeech.end() }
        else if receivingInputMethod { inputMethod.cancel() }
        else if phase == .listening { endRecording() }
        else { startRecording() }
    }

    private func reloadPending() throws {
        pending = try repository.pending()
        captureContexts = Dictionary(uniqueKeysWithValues: pending.compactMap { capture in
            (try? repository.captureContext(for: capture)).map { (capture.id, $0) }
        })
    }

    @discardableResult func submit(_ text: String, answerID: String? = nil) -> Bool {
        guard !busy else { return false }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        guard !demo else { message = "界面预览不提交输入"; return false }
        do {
            let capture = try repository.capture(words, questionID: answerID ?? overlayQuestion?.id ?? question?.id)
            try reloadPending()
            process(capture)
            return true
        } catch { errorMessage = "保存失败，文字尚未提交：\(friendly(error))"; return false }
    }
    func retry(_ capture: InputCapture) { guard !busy else { return }; process(capture, explicitlySubmitted: true) }
    func enqueueExternal(_ text: String, id: String, answerID: String? = nil) {
        guard !demo, AutomaticCapturePolicy.accepts(text) else { return }
        do {
            let addressedAnswer = NaturalTaskIntent.addressed(text) ? (overlayQuestion?.id ?? question?.id) : nil
            _ = try repository.capture(text, questionID: answerID ?? addressedAnswer, id: "external-" + id, queued: true)
            try reloadPending()
            processNextQueued()
        } catch { errorMessage = "接收文字失败，原输入框文字仍在：\(friendly(error))"; showOverlay?() }
    }
    private func processNextQueued() {
        guard !demo, !busy, let next = pending.first(where: { $0.status == "queued" }) else { return }
        process(next)
    }
    func editCapture(_ capture: InputCapture) {
        guard !busy else { return }
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, editingCaptureID != capture.id {
            errorMessage = "输入框还有未提交的文字，请先处理或清空，再修改这条记录。"
            return
        }
        draft = capture.text; editingCaptureID = capture.id; showPending = false
    }
    func submitDraft() {
        guard !busy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let id = editingCaptureID, let capture = pending.first(where: { $0.id == id }) {
            do {
                let detach = recoveryIssue(capture) != nil
                if detach && CaptureRecovery.isUnboundReply(draft) {
                    errorMessage = "请写出完整事项和操作，例如“材料已经交了”，不能只回答“是的”。"
                    return
                }
                try repository.update(capture, text: draft, detachQuestion: detach)
                try reloadPending()
                draft = ""; editingCaptureID = nil; process(capture, explicitlySubmitted: true)
            } catch { errorMessage = friendly(error) }
        } else if submit(draft) { draft = ""; editingCaptureID = nil }
    }
    private func process(_ capture: InputCapture, explicitlySubmitted: Bool = false) {
        let external = capture.id.hasPrefix("external-")
        let traceID = String(capture.id.dropFirst("external-".count))
        if external { inputMethod.diagnostics?.record(.processing, id: traceID) }
        phase = .processing; errorMessage = ""; message = ""; transcript = capture.text; lastVoiceOutcome = nil
        if !external { showOverlay?() }
        speaker.stop()
        let snapshot = workspace
        let currentQuestion = workspace.questions.first { $0.id == capture.questionID }
        let start = releasedAt ?? .now; releasedAt = nil
        processingTask = Task {
            defer { processNextQueued() }
            do {
                // An old queued capture must not run after upgrading to strict
                // reception. Opening a record and explicitly retrying is manual input.
                if external && !explicitlySubmitted && !AutomaticCapturePolicy.accepts(capture.text) {
                    throw UserFacingError("旧版自动接收的文字没有开头口令，已停止处理。请核对后手动重试或忽略。")
                }
                var proposal: Proposal
                let inputContext = try repository.captureContext(for: capture)
                if let issue = CaptureRecovery.issue(questionID: capture.questionID, context: inputContext, workspace: snapshot) {
                    throw UserFacingError(issue)
                }
                if currentQuestion == nil, CaptureRecovery.isUnboundReply(capture.text) {
                    throw UserFacingError("这句话没有对应的问题，请补充完整的事项和操作。")
                }
                if let local = LocalInterpreter.interpret(capture.text, workspace: snapshot, question: currentQuestion,
                                                          now: inputContext.interpretationDate, timeZone: inputContext.interpretationTimeZone,
                                                          defaultReminderHour: settings.defaultReminderHour,
                        defaultReminderLeadMinutes: settings.defaultReminderLeadMinutes) {
                    proposal = local
                } else {
                    let key = try AIKey.read(configuration: settings.configuration, defaults: settings.defaults)
                    proposal = try await AIClient(configuration: settings.configuration).interpret(
                        input: capture.text, workspace: snapshot, question: currentQuestion, key: key,
                        now: inputContext.interpretationDate, timeZone: inputContext.interpretationTimeZone,
                        defaultReminderHour: settings.defaultReminderHour,
                        defaultReminderLeadMinutes: settings.defaultReminderLeadMinutes)
                }
                try Task.checkCancellation()
                // Rebase an immediate lead alarm after network/recognition latency.
                // Relative dates themselves remain anchored to the original capture.
                proposal = ReminderTiming.apply(to: proposal, input: capture.text, now: .now,
                                                leadMinutes: settings.defaultReminderLeadMinutes)
                guard snapshot == workspace else { throw UserFacingError("处理期间列表有变化，原话已保留，请重试。") }
                let result = try TaskReducer.apply(proposal, to: workspace, inputID: capture.id,
                                                   input: capture.text, answering: capture.questionID,
                                                   inputDate: inputContext.interpretationDate, timeZone: inputContext.interpretationTimeZone)
                try repository.save(result.workspace, capture: capture)
                workspace = result.workspace; try reloadPending()
                if external { inputMethod.diagnostics?.record(.applied, id: traceID) }
                message = result.messages.joined(separator: "\n"); elapsed = Date.now.timeIntervalSince(start)
                phase = .idle
                let feedback = !external || ExternalFeedback.shouldShow(result, previous: snapshot, proposal: proposal)
                if feedback {
                    overlayQuestionID = workspace.questions.first { q in !snapshot.questions.contains { $0.id == q.id } }?.id
                        ?? workspace.questions.first { $0.id == capture.questionID }?.id
                        ?? (capture.questionID != nil ? workspace.questions.first?.id : nil)
                    inputMethod.awaitReply(to: overlayQuestion?.id, after: capture.id)
                    fnSpeech.awaitReply(to: overlayQuestion?.id, after: capture.id)
                    if !receivingInputMethod { showOverlay?() }
                }
                await notifications.reconcile(workspace.tasks)
                if feedback, !receivingInputMethod, let question = overlayQuestion, settings.speakQuestions {
                    speaker.speak(question.question + (settings.useInputMethod ? " 请先说清单，再回答。" : ""))
                }
            } catch {
                if external { inputMethod.diagnostics?.record(.processingFailed, id: traceID) }
                let issue = friendly(error)
                do { try repository.fail(capture, message: issue); try reloadPending() }
                catch { errorMessage = "保存处理状态失败，原文：\(capture.text)" }
                if errorMessage.isEmpty { errorMessage = issue }
                phase = .idle
                if !external || explicitlySubmitted || AutomaticCapturePolicy.accepts(capture.text) { showOverlay?() }
            }
        }
    }
    func dismissCapture(_ capture: InputCapture) {
        guard !busy else { return }
        do {
            try repository.dismiss(capture); try reloadPending()
            if editingCaptureID == capture.id { editingCaptureID = nil }
        }
        catch { errorMessage = friendly(error) }
    }
    func undo() {
        guard !busy else { return }
        do {
            let result = try TaskReducer.undo(workspace)
            try commit(result.workspace, message: result.messages.joined(separator: "\n"))
        } catch { errorMessage = friendly(error) }
    }
    func toggle(_ item: TodoItem) {
        guard !busy, let current = workspace.tasks.first(where: { $0.id == item.id }) else { return }
        var updated = current
        updated.completedAt = current.isCompleted ? nil : .now
        updated.needsReminder = false
        if current.isCompleted { updated.reminderRevision = UUID().uuidString }
        edit(updated, message: current.isCompleted ? "已恢复：\(current.title)" : "已完成：\(current.title)", mustExist: true)
    }
    @discardableResult func edit(_ item: TodoItem, message: String = "已保存修改", mustExist: Bool = false, expected: TodoItem? = nil) -> Bool {
        guard !busy else { errorMessage = "正在处理另一句话，请稍后保存。"; return false }
        guard !mustExist || workspace.tasks.contains(where: { $0.id == item.id }) else {
            errorMessage = "这件事已经被取消，未重新添加。"; return false
        }
        if let expected, workspace.tasks.first(where: { $0.id == item.id }) != expected {
            errorMessage = "这件事在编辑期间已变化，请放弃修改后重新打开。"; return false
        }
        let summary = message + (message.contains(item.title) ? "" : "：\(item.title)")
        do { try commit(TaskReducer.manualEdit(item, in: workspace, summary: summary), message: summary); return true }
        catch { errorMessage = friendly(error); return false }
    }
    func cancelTask(_ item: TodoItem) {
        guard !busy else { return }
        do {
            let updated = try TaskReducer.cancelTask(item.id, in: workspace)
            try commit(updated, message: updated.lastActivity?.summary ?? "已取消事项")
        } catch { errorMessage = friendly(error) }
    }
    func disableReminder(_ item: TodoItem) {
        guard var current = workspace.tasks.first(where: { $0.id == item.id }), !current.isCompleted else { return }
        current.reminderAt = nil; current.needsReminder = false; current.reminderRevision = UUID().uuidString
        edit(current, message: "已关闭提醒：\(current.title)", mustExist: true)
    }
    func choose(_ id: String, questionID: String? = nil) {
        let target = questionID == nil ? question : workspace.questions.first { $0.id == questionID }
        guard !busy, let question = target, question.kind == .chooseTask, question.taskIDs.contains(id) else { return }
        if question.intent == nil || question.intent == .other {
            guard let task = workspace.tasks.first(where: { $0.id == id }) else { return }
            submit("我指的是“\(task.title)”这条，请接着处理刚才的问题。", answerID: question.id)
            return
        }
        var capture: InputCapture?
        do {
            let title = workspace.tasks.first(where: { $0.id == id })?.title ?? id
            let input = try repository.capture("选择“\(title)”这条", questionID: question.id)
            capture = input
            let result = try TaskReducer.selectTask(id, questionID: question.id, in: workspace, inputID: input.id)
            try repository.save(result.workspace, capture: input); workspace = result.workspace
            try reloadPending(); errorMessage = ""
            message = result.messages.joined(separator: "\n"); speaker.stop(); reconcile(); showOverlay?()
            if let question = self.question, settings.speakQuestions {
                speaker.speak(question.question + (settings.useInputMethod ? " 请先说清单，再回答。" : ""))
            }
        } catch {
            errorMessage = friendly(error)
            if let capture { try? repository.fail(capture, message: errorMessage) }
            try? reloadPending()
        }
    }
    private func commit(_ state: Workspace, message: String) throws {
        try repository.save(state); workspace = state
        self.message = message; errorMessage = ""; lastVoiceOutcome = nil; reconcile()
        if !workspace.questions.contains(where: { $0.id == overlayQuestionID }) { overlayQuestionID = nil }
    }
    func checkConnection(key: String, configuration newConfiguration: AIConfiguration? = nil) {
        guard !checkingConnection else { return }
        checkingConnection = true; connectionStatus = "正在检查…"; connectionOK = false
        Task {
            defer { checkingConnection = false }
            do {
                let configuration = newConfiguration ?? settings.configuration
                let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await AIClient(configuration: configuration).interpret(
                    input: "仅连接测试，不要改变任务，返回 noop。", workspace: Workspace(), question: nil, key: cleanedKey)
                try Keychain.write(cleanedKey)
                settings.baseURL = configuration.baseURL; settings.model = configuration.model
                settings.defaults.removeObject(forKey: AIKey.referenceKey)
                connectionOK = true; connectionStatus = "连接成功 · 密钥已存入钥匙串"
            } catch { connectionStatus = friendly(error) }
        }
    }
    func checkLocalConnection() {
        guard !checkingConnection else { return }
        checkingConnection = true; connectionStatus = "正在检查…"; connectionOK = false
        Task {
            defer { checkingConnection = false }
            do {
                let key = try AIKey.read(configuration: settings.configuration, defaults: settings.defaults)
                _ = try await AIClient(configuration: settings.configuration).interpret(input: "仅连接测试，返回 noop。", workspace: .init(), question: nil, key: key)
                connectionOK = true; connectionStatus = "本地 Key 连接成功"
            } catch { connectionStatus = friendly(error) }
        }
    }
    func requestMicrophone() {
        Task {
            microphoneAllowed = await SpeechService.requestMicrophone()
            if !microphoneAllowed { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
        }
    }
    func requestHotkey() {
        GlobalHotkey.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func requestNotifications() {
        Task {
            notificationsAllowed = await notifications.requestPermission()
            if !notificationsAllowed { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
            reconcile()
        }
    }
    func installModel() {
        modelStatus = "正在准备语音模型…"
        Task {
            do { try await SpeechService.installModel(); modelStatus = "简体中文模型已就绪" }
            catch { modelStatus = friendly(error) }
        }
    }
    private func friendly(_ error: Error) -> String {
        if error is CancellationError { return "处理已取消，原话已保留。" }
        if let error = error as? UserFacingError { return error.message }
        if let error = error as? URLError {
            return error.code == .timedOut ? "连接超时，原话已保留，请重试。" : "网络连接失败，原话已保留，请联网后重试。"
        }
        return error.localizedDescription
    }
}

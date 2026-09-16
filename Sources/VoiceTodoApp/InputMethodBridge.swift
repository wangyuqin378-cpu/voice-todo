import AppKit
import ApplicationServices
import VoiceTodoCore

/// Read-only observation scoped to one Fn session across field and clipboard
/// delivery. Never read the previous clipboard.
@MainActor final class InputMethodBridge {
    var onCommand: ((String, String, String?) -> Void)?
    var currentQuestionID: (() -> String?)?
    var onStatus: ((String) -> Void)?
    var onProblem: ((String) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onFinished: (() -> Void)?
    private(set) var active = false
    private var field: AXUIElement?
    private var fieldAnchor: FieldAnchor?
    private var application: AXUIElement?
    private var pid: pid_t = 0
    private var source: DictationSource?
    private var previousEditor: DictationApplication?
    private var initialFieldValue: String?
    private var initialClipboardCount = 0
    private var frontRoute: DictationSource.Route?
    var diagnostics: CaptureDiagnostics?
    private var diagnosticID: String?
    private func describe(_ app: NSRunningApplication?) -> DictationApplication? {
        app.map { DictationApplication(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "unknown", bundlePath: $0.bundleURL?.path ?? "") }
    }
    func applicationActivated(_ app: NSRunningApplication?) {
        guard let info = describe(app), !info.isInputMethod else { return }
        previousEditor = info
        if replyPID != info.pid { endConversation() }
    }
    private func trace(_ stage: CaptureDiagnostics.Stage, application: String? = nil, once: Bool = false) {
        if let diagnosticID { diagnostics?.record(stage, id: diagnosticID, application: application, once: once) }
    }
    private var capture: ExternalDictationCapture?
    private let environment: DictationEnvironment
    private let automaticPolling: Bool
    init(environment: DictationEnvironment? = nil, automaticPolling: Bool = true) {
        self.environment = environment ?? .system; self.automaticPolling = automaticPolling
    }
    private var polling: Task<Void, Never>?
    private var pressAt: TimeInterval?
    private var secondPress = false
    private var ended = false
    private var endedAt: TimeInterval?
    private var startedAt: TimeInterval = 0
    private var replyField: AXUIElement?
    private var replyAnchor: FieldAnchor?
    private var replyPID: pid_t = 0
    private var replyInputID: String?
    private var replyWindow: DictationReplyWindow?
    private var replyUsesClipboard = false
    var awaitingReply: Bool {
        replyWindow?.answerID(sourceID: replyInputID, pendingQuestionID: currentQuestionID?(), now: environment.now()) != nil
    }

    func awaitReply(to questionID: String?, after inputID: String) {
        guard replyInputID == inputID else { return }
        replyWindow = questionID.map { DictationReplyWindow(questionID: $0, sourceID: inputID, now: environment.now()) }
    }
    func endConversation() { replyWindow = nil; replyField = nil; replyAnchor = nil; replyInputID = nil; replyUsesClipboard = false }
    func manualCopy() {
        if active { cancel(message: "检测到手动复制，本次自动接收已取消。") }
        else if replyUsesClipboard { endConversation() }
    }
    static var allowed: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func press() {
        let now = environment.now()
        if active && !ended { trace(.pressed); secondPress = true; pressAt = now; return }
        if active { cancel(message: "上一段转写尚未接收，请检查原输入框里的文字。") }
        guard let app = DictationSource.initial(foreground: environment.foreground(), previousEditor: previousEditor) else {
            let id = UUID().uuidString
            diagnostics?.start(id: id, source: nil, fieldReadable: false)
            diagnostics?.record(.noInputDestination, id: id)
            onStatus?("未找到原输入应用，本次没有自动接收。"); return
        }
        initialClipboardCount = environment.clipboardCount()
        let element = environment.application(app.pid)
        let focus: AXUIElement? = environment.trusted() ? attribute(element, kAXFocusedUIElementAttribute) : nil
        if let focus, (attribute(focus, kAXSubroleAttribute) as String?) == kAXSecureTextFieldSubrole {
            diagnosticID = UUID().uuidString
            diagnostics?.start(id: diagnosticID!, source: app.bundleID, fieldReadable: false)
            trace(.secureField)
            onProblem?("密码输入框不接收清单命令。"); return
        }
        let snapshot = focus.flatMap { fieldSnapshot($0) }
        let usingClipboard = snapshot == nil
        let sameSource = replyPID == app.pid && (usingClipboard
            ? replyUsesClipboard
            : (focus.map { current in
                if let replyField, CFEqual(replyField, current) { return true }
                guard let replyAnchor, let currentAnchor = anchor(for: current) else { return false }
                return replyAnchor.matches(currentAnchor)
            } == true))
        let questionID = replyWindow?.answerID(sourceID: sameSource ? replyInputID : nil,
                                              pendingQuestionID: currentQuestionID?(), now: now)
        capture = ExternalDictationCapture(baseline: snapshot?.value, selection: snapshot?.selection,
                                            clipboardCount: initialClipboardCount, questionID: questionID)
        diagnosticID = capture?.id
        if let diagnosticID { diagnostics?.start(id: diagnosticID, source: app.bundleID, fieldReadable: snapshot != nil) }
        trace(.bound)
        source = DictationSource(original: app); frontRoute = nil; initialFieldValue = snapshot?.value
        field = snapshot == nil ? nil : focus; application = snapshot == nil ? nil : element
        fieldAnchor = field.flatMap { anchor(for: $0) }
        active = true; ended = false; endedAt = nil; secondPress = false; startedAt = now; pressAt = now
        pid = app.pid
        endConversation()
        if questionID != nil { onStatus?("继续用 Fn 回答刚才的问题，无需再说“清单”。") }
        else { onStatus?("后台接收本次 Fn · 识别到待办后才显示") }
        onBegin?()
        guard automaticPolling else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.active else { return }
                self.poll()
            }
        }
    }
    func release() {
        guard active, let pressAt else { return }
        let now = environment.now()
        trace(.released)
        if secondPress || now - pressAt >= 0.35 {
            ended = true; endedAt = now; capture?.end(at: now); trace(.ended)
            onStatus?("Fn 已结束 · 等待文字稳定后接收")
            onFinished?()
        }
        self.pressAt = nil
    }
    func cancel(message: String? = nil) {
        if active { trace(.cancelled) }
        endConversation()
        polling?.cancel(); polling = nil; capture = nil; field = nil; fieldAnchor = nil; application = nil
        source = nil; initialFieldValue = nil; diagnosticID = nil
        active = false; pressAt = nil; secondPress = false; ended = false; endedAt = nil
        if let message { onStatus?(message) }
        onEnd?()
    }
    // Internal for deterministic tests of the actual OS-to-command orchestration.
    func poll() {
        guard active else { return }
        let now = environment.now()
        guard now - startedAt < 90 else { finish(.timedOut, message: "本次接收已结束，未收到完整转写。"); return }
        let foreground = environment.foreground()
        let route = source?.route(foreground) ?? .otherApplication
        guard route != .otherApplication else {
            finish(.applicationChanged, message: "当前应用已切换，本次没有自动接收。", application: foreground?.bundleID); return
        }
        if route != frontRoute {
            trace(route == .inputMethod ? .inputMethodFront : .editorFront, application: foreground?.bundleID)
            frontRoute = route
        }
        guard var session = capture else { return }
        if let boundField = field, let application {
            let currentFocus: AXUIElement? = attribute(application, kAXFocusedUIElementAttribute)
            if route == .original, let currentFocus, !CFEqual(currentFocus, boundField) {
                if (attribute(currentFocus, kAXSubroleAttribute) as String?) == kAXSecureTextFieldSubrole {
                    finish(.secureField, message: "密码输入框不接收清单命令。"); return
                }
                if isTextField(currentFocus) {
                    // Web/native editors may replace their accessibility object
                    // on commit. Match its original window and editor anchor;
                    // never replace the text baseline or capture identifier.
                    guard let original = fieldAnchor, let current = anchor(for: currentFocus) else {
                        trace(.fieldAnchorUnavailable)
                        finish(.inputFieldChanged, message: "无法核对原输入位置，本次没有自动接收。"); return
                    }
                    guard original.matches(current) else {
                        trace(CFEqual(original.window, current.window) ? .fieldIdentityChanged : .fieldWindowChanged)
                        finish(.inputFieldChanged, message: "输入位置已切换，本次没有自动接收。"); return
                    }
                    field = currentFocus
                    trace(.fieldRebound, once: true)
                } else {
                    let focusedWindow: AXUIElement? = attribute(currentFocus, kAXWindowAttribute)
                    guard let original = fieldAnchor, let focusedWindow, CFEqual(original.window, focusedWindow) else {
                        finish(.inputFieldChanged, message: "输入位置已切换，本次没有自动接收。"); return
                    }
                    trace(.temporaryFocus, once: true)
                }
            }
            if let field, let value: String = attribute(field, kAXValueAttribute) {
                if value != initialFieldValue { trace(.fieldTextChanged, once: true) }
                session.observeField(value, at: now)
                if session.fieldObservation == .insertion { trace(.fieldInsertionDetected, once: true) }
                if session.fieldObservation == .outsideSelection { trace(.fieldContextChanged, once: true) }
            } else { trace(.fieldTemporarilyUnavailable, once: true) }
        }
        let clipboardCount = environment.clipboardCount()
        if clipboardCount != initialClipboardCount { trace(.clipboardChanged, once: true) }
        session.observeClipboard(changeCount: clipboardCount, at: now, read: environment.clipboardText)
        let result = session.result(at: now)
        capture = session
        if let ordinary = session.ordinarySource {
            trace(ordinary == .field ? .fieldOrdinaryPending : .clipboardOrdinaryPending, once: true)
        }
        switch result {
        case .command(let text, let source):
            trace(source == .field ? .fieldCommandReceived : .clipboardCommandReceived)
            deliver(text, id: session.id, questionID: session.questionID, field: field, fromClipboard: source == .clipboard)
        case .ignored:
            finish(.ordinaryText, message: "本次是普通转写，未改变清单。")
        case .timedOut:
            finish(.timedOut, message: "本次 Fn 未收到转写，未改变清单。")
        case .waiting: break
        }
    }
    private func finish(_ stage: CaptureDiagnostics.Stage, message: String, application: String? = nil) {
        trace(stage, application: application)
        diagnosticID = nil // Keep the actual terminal reason instead of a generic cancel.
        cancel(message: message)
    }
    private func deliver(_ text: String, id: String, questionID: String?, field: AXUIElement?, fromClipboard: Bool) {
        guard questionID == nil || questionID == currentQuestionID?() else {
            cancel(message: "刚才的问题已变化，本次回答未自动处理。"); return
        }
        let sourcePID = pid
        let sourceAnchor = fieldAnchor
        trace(.commandReceived); diagnosticID = nil
        cancel()
        replyField = field; replyAnchor = sourceAnchor; replyPID = sourcePID
        replyInputID = "external-" + id; replyUsesClipboard = fromClipboard
        onStatus?(fromClipboard ? "已接收本次复制的清单命令 · 无需粘贴" : "已接收清单命令 · 原输入框文字保留")
        onCommand?(text, id, questionID)
    }
    private func fieldSnapshot(_ focus: AXUIElement) -> (value: String, selection: NSRange)? {
        guard isTextField(focus),
              let value: String = attribute(focus, kAXValueAttribute),
              let rangeValue: AXValue = attribute(focus, kAXSelectedTextRangeAttribute),
              AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        let selection = NSRange(location: range.location, length: range.length)
        guard TranscriptionCapture(baseline: value, selection: selection) != nil else { return nil }
        return (value, selection)
    }
    private func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        environment.attribute(element, key) as? T
    }
    private func isTextField(_ element: AXUIElement) -> Bool {
        guard let role: String = attribute(element, kAXRoleAttribute) else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }
    private struct FieldAnchor {
        let window: AXUIElement
        let parent: AXUIElement?
        let identifier: String?
        let role: String
        let position: CGPoint?
        func matches(_ other: Self) -> Bool {
            guard CFEqual(window, other.window), role == other.role else { return false }
            if let identifier, !identifier.isEmpty, let otherID = other.identifier, !otherID.isEmpty {
                return identifier == otherID
            }
            guard let parent, let otherParent = other.parent, CFEqual(parent, otherParent),
                  let position, let otherPosition = other.position else { return false }
            return abs(position.x - otherPosition.x) < 2 && abs(position.y - otherPosition.y) < 2
        }
    }
    private func anchor(for element: AXUIElement) -> FieldAnchor? {
        guard let window: AXUIElement = attribute(element, kAXWindowAttribute),
              let role: String = attribute(element, kAXRoleAttribute) else { return nil }
        var position: CGPoint?
        if let value: AXValue = attribute(element, kAXPositionAttribute), AXValueGetType(value) == .cgPoint {
            var point = CGPoint.zero
            if AXValueGetValue(value, .cgPoint, &point) { position = point }
        }
        return FieldAnchor(window: window, parent: attribute(element, kAXParentAttribute),
                           identifier: attribute(element, kAXIdentifierAttribute), role: role, position: position)
    }
}

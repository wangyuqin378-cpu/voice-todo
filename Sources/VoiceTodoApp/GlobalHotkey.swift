import AppKit
import VoiceTodoCore

@MainActor final class GlobalHotkey {
    var choice: HotkeyChoice = .rightOption
    var useInputMethod = false
    var dictationShortcut: DictationShortcut = .fn {
        didSet { if oldValue != dictationShortcut { reset(clearHeldKeys: true) } }
    }
    var recordingShortcut = false {
        didSet { if oldValue != recordingShortcut { reset(clearHeldKeys: true) } }
    }
    var onFnPress: (() -> Void)?
    var onFnRelease: (() -> Void)?
    var onExternalCancel: (() -> Void)?
    var onManualCopy: (() -> Void)?
    var onStart: (() -> Bool)?
    var onTap: (() -> Void)?
    var onLatch: (() -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDetected: (() -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onConnection: ((Bool) -> Void)?
    var onReceipt: ((HotkeyDiagnostics.Source, HotkeyDiagnostics.Outcome, Bool?, Double) -> Void)?
    private(set) var connectionDetail = "尚未连接"
    private(set) var tap: CFMachPort?
    private(set) var source: CFRunLoopSource?
    private var localMonitor: Any?
    private var delayed: Task<Void, Never>?
    private var gesture = HotkeyGesture()
    private var ownsHoldRecording = false
    private var pressedAt: TimeInterval?
    private var fnPressed = false
    private var fnBlocked = false
    private var customGesture = DictationShortcutGesture()
    // Only retain currently held virtual keys; never collect typed text or a key history.
    private var heldKeys: Set<UInt16> = []
    // Only opaque, process-randomized event fingerprints are retained briefly.
    // No key-code or typed-text history is kept by the duplicate cache.
    private var recentEventIDs: [(id: Int, receivedAt: TimeInterval)] = []
    static var allowed: Bool { CGPreflightListenEventAccess() }
    static func requestPermission() { _ = CGRequestListenEventAccess() }

    deinit {
        delayed?.cancel()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    @discardableResult func install() -> Bool {
        // Foreground recording and Escape work even without global permission.
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let type: CGEventType = event.type == .flagsChanged ? .flagsChanged : (event.type == .keyDown ? .keyDown : .keyUp)
                    self.receive(type, code: event.keyCode, flags: event.modifierFlags.rawValue, timestamp: event.timestamp, source: .localMonitor, isRepeat: event.type == .keyDown && event.isARepeat)
                }
                return event
            }
        }
        if let tap, CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            let enabled = CGEvent.tapIsEnabled(tap: tap); onConnection?(enabled); return enabled
        }
        guard Self.allowed else { onConnection?(false); return false }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context {
                let service = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
                let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = UInt(event.flags.rawValue)
                let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                // Return from the tap before querying another app's accessibility
                // tree. AX IPC inside this callback can stall the input event itself.
                DispatchQueue.main.async { [weak service] in
                    guard let service else { return }
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        service.reset(clearHeldKeys: true)
                        service.onDiagnostic?("按键监听已恢复，请重新按一次语音键。")
                        if let tap = service.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        service.onConnection?(service.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)
                    } else { service.receive(type, code: code, flags: flags, timestamp: timestamp, isRepeat: isRepeat) }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        // Observe before input methods can consume Fn at the session stage.
        // Both taps are passive; normal input-monitoring authorization still applies.
        var installed: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            installed = CGEvent.tapCreate(tap: location, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                          callback: callback, userInfo: pointer)
            if installed != nil {
                connectionDetail = location == .cghidEventTap ? "已连接键盘入口" : "已连接会话入口"
                break
            }
        }
        guard let tap = installed else { connectionDetail = "未能连接"; onConnection?(false); return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let enabled = CGEvent.tapIsEnabled(tap: tap); onConnection?(enabled)
        return enabled
    }

    func reset(clearHeldKeys: Bool = false) {
        onExternalCancel?()
        fnPressed = false; fnBlocked = false
        customGesture = DictationShortcutGesture()
        delayed?.cancel(); delayed = nil
        perform(gesture.reset()); ownsHoldRecording = false; pressedAt = nil
        if clearHeldKeys { heldKeys.removeAll() }
    }
    // Physical/input-method and synthesized events can carry different clock
    // values. A lower timestamp is not proof that an input is stale. Reject only
    // a recently seen event identity, including delayed copies from either source.
    func receive(_ type: CGEventType, code: UInt16, flags: UInt, timestamp: TimeInterval, source: HotkeyDiagnostics.Source = .eventTap, isRepeat: Bool = false) {
        let fnDown: Bool? = type == .flagsChanged && code == 63 ? flags & NSEvent.ModifierFlags.function.rawValue != 0 : nil
        let receivedAt = ProcessInfo.processInfo.systemUptime
        let aheadBy = timestamp - receivedAt
        recentEventIDs.removeAll { receivedAt - $0.receivedAt > 30 }
        if timestamp.isFinite, timestamp > 0 {
            var hasher = Hasher()
            // Tolerate sub-microsecond conversion noise between CGEvent/NSEvent.
            hasher.combine((timestamp * 1_000_000).rounded())
            hasher.combine(type.rawValue); hasher.combine(code); hasher.combine(flags); hasher.combine(isRepeat)
            let id = hasher.finalize()
            guard !recentEventIDs.contains(where: { $0.id == id }) else {
                onReceipt?(source, .duplicate, fnDown, aheadBy); return
            }
            recentEventIDs.append((id, receivedAt))
            if recentEventIDs.count > 256 { recentEventIDs.removeFirst(recentEventIDs.count - 256) }
        }
        onReceipt?(source, .accepted, fnDown, aheadBy)
        handle(type, code: code, flags: flags, isRepeat: isRepeat)
    }
    // Internal so the same event path can be exercised without posting system key events.
    func handle(_ type: CGEventType, code: UInt16, flags: UInt, isRepeat: Bool = false) {
        guard !recordingShortcut else { return }
        if useInputMethod {
            if dictationShortcut != .fn {
                let effect = customGesture.handle(type, code: code, flags: flags, shortcut: dictationShortcut, isRepeat: isRepeat)
                switch effect {
                case .press: onDetected?(); onDiagnostic?("已按下 \(dictationShortcut.label)"); onFnPress?()
                case .release: onDiagnostic?("已松开 \(dictationShortcut.label)"); onFnRelease?()
                case .cancel: onDiagnostic?("本次语音接收已取消。"); onExternalCancel?()
                case .none: break
                }
                if type == .keyDown, code == 53 { onCancel?() }
                // Copy is a deliberate user action unless it is the configured
                // dictation shortcut itself. Synthetic paste commits stay allowed.
                if effect == .none, type == .keyDown, code != dictationShortcut.keyCode,
                   flags & NSEvent.ModifierFlags.command.rawValue != 0, code == 8 || code == 7 { onManualCopy?() }
                return
            }
            if type == .keyDown, flags & NSEvent.ModifierFlags.command.rawValue != 0, code == 8 || code == 7 {
                onManualCopy?()
            }
            // Dictation tools can commit via synthetic Cmd+V. Do not mistake that
            // insertion mechanism for the user abandoning the voice session.
            if type == .keyDown, code == 53 {
                if fnPressed { fnBlocked = true }
                onExternalCancel?()
            } else if type == .keyDown, fnPressed || flags & NSEvent.ModifierFlags.function.rawValue != 0 {
                blockFnChord()
            }
            let other = flags & (NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.shift.rawValue)
            if type == .flagsChanged, code == 63 {
                onDetected?()
                if flags & NSEvent.ModifierFlags.function.rawValue != 0 {
                    // A press owns exactly one release. Suppression remains in
                    // effect even if the extra modifier/key is released first.
                    if !fnPressed {
                        fnPressed = true; fnBlocked = false
                        if other != 0 || !heldKeys.isEmpty { blockFnChord() }
                        else { onDiagnostic?("已按下 Fn"); onFnPress?() }
                    } else if other != 0 || !heldKeys.isEmpty { blockFnChord() }
                } else if fnPressed {
                    if other != 0 || !heldKeys.isEmpty { blockFnChord() }
                    let shouldRelease = !fnBlocked
                    fnPressed = false; fnBlocked = false
                    if shouldRelease { onDiagnostic?("已松开 Fn"); onFnRelease?() }
                }
            } else if type == .flagsChanged, fnPressed, other != 0 {
                blockFnChord()
            }
            if type == .keyDown { heldKeys.insert(code); if code == 53 { onCancel?() } }
            if type == .keyUp { heldKeys.remove(code) }
            return
        }
        if type == .keyUp { heldKeys.remove(code); return }
        if type == .keyDown {
            heldKeys.insert(code)
            if code == 53 { reset(); onDiagnostic?("已按 Esc 取消。"); onCancel?(); return }
            if gesture.state != .idle {
                delayed?.cancel(); perform(gesture.combine())
                onDiagnostic?("检测到组合键，本次未录音。")
            }
            return
        }
        guard type == .flagsChanged else { return }
        // IOLLEvent.h device bits describe this event, avoiding global key-state delivery races.
        let rightMask: UInt = choice == .rightOption ? 0x40 : (choice == .rightControl ? 0x2000 : 0x10)
        let rightDown = flags & rightMask != 0
        let allDeviceModifiers: UInt = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x2000
        let hasOtherModifier = flags & (allDeviceModifiers & ~rightMask) != 0 || flags & NSEvent.ModifierFlags.function.rawValue != 0
        if code == choice.keyCode {
            if rightDown {
                onDetected?()
                if gesture.state == .idle { pressedAt = ProcessInfo.processInfo.systemUptime }
                // A global key-state snapshot can retain stale synthetic key states.
                // Pair actual down/up events instead of treating that snapshot as a chord.
                let combined = hasOtherModifier || !heldKeys.isEmpty
                if gesture.state == .idle {
                    onDiagnostic?(combined ? "检测到组合键，本次未录音。" : "已按下录音键。")
                }
                perform(gesture.press(hasOtherKeys: combined))
            } else {
                delayed?.cancel(); delayed = nil
                let duration = pressedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 1
                pressedAt = nil
                perform(gesture.release(heldFor: duration))
            }
        } else if gesture.state != .idle, hasOtherModifier {
            delayed?.cancel(); perform(gesture.combine())
            onDiagnostic?("检测到组合键，本次未录音。")
        }
    }
    private func blockFnChord() {
        guard !fnBlocked else { return }
        fnBlocked = true
        onDiagnostic?("检测到 Fn 组合键，本次不接收。")
        onExternalCancel?()
    }
    private func perform(_ effect: HotkeyGesture.Effect) {
        switch effect {
        case .none: break
        case .armHold:
            delayed?.cancel()
            delayed = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                self.perform(self.gesture.holdThreshold())
            }
        case .tap: onDiagnostic?("已松开录音键，执行开始／结束。"); onTap?()
        case .startHold:
            ownsHoldRecording = onStart?() ?? false
            onDiagnostic?(ownsHoldRecording ? "按住录音已开始。" : "已收到长按，当前未能开始录音。")
        case .latchRecording:
            onDiagnostic?("已松开录音键，轻按录音继续。")
            if ownsHoldRecording { onLatch?() } else { onTap?() }
            ownsHoldRecording = false
        case .endHold: onDiagnostic?("已松开录音键，结束录音。"); ownsHoldRecording = false; onEnd?()
        case .cancelHold:
            if ownsHoldRecording { onCancel?() }
            ownsHoldRecording = false
        }
    }
}

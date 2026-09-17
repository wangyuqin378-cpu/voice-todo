import AppKit
import SwiftUI

/// Recording runs only in the settings sheet. It never persists key events.
struct ShortcutRecording {
    private var heldModifiers: Set<UInt16> = []
    private var heldKeys: Set<UInt16> = []
    private var pending: DictationShortcut?
    private var invalid = false
    private var physicalFn = false
    mutating func receive(_ event: NSEvent) -> DictationShortcut? {
        if event.type == .flagsChanged, let modifier = DictationShortcut.modifierKeys[event.keyCode] {
            let familyDevices = DictationShortcut.modifierKeys.values.filter { $0.flag == modifier.flag }.reduce(UInt(0)) { $0 | $1.device }
            let down = event.modifierFlags.rawValue & modifier.flag != 0 &&
                (event.modifierFlags.rawValue & familyDevices == 0 || event.modifierFlags.rawValue & modifier.device != 0 || event.keyCode == 63)
            if event.keyCode == 63 { physicalFn = down }
            if down {
                if heldModifiers.isEmpty && heldKeys.isEmpty { pending = nil; invalid = false }
                heldModifiers.insert(event.keyCode)
                // Two sides of one modifier are not a portable modifier combination.
                if Set(heldModifiers.compactMap { DictationShortcut.modifierKeys[$0]?.flag }).count != heldModifiers.count { invalid = true }
                if heldKeys.isEmpty { pending = .recorded(code: event.keyCode, flags: event.modifierFlags.rawValue, characters: nil) }
                else if let key = heldKeys.first, let label = pending?.keyLabel {
                    pending = .recorded(code: key, flags: event.modifierFlags.rawValue, characters: label)
                }
            } else { heldModifiers.remove(event.keyCode) }
        } else if event.type == .keyDown {
            if event.isARepeat { return nil }
            if heldKeys.isEmpty && heldModifiers.isEmpty { invalid = false }
            heldKeys.insert(event.keyCode)
            if heldKeys.count > 1 { invalid = true }
            var flags = event.modifierFlags.rawValue
            if !physicalFn { flags &= ~NSEvent.ModifierFlags.function.rawValue }
            pending = .recorded(code: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers)
        } else if event.type == .keyUp { heldKeys.remove(event.keyCode) }
        guard heldKeys.isEmpty, heldModifiers.isEmpty else { return nil }
        defer { pending = nil; invalid = false }
        return invalid ? nil : pending
    }
}

struct ShortcutRecorderSheet: View {
    let current: DictationShortcut
    let save: (DictationShortcut) -> Void
    let cancel: () -> Void
    @State private var candidate: DictationShortcut?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("录入原语音工具的按键").font(.title2.bold())
            Text("按下并松开按键或组合键，然后保存。支持 Fn、左右修饰键、功能键和修饰键组合；Esc 取消。")
            Text(candidate?.label ?? "请按键…").font(.title).frame(maxWidth: .infinity, minHeight: 58)
                .accessibilityLabel("录入的语音按键").accessibilityValue(candidate?.label ?? "等待按键")
            Text("当前：\(current.label)。这里只设置随口清单，请与原语音工具保持一致。系统保留的快捷键可能收不到；单独字母会在打字时触发。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("取消", action: cancel)
                Spacer()
                Button("保存按键") { if let candidate { save(candidate) } }.disabled(candidate == nil)
            }
        }.padding(24).frame(width: 440)
            .background(ShortcutEventView(onCandidate: { candidate = $0 }, onCancel: cancel))
    }
}

private struct ShortcutEventView: NSViewRepresentable {
    let onCandidate: (DictationShortcut) -> Void
    let onCancel: () -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(); view.onCandidate = onCandidate; view.onCancel = onCancel
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) { view.onCandidate = onCandidate; view.onCancel = onCancel }
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.stop() }

    @MainActor final class CaptureView: NSView {
        var onCandidate: ((DictationShortcut) -> Void)?
        var onCancel: (() -> Void)?
        private var recording = ShortcutRecording()
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(resetRecording), name: NSWindow.didResignKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isKeyWindow, event.window === window else { return false }
                    if event.type == .keyDown && event.keyCode == 53 { self.onCancel?(); return true }
                    if let shortcut = self.recording.receive(event) { self.onCandidate?(shortcut) }
                    return true
                }
                return consumed ? nil : event
            }
        }
        @objc private func resetRecording() { recording = ShortcutRecording() }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            NotificationCenter.default.removeObserver(self)
            resetRecording()
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

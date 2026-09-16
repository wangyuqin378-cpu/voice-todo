import AppKit
import SwiftUI
import Observation
import VoiceTodoCore

final class VoicePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var status: NSStatusItem!
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var overlay: NSPanel!
    private var timer: Timer?
    private var dismissTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var captureMenuItem: NSMenuItem?
    private var undoMenuItem: NSMenuItem?
    private var pendingMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let demo = CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier == "com.wyq.voicetodo.preview"
            let repository: Repository
            let settings: AppSettings
            if demo {
                repository = try Repository(inMemory: true)
                settings = AppSettings(defaults: UserDefaults(suiteName: "com.wyq.voicetodo.preview.settings") ?? .standard)
            } else {
                let root = URL.applicationSupportDirectory.appending(path: "VoiceTodo", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                repository = try Repository(url: root.appending(path: "tasks.store"))
                settings = AppSettings()
            }
            state = try AppState(repository: repository, settings: settings, demo: demo,
                captureDiagnostics: demo ? nil : CaptureDiagnostics(url: URL.applicationSupportDirectory.appending(path: "VoiceTodo/capture-diagnostics.json")),
                hotkeyDiagnostics: demo ? nil : HotkeyDiagnostics(url: URL.applicationSupportDirectory.appending(path: "VoiceTodo/hotkey-diagnostics.json")))
            window = makeWindow(title: demo ? "随口清单 · 预览" : "随口清单", size: NSSize(width: 650, height: 720))
            window.contentView = NSHostingView(rootView: MainView(state: state, openSettings: { [weak self] in self?.showSettings() }))
            overlay = VoicePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            overlay.level = .floating; overlay.isFloatingPanel = true; overlay.hidesOnDeactivate = false
            overlay.title = "随口清单 · 录音"
            overlay.backgroundColor = .clear; overlay.isOpaque = false; overlay.hasShadow = true
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            overlay.contentView = NSHostingView(rootView: OverlayView(state: state).fixedSize(horizontal: true, vertical: true))
            state.showOverlay = { [weak self] in DispatchQueue.main.async { self?.showOverlay() } }
            state.hideOverlay = { [weak self] in self?.overlay.orderOut(nil) }
            state.openList = { [weak self] in self?.showList() }
            makeMenu(); state.activate(); observeStatus()
            timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.state.reconcile() }
            }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.state.activate() } })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.state.sleep() } })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in self?.state.inputMethod.applicationActivated(app) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.state.refreshPermissions() } })
            showList()
            if !settings.onboardingDone { showSettings() }
        } catch {
            let alert = NSAlert(); alert.messageText = "随口清单暂时无法打开"
            alert.informativeText = "本地数据未被覆盖。\n\(error.localizedDescription)"
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func makeWindow(title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 610, height: 620); window.center()
        return window
    }
    private func makeMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "checkmark.bubble", accessibilityDescription: "随口清单")
        status.button?.toolTip = "随口清单"
        let menu = NSMenu()
        let captureItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(captureItem); captureMenuItem = captureItem
        menu.addItem(.separator())
        for (title, action, key) in [("查看清单", #selector(showList), ""), ("开始／结束录音", #selector(toggleRecording), ""), ("设置…", #selector(showSettings), ",")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        let pending = NSMenuItem(title: "未处理记录", action: #selector(showPending), keyEquivalent: "")
        pending.target = self; menu.addItem(pending); pendingMenuItem = pending
        let undo = NSMenuItem(title: "撤销最近操作", action: #selector(undoTask), keyEquivalent: "")
        undo.target = self; menu.addItem(undo); undoMenuItem = undo
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出随口清单", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        status.menu = menu
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = menu.copy() as? NSMenu; main.addItem(appItem)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
        edit.submenu = editMenu; main.addItem(edit); NSApp.mainMenu = main
    }
    private func observeStatus() {
        withObservationTracking {
            let current = state.captureStatus
            status.button?.image = NSImage(systemSymbolName: current.symbol, accessibilityDescription: "随口清单 · " + current.title)
            status.button?.toolTip = "随口清单 · " + current.title
            status.button?.setAccessibilityLabel("随口清单 · " + current.title)
            captureMenuItem?.title = current.title
            pendingMenuItem?.title = "未处理记录（\(state.pending.count)）"
            pendingMenuItem?.isEnabled = !state.pending.isEmpty
            undoMenuItem?.title = state.workspace.undo.last.map { "撤销：" + String($0.summary.prefix(32)) } ?? "暂无可撤销操作"
            undoMenuItem?.isEnabled = !state.workspace.undo.isEmpty && !state.busy
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
    }
    @objc func showPending() { state.showPending = true; showList() }
    @objc func undoTask() { state.undo() }
    @objc func showList() { overlay?.orderOut(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showSettings() {
        if settingsWindow == nil {
            let panel = makeWindow(title: "随口清单设置", size: NSSize(width: 570, height: 750))
            panel.styleMask.remove(.resizable)
            panel.contentView = NSHostingView(rootView: SettingsView(state: state, settings: state.settings, close: { [weak self] in self?.settingsWindow?.close(); self?.showList() }))
            settingsWindow = panel
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func toggleRecording() { state.toggleRecording() }
    @objc func quitApp() { NSApp.terminate(nil) }
    private func showOverlay() {
        dismissTask?.cancel()
        overlay.contentView?.layoutSubtreeIfNeeded()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = overlay.contentView?.fittingSize ?? NSSize(width: 420, height: 280)
            overlay.setContentSize(NSSize(width: 420, height: max(180, size.height)))
            overlay.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.minY + 32))
        }
        overlay.orderFrontRegardless()
        if state.phase == .idle, !state.receivingInputMethod, state.overlayQuestion == nil, state.errorMessage.isEmpty {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.overlay.orderOut(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showList(); return true }
    func applicationWillTerminate(_ notification: Notification) { state?.sleep() }
}

@main enum VoiceTodoMain {
    @MainActor static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--use-local-deepseek-key" {
            Task { exit(await AISetup.useLocalDeepSeek(path: CommandLine.arguments[2])) }
            dispatchMain()
        }
        if CommandLine.arguments == [CommandLine.arguments[0], "--configure-ai-stdin"] {
            // Credentials travel through stdin directly into Keychain, never argv or logs.
            Task { exit(await AISetup.importFromStandardInput()) }
            dispatchMain()
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--evaluate" {
            Task { let status = await Evaluation.run(casesPath: CommandLine.arguments[2], outputPath: CommandLine.arguments[3]); exit(status) }
            dispatchMain()
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--transcribe-file" {
            Task { let status = await Evaluation.transcribeFile(path: CommandLine.arguments[2]); exit(status) }
            dispatchMain()
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

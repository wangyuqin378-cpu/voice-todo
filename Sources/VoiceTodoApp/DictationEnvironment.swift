import AppKit
import ApplicationServices
import VoiceTodoCore

/// Replace only the OS boundary in tests; exercise the real bridge without
/// reading another app or the user's clipboard, or posting keyboard events.
@MainActor struct DictationEnvironment {
    var foreground: () -> DictationApplication?
    var trusted: () -> Bool
    var now: () -> TimeInterval
    var clipboardCount: () -> Int
    var clipboardText: () -> String?
    var application: (pid_t) -> AXUIElement
    var attribute: (AXUIElement, String) -> CFTypeRef?

    static var system: Self {
        Self(foreground: {
            NSWorkspace.shared.frontmostApplication.map {
                DictationApplication(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "unknown", bundlePath: $0.bundleURL?.path ?? "")
            }
        }, trusted: { AXIsProcessTrusted() }, now: { ProcessInfo.processInfo.systemUptime },
        clipboardCount: { NSPasteboard.general.changeCount }, clipboardText: { NSPasteboard.general.string(forType: .string) },
        application: {
            let app = AXUIElementCreateApplication($0)
            AXUIElementSetMessagingTimeout(app, 0.08)
            return app
        }, attribute: { element, key in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        })
    }
}

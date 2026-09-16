import Foundation

/// Metadata only: input methods may temporarily become foreground while the
/// original editor remains the destination. Never retarget to an arbitrary app.
public struct DictationApplication: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    public var bundlePath: String
    public init(pid: Int32, bundleID: String, bundlePath: String) {
        self.pid = pid; self.bundleID = bundleID; self.bundlePath = bundlePath
    }
    public var isInputMethod: Bool {
        let parent = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().standardizedFileURL.path
        return ["/Library/Input Methods", "/System/Library/Input Methods",
                NSHomeDirectory() + "/Library/Input Methods"].contains(parent)
    }
}

public struct DictationSource: Sendable {
    public enum Route: Equatable { case original, inputMethod, otherApplication }
    public let original: DictationApplication
    public init(original: DictationApplication) { self.original = original }
    public func route(_ foreground: DictationApplication?) -> Route {
        guard let foreground else { return .otherApplication }
        if foreground.pid == original.pid { return .original }
        return foreground.isInputMethod ? .inputMethod : .otherApplication
    }
    public static func initial(foreground: DictationApplication?, previousEditor: DictationApplication?) -> DictationApplication? {
        guard let foreground else { return nil }
        return foreground.isInputMethod ? previousEditor : foreground
    }
}

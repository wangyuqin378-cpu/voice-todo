import Foundation
import Security
import Observation
import VoiceTodoCore

enum Keychain {
    static let service = "com.wyq.voicetodo.ai"
    static func read() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let result = String(data: data, encoding: .utf8) else {
            throw UserFacingError("无法读取系统钥匙串中的 AI 密钥。")
        }
        return result
    }
    static func write(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw UserFacingError("无法删除旧密钥。") }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query; attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw UserFacingError("无法把密钥保存到系统钥匙串（\(added)）。") }
        } else if status != errSecSuccess { throw UserFacingError("无法更新系统钥匙串中的密钥。") }
    }
}

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightOption, rightControl, rightCommand
    var id: String { rawValue }
    var label: String {
        switch self { case .rightOption: "右侧 ⌥ Option"; case .rightControl: "右侧 ⌃ Control"; case .rightCommand: "右侧 ⌘ Command" }
    }
    var keyCode: UInt16 { switch self { case .rightOption: 61; case .rightControl: 62; case .rightCommand: 54 } }
}

@MainActor @Observable final class AppSettings {
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "ai.baseURL") } }
    var model: String { didSet { defaults.set(model, forKey: "ai.model") } }
    var hotkey: HotkeyChoice { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    var speakQuestions: Bool { didSet { defaults.set(speakQuestions, forKey: "speakQuestions") } }
    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    var shortcutExperienced: Bool { didSet { defaults.set(shortcutExperienced, forKey: "shortcutExperienced") } }
    var useInputMethod: Bool { didSet { defaults.set(useInputMethod, forKey: "inputMethod.enabled") } }
    var fnLocalSpeech: Bool { didSet { defaults.set(fnLocalSpeech, forKey: "inputMethod.localSpeech") } }
    var defaultReminderHour: Int { didSet { defaults.set(defaultReminderHour, forKey: "reminder.defaultHour") } }
    var defaultReminderLeadMinutes: Int { didSet { defaults.set(defaultReminderLeadMinutes, forKey: "reminder.leadMinutes") } }
    @ObservationIgnored let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        baseURL = defaults.string(forKey: "ai.baseURL") ?? AIConfiguration().baseURL
        model = defaults.string(forKey: "ai.model") ?? AIConfiguration().model
        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        speakQuestions = defaults.object(forKey: "speakQuestions") as? Bool ?? true
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        shortcutExperienced = defaults.bool(forKey: "shortcutExperienced")
        useInputMethod = defaults.object(forKey: "inputMethod.enabled") as? Bool ?? true
        fnLocalSpeech = defaults.object(forKey: "inputMethod.localSpeech") as? Bool ?? true
        defaultReminderHour = defaults.object(forKey: "reminder.defaultHour") as? Int ?? 9
        let lead = defaults.object(forKey: "reminder.leadMinutes") as? Int ?? 10
        defaultReminderLeadMinutes = (0...1440).contains(lead) ? lead : 10
    }
    var configuration: AIConfiguration { AIConfiguration(baseURL: baseURL, model: model) }
}

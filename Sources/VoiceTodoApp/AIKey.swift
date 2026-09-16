import Foundation
import VoiceTodoCore

enum AIKey {
    static let referenceKey = "ai.localDeepSeekReference"
    static var hasLocalReference: Bool { UserDefaults.standard.string(forKey: referenceKey) != nil }
    static func read(configuration: AIConfiguration, defaults: UserDefaults = .standard) throws -> String {
        if let path = defaults.string(forKey: referenceKey) {
            // A borrowed provider credential must never follow an edited endpoint.
            guard try configuration.endpoint().host == "api.deepseek.com" else {
                throw UserFacingError("本地 DeepSeek 密钥只用于 DeepSeek 官方接口；如需其他服务，请在设置中保存对应密钥。")
            }
            return try fileKey(path: path)
        }
        return try Keychain.read()
    }
    static func fileKey(path: String) throws -> String {
        guard path.hasPrefix("/"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 65_536,
              let text = String(data: data, encoding: .utf8) else {
            throw UserFacingError("无法读取你指定的本地 AI 配置，请检查文件是否仍在。")
        }
        let lines = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("DEEPSEEK_API_KEY:") }
        guard lines.count == 1 else { throw UserFacingError("本地配置中没有唯一的 DeepSeek API Key。") }
        var key = String(lines[0].dropFirst("DEEPSEEK_API_KEY:".count)).trimmingCharacters(in: .whitespaces)
        if (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")) { key = String(key.dropFirst().dropLast()) }
        guard !key.isEmpty, key.count < 4096, !key.contains(where: \.isWhitespace) else { throw UserFacingError("本地 DeepSeek Key 格式无法识别。") }
        return key
    }
}

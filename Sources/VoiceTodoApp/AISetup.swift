import Foundation
import VoiceTodoCore

@MainActor enum AISetup {
    static func useLocalDeepSeek(path: String) async -> Int32 {
        do {
            let key = try AIKey.fileKey(path: path)
            let existing = try Keychain.read()
            guard existing.isEmpty || existing == key else { throw UserFacingError("应用已有不同密钥，未覆盖。") }
            let configuration = AIConfiguration(baseURL: "https://api.deepseek.com", model: "deepseek-flash")
            let proposal = try await AIClient(configuration: configuration).interpret(input: "仅连接测试，不要改变任务，返回 noop。", workspace: .init(), question: nil, key: key)
            guard !proposal.actions.isEmpty, proposal.actions.allSatisfy({ $0.kind == .noop }) else { throw UserFacingError("连接检查未通过，未保存设置。") }
            do {
                try Keychain.write(key)
                UserDefaults.standard.removeObject(forKey: AIKey.referenceKey)
                print("AI 连接通过，密钥已存入系统钥匙串。")
            } catch {
                UserDefaults.standard.set(path, forKey: AIKey.referenceKey)
                print("AI 连接通过；钥匙串拒绝写入，已引用现有本地配置，未另存密钥副本。")
            }
            let settings = AppSettings()
            settings.baseURL = configuration.baseURL; settings.model = configuration.model
            settings.apiProtocol = configuration.apiProtocol
            return 0
        } catch {
            print((error as? UserFacingError)?.message ?? "本地 AI 配置接入失败。")
            return 2
        }
    }
    static func importFromStandardInput() async -> Int32 {
        struct Import: Decodable { var key: String; var baseURL: String; var model: String; var apiProtocol: AIProtocol? }
        do {
            let data = try FileHandle.standardInput.read(upToCount: 16_385) ?? Data()
            guard data.count <= 16_384 else { throw UserFacingError("配置过大，未保存。") }
            let value = try JSONDecoder().decode(Import.self, from: data)
            let key = value.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw UserFacingError("密钥为空，未保存。") }
            let old = try Keychain.read()
            guard old.isEmpty || old == key else { throw UserFacingError("应用已有不同密钥，请在设置中修改，未覆盖。") }
            let configuration = AIConfiguration(baseURL: value.baseURL, model: value.model, apiProtocol: value.apiProtocol ?? .automatic)
            let result = try await AIClient(configuration: configuration).interpret(
                input: "仅连接测试，不要改变任务，返回 noop。", workspace: .init(), question: nil, key: key)
            guard result.actions.allSatisfy({ $0.kind == .noop }), !result.actions.isEmpty else {
                throw UserFacingError("连接测试返回了意外动作，未保存。")
            }
            try Keychain.write(key)
            let settings = AppSettings()
            settings.baseURL = configuration.baseURL; settings.model = configuration.model
            settings.apiProtocol = configuration.apiProtocol
            print("AI 连接通过；密钥已存入系统钥匙串。")
            return 0
        } catch {
            // Do not print decoder diagnostics, which can contain the input credential.
            if let known = error as? UserFacingError { print(known.message) }
            else { print("AI 配置导入失败，未输出配置内容。") }
            return 2
        }
    }
}

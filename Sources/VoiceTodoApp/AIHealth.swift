import Foundation
import CryptoKit
import VoiceTodoCore

/// One runtime health record, scoped to the exact configuration and credential.
/// No key or fingerprint is persisted. Editing configuration/credential resets the pause.
struct AIHealth {
    private var configuration: AIConfiguration?
    private var credentialDigest: SHA256.Digest?
    private(set) var pausedUntil: Date?
    private(set) var requiresConfiguration = false
    private(set) var explanation = ""
    mutating func prepare(configuration: AIConfiguration, key: String) {
        let digest = SHA256.hash(data: Data(key.utf8))
        if self.configuration != configuration || credentialDigest.map({ Array($0) }) != Array(digest) {
            self = AIHealth(); self.configuration = configuration; credentialDigest = digest
        }
    }
    func canAttempt(now: Date = .now) -> Bool {
        !requiresConfiguration && (pausedUntil == nil || pausedUntil! <= now)
    }
    mutating func success() { pausedUntil = nil; requiresConfiguration = false; explanation = "" }
    mutating func failure(_ error: Error, now: Date = .now) {
        if let service = error as? AIServiceError {
            explanation = service.message
            switch service.kind {
            case .configuration, .credentials: requiresConfiguration = true; pausedUntil = nil
            case .temporary, .invalidResponse: pausedUntil = now.addingTimeInterval(60)
            }
        } else if error is URLError {
            explanation = "AI 网络连接失败。"; pausedUntil = now.addingTimeInterval(60)
        }
        // A rejected task proposal does not mean the service/configuration is broken.
    }
    var status: String {
        if requiresConfiguration { return explanation + " 简单事项仍可在本机处理；修正后检查连接可恢复 AI。" }
        if pausedUntil != nil { return explanation + " 简单事项仍可在本机处理；暂停 1 分钟后再试，可手动检查连接。" }
        return ""
    }
}

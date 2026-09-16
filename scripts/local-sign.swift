import Foundation
import Security
import CryptoKit

// An app-specific development identity. Never changes trust settings or imports
// into the user's login keychain. Only codesign can use this new private key.
// This identity is for builds on this Mac, not public distribution.
let fm = FileManager.default
let project = URL(fileURLWithPath: fm.currentDirectoryPath)
let directory = project.appending(path: ".local-signing", directoryHint: .isDirectory)
let passwordURL = directory.appending(path: "password")
let keychainURL = directory.appending(path: "development.keychain-db")

func check(_ status: OSStatus, _ action: String) throws {
    guard status == errSecSuccess else {
        throw NSError(domain: "LocalSigning", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(action)失败（\(status)）"])
    }
}
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "LocalSigning", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent)未完成"])
    }
}

do {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    if !fm.fileExists(atPath: passwordURL.path) {
        guard !fm.fileExists(atPath: keychainURL.path) else { throw NSError(domain: "LocalSigning", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地签名密码文件丢失；不会覆盖已有签名。"] ) }
        var bytes = [UInt8](repeating: 0, count: 32)
        try check(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), "生成本地签名凭据")
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        try Data(value.utf8).write(to: passwordURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)
    }
    let password = try Data(contentsOf: passwordURL)
    var keychain: SecKeychain?
    var previousSearchList: CFArray?
    try check(SecKeychainCopySearchList(&previousSearchList), "读取钥匙串搜索范围")
    defer { if let previousSearchList { _ = SecKeychainSetSearchList(previousSearchList) } }
    if !fm.fileExists(atPath: keychainURL.path) {
        let status = password.withUnsafeBytes { bytes in
            SecKeychainCreate(keychainURL.path, UInt32(password.count), bytes.baseAddress, false, nil, &keychain)
        }
        try check(status, "创建应用专用签名钥匙串")
    } else { try check(SecKeychainOpen(keychainURL.path, &keychain), "读取应用专用签名钥匙串") }
    var activeSearchList = (previousSearchList as? [SecKeychain]) ?? []
    activeSearchList.append(keychain!)
    try check(SecKeychainSetSearchList(activeSearchList as CFArray), "临时接入应用签名钥匙串")
    let unlock = password.withUnsafeBytes { SecKeychainUnlock(keychain, UInt32(password.count), $0.baseAddress, true) }
    try check(unlock, "解锁应用专用签名")
    defer { if let keychain { _ = SecKeychainLock(keychain) } }

    let marker = directory.appending(path: "ready")
    if !fm.fileExists(atPath: marker.path) {
        let pem = directory.appending(path: "private.pem")
        let p12 = directory.appending(path: "identity.p12")
        let cert = directory.appending(path: "certificate.pem")
        let config = directory.appending(path: "certificate.cnf")
        let exportPassword = directory.appending(path: "export-password")
        defer { try? fm.removeItem(at: pem); try? fm.removeItem(at: p12); try? fm.removeItem(at: exportPassword) }
        try password.write(to: exportPassword, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exportPassword.path)
        try """
        [req]
        distinguished_name = dn
        x509_extensions = codesign
        prompt = no
        [dn]
        CN = VoiceTodo Local Development
        [codesign]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature
        extendedKeyUsage = critical,codeSigning
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid
        """.write(to: config, atomically: true, encoding: .utf8)
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-config", config.path, "-passout", "file:" + passwordURL.path, "-keyout", pem.path, "-out", cert.path])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pem.path)
        try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", pem.path, "-in", cert.path, "-passin", "file:" + passwordURL.path, "-passout", "file:" + exportPassword.path, "-out", p12.path])
        try run("/usr/bin/security", ["import", p12.path, "-k", keychainURL.path, "-P", String(decoding: password, as: UTF8.self), "-T", "/usr/bin/codesign"])
        try Data("VoiceTodo Local Development\n".utf8).write(to: marker, options: .atomic)
    }
    let publicDER = directory.appending(path: "certificate.der")
    try run("/usr/bin/openssl", ["x509", "-in", directory.appending(path: "certificate.pem").path, "-outform", "DER", "-out", publicDER.path])
    let fingerprint = Insecure.SHA1.hash(data: try Data(contentsOf: publicDER)).map { String(format: "%02x", $0) }.joined()
    try run("/usr/bin/codesign", ["--force", "--sign", fingerprint, "--keychain", keychainURL.path, "--identifier", "com.wyq.voicetodo", project.appending(path: "dist/随口清单.app").path])
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", project.appending(path: "dist/随口清单.app").path])
    print("应用专用本地签名与验证已完成。")
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}

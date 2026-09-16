import Foundation

/// Stores only lifecycle metadata. There is deliberately no transcript, field
/// value, clipboard value, task title, window title, or ordinary key field.
@MainActor final class CaptureDiagnostics {
    enum Stage: String, Codable {
        case pressed, released, bound, noInputDestination, inputMethodFront, editorFront, fieldTemporarilyUnavailable
        case fieldTextChanged, clipboardChanged, ended, commandReceived, ordinaryText, timedOut
        case applicationChanged, inputFieldChanged, secureField, cancelled, processing, applied, processingFailed
        case fieldRebound, temporaryFocus, fieldContextChanged, fieldInsertionDetected
        case fieldAnchorUnavailable, fieldWindowChanged, fieldIdentityChanged
        case fieldOrdinaryPending, clipboardOrdinaryPending, fieldCommandReceived, clipboardCommandReceived
        case localSpeechStarted, localSpeechReady, localSpeechFinal, localSpeechEmpty, localSpeechFailed
        var label: String {
            switch self {
            case .pressed: "Fn 按下"
            case .localSpeechStarted: "本机语音开始"
            case .localSpeechReady: "本机识别已就绪"
            case .localSpeechFinal: "本机语音已定稿"
            case .localSpeechEmpty: "本次未识别到文字"
            case .localSpeechFailed: "本机语音未完整结束"
            case .released: "Fn 松开"
            case .noInputDestination: "未找到原输入应用"
            case .bound: "已绑定原输入位置"
            case .inputMethodFront: "输入法窗口介入，继续接收"
            case .editorFront: "回到原应用"
            case .fieldTemporarilyUnavailable: "输入框暂时不可读"
            case .fieldTextChanged: "输入框文字有变化"
            case .fieldRebound: "输入框刷新，继续接收"
            case .temporaryFocus: "焦点暂离输入框，保留原位置"
            case .fieldContextChanged: "原输入框上下文变化，尚未提取转写"
            case .fieldInsertionDetected: "已提取新增文字，等待结束并稳定"
            case .fieldAnchorUnavailable: "输入位置缺少可核对的标识"
            case .fieldWindowChanged: "输入窗口已变化"
            case .fieldIdentityChanged: "新焦点与原输入位置不匹配"
            case .clipboardChanged: "收到新复制内容"
            case .fieldOrdinaryPending: "输入框暂未识别到待办，继续等候最终文字"
            case .clipboardOrdinaryPending: "复制内容暂未识别到待办，继续等候最终文字"
            case .fieldCommandReceived: "从原输入框接收待办文字"
            case .clipboardCommandReceived: "从本次复制接收待办文字"
            case .ended: "收到结束信号"
            case .commandReceived: "收到待办候选文字"
            case .ordinaryText: "普通转写，未改变清单"
            case .timedOut: "未收到完整转写"
            case .applicationChanged: "切换到其他应用，接收结束"
            case .inputFieldChanged: "切换输入位置，接收结束"
            case .secureField: "密码输入框不接收"
            case .cancelled: "已取消接收"
            case .processing: "正在理解收到的文字"
            case .applied: "处理结束"
            case .processingFailed: "理解失败，文字已保留待处理"
            }
        }
    }
    struct Event: Codable { var stage: Stage; var at: Date; var application: String? }
    struct Session: Codable {
        var id: String; var startedAt: Date; var sourceApplication: String?; var build: String
        var fieldReadable: Bool; var events: [Event]
    }
    private(set) var sessions: [Session] = []
    let url: URL
    var onChange: ((String) -> Void)?
    init(url: URL) {
        self.url = url
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let rows = try? decoder.decode([Session].self, from: data) {
            sessions = Array(rows.suffix(12))
        }
    }
    var summary: String {
        guard let session = sessions.last else { return "尚无接收记录" }
        let time = DateFormatter(); time.locale = Locale(identifier: "zh_CN"); time.dateFormat = "HH:mm:ss"
        return time.string(from: session.startedAt) + " · " + (session.events.last?.stage.label ?? "开始接收")
            + "\n" + session.events.suffix(6).map(\.stage.label).joined(separator: " → ")
    }
    func start(id: String, source: String?, fieldReadable: Bool) {
        sessions.append(Session(id: id, startedAt: .now, sourceApplication: source, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "test", fieldReadable: fieldReadable,
                                events: [.init(stage: .pressed, at: .now)]))
        sessions = Array(sessions.suffix(12)); save()
    }
    func record(_ stage: Stage, id: String, application: String? = nil, once: Bool = false) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if once && sessions[index].events.contains(where: { $0.stage == stage }) { return }
        sessions[index].events.append(.init(stage: stage, at: .now, application: application))
        sessions[index].events = Array(sessions[index].events.suffix(32)); save()
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sessions).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            onChange?(summary)
        } catch { onChange?(summary + "\n接收诊断未能保存") }
    }
}

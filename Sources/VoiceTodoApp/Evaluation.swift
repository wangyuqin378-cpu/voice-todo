import Foundation
import Speech
import AVFoundation
import VoiceTodoCore

// Explicit command-line QA only: uses synthetic fixture tasks and never opens or changes the user's store.
@MainActor enum Evaluation {
    static func run(casesPath: String, outputPath: String) async -> Int32 {
        do {
            let cases = try JSONDecoder().decode([EvaluationCase].self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
            guard !cases.isEmpty, Set(cases.map(\.id)).count == cases.count else {
                throw UserFacingError("验收用例不能为空，且每条用例需要唯一标识。")
            }
            for item in cases { _ = try item.validate() }
            let key = try AIKey.read(configuration: AppSettings().configuration)
            guard !key.isEmpty else { print("尚未配置 AI 密钥。请在随口清单设置中保存并检查连接，再运行验收。未执行任何 AI 测试。"); return 2 }
            let client = AIClient(configuration: AppSettings().configuration)
            var rows: [[String: Any]] = []
            for item in cases {
                let (now, zone) = try item.validate()
                let seed = item.pending.enumerated().map { TodoItem(id: "p\($0.offset)", title: $0.element, createdAt: now) }
                    + item.done.enumerated().map { TodoItem(id: "d\($0.offset)", title: $0.element, createdAt: now, completedAt: now) }
                let workspace = Workspace(tasks: seed)
                let start = Date.now
                do {
                    let local = LocalInterpreter.interpret(item.text, workspace: workspace, question: nil, now: now, timeZone: zone.identifier)
                    let proposal: Proposal
                    if let local { proposal = local }
                    else { proposal = try await client.interpret(input: item.text, workspace: workspace, question: nil, key: key, now: now, timeZone: zone.identifier) }
                    let result = try TaskReducer.apply(proposal, to: workspace, inputID: item.id, input: item.text, now: now, timeZone: zone.identifier)
                    let check = EvaluationChecks.compare(result.workspace, seed: workspace, expected: item)
                    rows.append(["id": item.id, "input": item.text, "automaticChecksPassed": check.passed, "falseCompletion": check.falseCompletion,
                                 "issues": check.issues, "interpretationDate": item.nowISO, "timeZone": item.timeZoneID,
                                 "seconds": Date.now.timeIntervalSince(start), "route": local == nil ? "ai" : "local", "messages": result.messages,
                                 "expected": try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)),
                                 "actual": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.workspace)),
                                 "actions": try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal))])
                    print("\(item.id): \(check.passed ? "自动字段检查通过，仍需人工复核" : "需检查：" + check.issues.joined(separator: "；"))")
                } catch {
                    rows.append(["id": item.id, "input": item.text, "automaticChecksPassed": false, "error": error.localizedDescription, "seconds": Date.now.timeIntervalSince(start)])
                    print("\(item.id): 未通过（请求或校验失败）")
                }
            }
            let passed = rows.filter { $0["automaticChecksPassed"] as? Bool == true }.count
            let report: [String: Any] = ["scope": "本地快速处理＋真实 AI 单轮文字到动作；核对预期标题、时间与状态。不包含麦克风、桌面、通知送达或多轮追问验收。", "acceptance": "requiresHumanReview", "date": Dates.iso(.now), "cases": rows, "automaticChecksPassed": passed, "total": rows.count]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            return passed == rows.count ? 0 : 1
        } catch { print("验收未完成：\(error.localizedDescription)"); return 2 }
    }

    static func transcribeFile(path: String) async -> Int32 {
        do {
            let module = SpeechTranscriber(locale: Locale(identifier: "zh_CN"), preset: .progressiveTranscription)
            let analyzer = SpeechAnalyzer(modules: [module])
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            var text = ""
            let results = Task {
                for try await result in module.results where result.isFinal { text += String(result.text.characters) }
            }
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            try await results.value
            print(text)
            return text.isEmpty ? 1 : 0
        } catch { print("语音文件识别失败：\(error.localizedDescription)"); return 2 }
    }
}

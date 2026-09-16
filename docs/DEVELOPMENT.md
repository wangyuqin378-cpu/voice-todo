# 构建与验证

当前实现使用 SwiftUI、AppKit、SwiftData、SpeechAnalyzer 和系统本地通知，无第三方 Swift 依赖。最低 macOS 26，工具链为完整 Xcode 26 / Swift 6.2。

## 本机构建

```sh
git clone https://github.com/wangyuqin378-cpu/voice-todo.git
cd voice-todo
swift test
zsh scripts/build-app.sh
open 'dist/随口清单.app'
```

构建脚本默认使用 `/Applications/Xcode.app/Contents/Developer`。Xcode 在其他位置时可指定 `DEVELOPER_DIR`；如果系统没有选中完整 Xcode，运行 `swift test` 前也需指定该变量。

脚本在 `dist/` 生成应用，创建并复用项目专用开发签名；相关文件位于被忽略的 `.local-signing/`。保留该目录可避免更新时更换签名；不要上传或分享。可通过 `CODE_SIGN_IDENTITY` 指定自己的身份。本机开发签名**不是公证后的公开分发包**，不要将本机启动成功视为其他设备的安装验收。

## 测试

```sh
swift test
```

默认不联网、不打开个人任务库。显式联网验收会使用已配置服务并产生该服务的调用费用：

```sh
VOICETODO_LIVE_QA=1 swift test --filter LiveConversationTests
'dist/随口清单.app/Contents/MacOS/VoiceTodo' --evaluate qa/cases.json /tmp/voice-todo-evaluation.json
```

验收使用合成任务，不写入日常清单。第二条命令测试本机规则与真实 AI 的文字处理，不包含麦克风、其他输入法接收或通知实际展示。用例同时核对同一条事项的日期、时间精度和提醒，不允许把不同任务的字段拼成“通过”。

已有结果与待完成的真实设备检查见 [build28 回归记录](REVIEW-BUILD28.md) 与 [build27 历史审阅](REVIEW.md)。文档中的统计是该次验收记录，不是持续运行的 CI 状态或其他机器上的通过保证。

## 代码入口

| 位置 | 责任 |
| --- | --- |
| `Sources/VoiceTodoApp/GlobalHotkey.swift` | 系统按键观察与模式路由；当前 Fn 路径固定 |
| `Sources/VoiceTodoApp/FnSpeechCapture.swift`、`SpeechService.swift` | 本机语音会话和 SpeechAnalyzer |
| `Sources/VoiceTodoApp/InputMethodBridge.swift` | 试验性的外部转写接收 |
| `Sources/VoiceTodoCore/` | 输入判断、日期、动作提议、独立校验、任务与撤销 |
| `Sources/VoiceTodoApp/NotificationService.swift` | 系统通知调度与状态核对 |
| `Tests/`、`qa/cases.json` | 单元测试、多轮对话和合成文字验收 |

两个输入路径及数据写入边界见 [架构](ARCHITECTURE.md)。

## 报告与贡献

问题报告请写清预期和实际结果，提供版本、系统、语音工具、目标应用、入口模式及最短复现步骤。优先使用虚构事项；不要提交密钥、个人数据库、原始录音或未脱敏截图。

当前仓库尚未指定开源许可证；许可证决定会单独公布。

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceTodo",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "VoiceTodo", targets: ["VoiceTodoApp"])],
    targets: [
        .target(name: "VoiceTodoCore"),
        .executableTarget(name: "VoiceTodoApp", dependencies: ["VoiceTodoCore"]),
        .testTarget(name: "VoiceTodoCoreTests", dependencies: ["VoiceTodoCore"]),
        .testTarget(name: "VoiceTodoAppTests", dependencies: ["VoiceTodoApp"])
    ],
    swiftLanguageModes: [.v5]
)

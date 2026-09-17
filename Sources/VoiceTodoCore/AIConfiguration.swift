import Foundation

public enum AIProtocol: String, Codable, CaseIterable, Sendable {
    case automatic, chatCompletions, anthropicMessages
    public var label: String {
        switch self {
        case .automatic: "自动（按接口地址）"
        case .chatCompletions: "OpenAI 兼容接口"
        case .anthropicMessages: "Claude / Anthropic 接口"
        }
    }
}

public struct AIConfiguration: Codable, Hashable, Sendable {
    public var baseURL: String
    public var model: String
    public var apiProtocol: AIProtocol
    public init(baseURL: String = "https://dashscope.aliyuncs.com/compatible-mode/v1", model: String = "qwen-flash", apiProtocol: AIProtocol = .automatic) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiProtocol = apiProtocol
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(baseURL: try values.decode(String.self, forKey: .baseURL),
                  model: try values.decode(String.self, forKey: .model),
                  apiProtocol: try values.decodeIfPresent(AIProtocol.self, forKey: .apiProtocol) ?? .automatic)
    }
    public var resolvedProtocol: AIProtocol {
        if apiProtocol != .automatic { return apiProtocol }
        let url = URL(string: baseURL)
        return url?.host?.lowercased() == "api.anthropic.com" || url?.path.hasSuffix("/messages") == true
            ? .anthropicMessages : .chatCompletions
    }
    public func endpoint() throws -> URL {
        guard var url = URL(string: baseURL), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AIServiceError(.configuration, "AI 地址需要是有效的 HTTPS 接口地址。")
        }
        guard !model.isEmpty else { throw AIServiceError(.configuration, "请填写该服务实际可用的模型名称。") }
        let messages = resolvedProtocol == .anthropicMessages
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") || path.hasSuffix("messages") {
            guard (messages && path.hasSuffix("messages")) || (!messages && path.hasSuffix("chat/completions")) else {
                throw AIServiceError(.configuration, "接口地址和接口类型不一致，请检查设置。")
            }
            return url
        }
        if messages, path.isEmpty { url.appendPathComponent("v1") }
        return url.appendingPathComponent(messages ? "messages" : "chat/completions")
    }
}

/// Safe, fixed descriptions only; never expose a provider's response body or credentials.
public struct AIServiceError: Error, LocalizedError, Sendable {
    public enum Kind: Sendable { case configuration, credentials, temporary, invalidResponse }
    public let kind: Kind
    public let message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public var errorDescription: String? { message }
}

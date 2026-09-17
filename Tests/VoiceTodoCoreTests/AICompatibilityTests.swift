import XCTest
@testable import VoiceTodoCore

private final class ProviderFixture: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AICompatibilityTests: XCTestCase {
    private let fakeKey = "fake-qa-key-not-a-credential"
    private let noop = #"{"actions":[{"kind":"noop"}]}"#
    private func completion(_ content: String, finish: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
    }
    private func message(_ content: String, stop: String = "end_turn") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": content]], "stop_reason": stop])
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }
            data = result
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }
    private func client(_ config: AIConfiguration) -> AIClient {
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [ProviderFixture.self]
        return AIClient(configuration: config, session: URLSession(configuration: sessionConfig), compatibility: AICompatibility())
    }
    func testExistingConfigMigratesAndNativeEndpointIsResolved() throws {
        let old = Data(#"{"baseURL":"https://api.anthropic.com","model":"claude-test"}"#.utf8)
        let config = try JSONDecoder().decode(AIConfiguration.self, from: old)
        XCTAssertEqual(config.apiProtocol, .automatic)
        XCTAssertEqual(try config.endpoint().absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(config, try JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(config)))
        XCTAssertEqual(try AIConfiguration(baseURL: "https://example.com/v1/chat/completions/", model: "any-model").endpoint().path, "/v1/chat/completions")
        XCTAssertThrowsError(try AIConfiguration(baseURL: "https://example.com/v1/messages", model: "x", apiProtocol: .chatCompletions).endpoint())
    }
    func testNativeClaudeRequestHasNoFlashOrChatOnlyParameters() throws {
        let client = AIClient(configuration: .init(baseURL: "https://api.anthropic.com/v1", model: "claude-test"))
        let request = try client.makeRequest(key: fakeKey, content: "{}", profile: .init())
        let value = try body(request)
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), fakeKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(value["model"] as? String, "claude-test")
        XCTAssertNotNil(value["system"])
        for field in ["temperature", "response_format", "thinking", "enable_thinking"] { XCTAssertNil(value[field], field) }
        XCTAssertEqual((value["messages"] as? [[String: String]])?.count, 1)
    }
    func testCustomGatewayCanExplicitlyChooseEitherProtocol() throws {
        let config = AIConfiguration(baseURL: "https://example.com/proxy/v1", model: "claude-test")
        XCTAssertEqual(config.resolvedProtocol, .chatCompletions, "A model name is not evidence of the gateway protocol")
        var native = config; native.apiProtocol = .anthropicMessages
        XCTAssertEqual(try native.endpoint().path, "/proxy/v1/messages")
        let client = AIClient(configuration: .init(baseURL: config.baseURL, model: "deepseek-test"))
        let value = try body(client.makeRequest(key: fakeKey, content: "{}", profile: .init()))
        XCTAssertNil(value["thinking"], "Vendor extensions must not follow model names to arbitrary gateways")
        XCTAssertNil(value["temperature"])
    }
    func testExistingOfficialProviderRetainsItsValidatedSettings() throws {
        let client = AIClient(configuration: .init(baseURL: "https://api.deepseek.com", model: "deepseek-test"))
        let value = try body(client.makeRequest(key: fakeKey, content: "{}", profile: .init()))
        XCTAssertEqual((value["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(value["temperature"] as? Double, 0.1)
        let basic = try body(client.makeRequest(key: fakeKey, content: "{}", profile: .init(basic: true)))
        XCTAssertNil(basic["temperature"]); XCTAssertNil(basic["thinking"])
    }
    func testClaudeResponseAndWholeFencesDecodeButIncompleteOrProseCannotApply() throws {
        let client = AIClient(configuration: .init(baseURL: "https://api.anthropic.com", model: "claude-test"))
        XCTAssertEqual(try client.decodeProposal(message("```json\n" + noop + "\n```" )).actions.first?.kind, .noop)
        XCTAssertThrowsError(try client.decodeProposal(message(noop, stop: "max_tokens")))
        XCTAssertThrowsError(try client.decodeProposal(message("Here is your answer " + noop)))
        XCTAssertThrowsError(try client.decodeProposal(message(#"{"actions":[]}"#)))
        let chat = AIClient(configuration: .init())
        XCTAssertThrowsError(try chat.decodeProposal(completion(noop, finish: "length")))
        XCTAssertThrowsError(try chat.decodeProposal(completion(noop, finish: "content_filter")))
    }
    func testUnsupportedJSONModeRetriesSameProviderThenRemembersCompatibility() async throws {
        let client = client(.init(baseURL: "https://fixture.example/v1", model: "non-flash-model"))
        let success = try completion(noop); var count = 0
        ProviderFixture.handler = { request in
            count += 1
            XCTAssertEqual(request.url?.host, "fixture.example")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.fakeKey)
            let value = try self.body(request)
            XCTAssertEqual(value["model"] as? String, "non-flash-model")
            if count == 1 {
                XCTAssertNotNil(value["response_format"])
                return (400, Data(#"{"error":{"message":"response_format is not supported"}}"#.utf8))
            }
            XCTAssertNil(value["response_format"])
            return (200, success)
        }
        defer { ProviderFixture.handler = nil }
        for _ in 0..<2 { _ = try await client.interpret(input: "记一下买牛奶", workspace: .init(), question: nil, key: fakeKey) }
        XCTAssertEqual(count, 3, "First call negotiates once; next call uses the supported shape")
    }
    func testAuthAndMissingModelNeverTriggerCompatibilityRetry() async throws {
        for status in [401, 403, 404] {
            let client = client(.init(baseURL: "https://fixture.example/v1", model: "test")); var calls = 0
            ProviderFixture.handler = { _ in calls += 1; return (status, Data()) }
            do { _ = try await client.interpret(input: "hello", workspace: .init(), question: nil, key: fakeKey); XCTFail("Expected rejection") }
            catch let error as AIServiceError { XCTAssertTrue(error.kind == .credentials || error.kind == .configuration) }
            XCTAssertEqual(calls, 1)
        }
        ProviderFixture.handler = nil
    }
    func testCompatibilityRetryIsBoundedAndDoesNotSalvageInvalidOutput() async throws {
        let client = client(.init(baseURL: "https://fixture.example/v1", model: "test")); var calls = 0
        ProviderFixture.handler = { _ in calls += 1; return (400, Data("unsupported response_format".utf8)) }
        defer { ProviderFixture.handler = nil }
        do { _ = try await client.interpret(input: "hello", workspace: .init(), question: nil, key: fakeKey); XCTFail("Expected rejection") }
        catch is AIServiceError {}
        XCTAssertEqual(calls, 2)
    }
    func testTokenParameterOnlyChangesAfterExplicitProviderRejection() throws {
        let profile = try XCTUnwrap(AIClient.compatibleProfile(status: 400, data: Data("Unsupported max_tokens; use max_completion_tokens".utf8), current: .init()))
        let value = try body(AIClient(configuration: .init()).makeRequest(key: fakeKey, content: "{}", profile: profile))
        XCTAssertNil(value["max_tokens"]); XCTAssertEqual(value["max_completion_tokens"] as? Int, 6000)
        XCTAssertNil(AIClient.compatibleProfile(status: 400, data: Data("invalid model".utf8), current: .init()))
        XCTAssertNil(AIClient.compatibleProfile(status: 429, data: Data("unsupported response_format".utf8), current: .init()))
    }
    func testProviderErrorsNeverEchoResponseContents() {
        let detail = Data("private task content and fake-qa-key-not-a-credential".utf8)
        for code in [400, 401, 402, 403, 404, 422, 429, 500] {
            XCTAssertFalse(AIClient.serviceError(status: code, data: detail).message.contains("fake-qa"))
        }
    }
}

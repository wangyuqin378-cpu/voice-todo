import Foundation

/// In-memory only. The cache contains capabilities, never keys, task text or responses.
public actor AICompatibility {
    public static let shared = AICompatibility()
    public struct Profile: Equatable, Sendable {
        var basic = false
        var completionTokens = false
    }
    private var profiles: [AIConfiguration: Profile] = [:]
    public init() {}
    func profile(for configuration: AIConfiguration) -> Profile { profiles[configuration] ?? .init() }
    func remember(_ profile: Profile, for configuration: AIConfiguration) { profiles[configuration] = profile }
    public func reset(_ configuration: AIConfiguration) { profiles.removeValue(forKey: configuration) }
}

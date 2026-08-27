import Foundation

public struct BackendConfig: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let baseURL: URL
    public var displayName: String

    public init(baseURL: URL, displayName: String? = nil) {
        self.id = baseURL.absoluteString
        self.baseURL = baseURL
        self.displayName = displayName ?? baseURL.host() ?? baseURL.absoluteString
    }
}

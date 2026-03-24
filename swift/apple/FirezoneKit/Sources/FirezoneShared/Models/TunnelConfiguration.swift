import Foundation

// Configuration does not conform to Decodable, so introduce a simpler type here to encode for IPC
public struct TunnelConfiguration: Codable, Sendable {
  public let apiURL: String
  public let accountSlug: String
  public let logFilter: String
  public let internetResourceEnabled: Bool

  public init(apiURL: String, accountSlug: String, logFilter: String, internetResourceEnabled: Bool)
  {
    self.apiURL = apiURL
    self.accountSlug = accountSlug
    self.logFilter = logFilter
    self.internetResourceEnabled = internetResourceEnabled
  }
}

extension TunnelConfiguration: Equatable {
  public static func == (lhs: TunnelConfiguration, rhs: TunnelConfiguration) -> Bool {
    return lhs.apiURL == rhs.apiURL && lhs.accountSlug == rhs.accountSlug
      && lhs.logFilter == rhs.logFilter
      && lhs.internetResourceEnabled == rhs.internetResourceEnabled
  }
}

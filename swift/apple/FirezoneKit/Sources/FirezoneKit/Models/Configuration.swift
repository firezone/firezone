import Foundation

public class Configuration: Codable {
#if DEBUG
  public static let defaultAuthURL = "https://app.firez.one"
  public static let defaultApiURL = "wss://api.firez.one"
  public static let defaultLogFilter = "debug"
#else
  public static let defaultAuthURL = "https://app.firezone.dev"
  public static let defaultApiURL = "wss://api.firezone.dev"
  public static let defaultLogFilter = "info"
#endif

  public struct Keys {
    public static let authURL = "authURL"
    public static let apiURL = "apiURL"
    public static let logFilter = "logFilter"
    public static let actorName = "actorName"
    public static let accountSlug = "accountSlug"
    public static let internetResourceEnabled = "internetResourceEnabled"
    public static let firezoneId = "firezoneId"
  }

  public var authURL: String?
  public var actorName: String?
  public var firezoneId: String?
  public var apiURL: String?
  public var logFilter: String?
  public var accountSlug: String?
  public var internetResourceEnabled: Bool?

  private var overriddenKeys: Set<String> = []

  public init(userDict: [String: Any?], managedDict: [String: Any?]) {
    self.actorName = userDict[Keys.actorName] as? String
    self.firezoneId = userDict[Keys.firezoneId] as? String

    setValue(forKey: Keys.authURL, from: managedDict, and: userDict) { [weak self] in self?.authURL = $0 }
    setValue(forKey: Keys.apiURL, from: managedDict, and: userDict) { [weak self] in self?.apiURL = $0 }
    setValue(forKey: Keys.logFilter, from: managedDict, and: userDict) { [weak self] in self?.logFilter = $0 }
    setValue(forKey: Keys.accountSlug, from: managedDict, and: userDict) { [weak self] in self?.accountSlug = $0 }
    setValue(forKey: Keys.internetResourceEnabled, from: managedDict, and: userDict) { [weak self] in
      self?.internetResourceEnabled = $0
    }
  }

  func isOverridden(_ key: String) -> Bool {
    return overriddenKeys.contains(key)
  }

  private func setValue<T>(
    forKey key: String,
    from managedDict: [String: Any?],
    and userDict: [String: Any?],
    setter: (T) -> Void
  ) {
    if let value = managedDict[key] as? T {
      overriddenKeys.insert(key)
      setter(value)
    } else if let value = userDict[key] as? T {
      setter(value)
    }
  }
}

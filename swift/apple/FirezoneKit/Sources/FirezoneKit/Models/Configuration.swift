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

  public static let defaultAccountSlug = ""
  public static let defaultConnectOnStart = true
  public static let defaultDisableUpdateCheck = false

  public struct Keys {
    public static let authURL = "authURL"
    public static let apiURL = "apiURL"
    public static let logFilter = "logFilter"
    public static let accountSlug = "accountSlug"
    public static let internetResourceEnabled = "internetResourceEnabled"
    public static let firezoneId = "firezoneId"
    public static let hideAdminPortalMenuItem = "hideAdminPortalMenuItem"
    public static let connectOnStart = "connectOnStart"
    public static let disableUpdateCheck = "disableUpdateCheck"
  }

  public var authURL: String?
  public var firezoneId: String?
  public var apiURL: String?
  public var logFilter: String?
  public var accountSlug: String?
  public var internetResourceEnabled: Bool?
  public var hideAdminPortalMenuItem: Bool?
  public var connectOnStart: Bool?
  public var disableUpdateCheck: Bool?

  private var overriddenKeys: Set<String> = []

  public init(userDict: [String: Any?], managedDict: [String: Any?]) {
    self.firezoneId = userDict[Keys.firezoneId] as? String

    setValue(forKey: Keys.authURL, from: managedDict, and: userDict) { [weak self] in self?.authURL = $0 }
    setValue(forKey: Keys.apiURL, from: managedDict, and: userDict) { [weak self] in self?.apiURL = $0 }
    setValue(forKey: Keys.logFilter, from: managedDict, and: userDict) { [weak self] in self?.logFilter = $0 }
    setValue(forKey: Keys.accountSlug, from: managedDict, and: userDict) { [weak self] in self?.accountSlug = $0 }
    setValue(forKey: Keys.internetResourceEnabled, from: managedDict, and: userDict) { [weak self] in
      self?.internetResourceEnabled = $0
    }
    setValue(forKey: Keys.hideAdminPortalMenuItem, from: managedDict, and: userDict) { [weak self] in
      self?.hideAdminPortalMenuItem = $0
    }
    setValue(forKey: Keys.connectOnStart, from: managedDict, and: userDict) { [weak self] in
      self?.connectOnStart = $0
    }
    setValue(forKey: Keys.disableUpdateCheck, from: managedDict, and: userDict) { [weak self] in
      self?.disableUpdateCheck = $0
    }
  }

  func isOverridden(_ key: String) -> Bool {
    return overriddenKeys.contains(key)
  }

  func applySettings(_ settings: Settings) {
    self.authURL = settings.authURL
    self.apiURL = settings.apiURL
    self.logFilter = settings.logFilter
    self.accountSlug = settings.accountSlug
    self.connectOnStart = settings.connectOnStart
  }

  private func setValue<T>(
    forKey key: String,
    from managedDict: [String: Any?],
    and userDict: [String: Any?],
    setter: (T) -> Void
  ) {
    if let value = managedDict[key],
       let typedValue = value as? T {
      overriddenKeys.insert(key)
      return setter(typedValue)
    }

    if let value = userDict[key],
       let typedValue = value as? T {
      setter(typedValue)
    }
  }
}

//
//  Configuration.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public class Configuration {
  public static var shared: Configuration = .init()

  public enum Keys {
    static let favoriteResourceIDs = "dev.firezone.config.favoriteResourceIDs"
    static let actorName = "dev.firezone.config.actorName"
    static let authURL = "dev.firezone.config.authURL"
    static let apiURL = "dev.firezone.config.apiURL"
    static let logFilter = "dev.firezone.config.logFilter"
    static let accountSlug = "dev.firezone.config.accountSlug"
    static let lastDismissedVersion = "dev.firezone.config.lastDismissedVersion"
    static let lastNotifiedVersion = "dev.firezone.config.lastNotifiedVersion"
    static let firezoneId = "dev.firezone.config.firezoneId"
    public static let internetResourceEnabled = "dev.firezone.config.internetResourceEnabled"
  }

  // We expose all configuration getters to return Optionals so that any consumers of this class may distinguish
  // between a key that's unset vs set.
  public var favoriteResourceIDs: [String]? {
    get { userDefaults.stringArray(forKey: Keys.favoriteResourceIDs) }
    set { userDefaults.set(newValue, forKey: Keys.favoriteResourceIDs) }
  }

  public var actorName: String? {
    get { userDefaults.string(forKey: Keys.actorName) }
    set { userDefaults.set(newValue, forKey: Keys.actorName) }
  }

  public var authURL: URL? {
    get { userDefaults.url(forKey: Keys.authURL) }
    set { userDefaults.set(newValue, forKey: Keys.authURL) }
  }

  public var apiURL: URL? {
    get { userDefaults.url(forKey: Keys.apiURL) }
    set { userDefaults.set(newValue, forKey: Keys.apiURL) }
  }

  public var logFilter: String? {
    get { userDefaults.string(forKey: Keys.logFilter) }
    set { userDefaults.set(newValue, forKey: Keys.logFilter) }
  }

  public var accountSlug: String? {
    get { userDefaults.string(forKey: Keys.accountSlug) }
    set { userDefaults.set(newValue, forKey: Keys.accountSlug) }
  }

  public var internetResourceEnabled: Bool? {
    get { userDefaults.bool(forKey: Keys.internetResourceEnabled) }
    set { userDefaults.set(newValue, forKey: Keys.internetResourceEnabled) }
  }

  public var lastDismissedVersion: String? {
    get { userDefaults.string(forKey: Keys.lastDismissedVersion) }
    set { userDefaults.set(newValue, forKey: Keys.lastDismissedVersion) }
  }

  public var lastNotifiedVersion: String? {
    get { userDefaults.string(forKey: Keys.lastNotifiedVersion) }
    set { userDefaults.set(newValue, forKey: Keys.lastNotifiedVersion) }
  }

  public var firezoneId: String? {
    get { userDefaults.string(forKey: Keys.firezoneId) }
    set { userDefaults.set(newValue, forKey: Keys.firezoneId) }
  }

  // Use these to provide default values at the call site if needed
#if DEBUG
  public static let defaultAuthURL = URL(string: "https://app.firez.one")!
  public static let defaultApiURL = URL(string: "wss://api.firez.one")!
  public static let defaultLogFilter = "debug"
#else
  private let defaultAuthURL = URL(string: "https://app.firezone.dev")!
  private let defaultApiURL = URL(string: "wss://api.firezone.dev")!
  private let defaultLogFilter = "info"
#endif

  private var userDefaults: UserDefaults

  // Stores the last known values for keys to detect changes.
  // The value type is Any? because userDefaults.object(forKey:) returns Any?.
  private var cachedValues: [String: Any?] = [:]

  public init() {
    guard let defaults = UserDefaults(suiteName: BundleHelper.appGroupId)
    else {
      fatalError("Could not initialize configuration for group id \(BundleHelper.appGroupId)")
    }

    self.userDefaults = defaults

    // These can be removed after the majority of users upgrade > 1.4.14
    migrateUpdateChecker()
    migrateFavorites()
    migrateFirezoneIdOrGenerateNewOne()
  }

  // MARK: - Observation

  public class ObserverToken {
    private let removeHandler: () -> Void
    fileprivate init(removeHandler: @escaping () -> Void) {
      self.removeHandler = removeHandler
    }
    public func remove() {
      removeHandler()
    }
    deinit {
      // Automatically remove the observer when the token is deallocated.
      removeHandler()
    }
  }

  @discardableResult
  public func addObserver(
    forKeys keys: [String]? = nil,
    queue: DispatchQueue = .main,
    handler: @escaping (_ changedKey: String?, _ configuration: Configuration) -> Void
  ) -> ObserverToken {
    let observer = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: self.userDefaults,
      queue: OperationQueue.main
    ) { [weak self] _ in // The notification object itself isn't passed to this handler type.
      guard let self = self else { return }

      var changedKeyForHandler: String?
      var shouldCallHandler = false

      if let specificKeys = keys, !specificKeys.isEmpty {
        for key in specificKeys where self.didValueChange(forKey: key) {
          changedKeyForHandler = key
          shouldCallHandler = true
          break
        }
      } else {
        shouldCallHandler = true
      }

      if shouldCallHandler {
        queue.async {
          handler(changedKeyForHandler, self)
        }
      }
    }

    return ObserverToken { [weak self] in
      self?.removeObserver(observer)
    }
  }

  private func removeObserver(_ observer: NSObjectProtocol) {
    NotificationCenter.default.removeObserver(observer)
  }

  private func didValueChange(forKey key: String) -> Bool {
    let currentValue: Any? = userDefaults.object(forKey: key)
    let previousOptionalValueFromCache: Any?? = cachedValues[key]
    let previousEffectiveValue: Any?

    if let definitePreviousOptional = previousOptionalValueFromCache { // Unwraps from Optional<Any?> to Any?
      previousEffectiveValue = definitePreviousOptional
    } else {
      previousEffectiveValue = nil
    }

    let changed = !areValuesEqual(previousEffectiveValue, currentValue)

    // Always update the cache to the current value for the next comparison.
    // Storing `currentValue` (which is `Any?`) into `cachedValues[key]`.
    // If `currentValue` is `nil`, `cachedValues[key]` will store `.some(nil)`.
    // If `currentValue` is `.some(data)`, `cachedValues[key]` will store `.some(.some(data))`.
    cachedValues[key] = currentValue

    return changed
  }

  private func areValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
      return true
    case (let unwrappedLHS?, let unwrappedRHS?):
      // UserDefaults stores property list types, which bridge to NSObject subclasses.
      // Compare using NSObject's isEqual method for robustness with these types.
      if let lhsObject = unwrappedLHS as? NSObject, let rhsObject = unwrappedRHS as? NSObject {
        return lhsObject.isEqual(rhsObject)
      }

      return false
    default:
      return false
    }
  }

  // MARK: - Migration

  private func migrateUpdateChecker() {
    let decoder = PropertyListDecoder()

    if let data = UserDefaults.standard.object(forKey: "lastDismissedVersion") as? Data,
       let version = try? decoder.decode(SemanticVersion.self, from: data) {
      self.userDefaults.set(version.description, forKey: Keys.lastDismissedVersion)
      UserDefaults.standard.removeObject(forKey: "lastDismissedVersion")
    }

    if let data = UserDefaults.standard.object(forKey: "lastNotifiedVersion") as? Data,
       let version = try? decoder.decode(SemanticVersion.self, from: data) {
      self.userDefaults.set(version.description, forKey: Keys.lastNotifiedVersion)
      UserDefaults.standard.removeObject(forKey: "lastNotifiedVersion")
    }
  }

  private func migrateFavorites() {
    if let ids = UserDefaults.standard.stringArray(forKey: "favoriteResourceIDs") {
      self.userDefaults.set(ids, forKey: Keys.favoriteResourceIDs)
      UserDefaults.standard.removeObject(forKey: "favoriteResourceIDs")
    }
  }

  private func migrateFirezoneIdOrGenerateNewOne() {
    guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BundleHelper.appGroupId),
          let id = try? String(contentsOf: containerURL.appendingPathComponent("firezone-id"))
    else {
      if self.userDefaults.string(forKey: Keys.firezoneId) == nil {
        self.userDefaults.set(UUID().uuidString, forKey: Keys.firezoneId)
      }

      return
    }

    self.userDefaults.set(id, forKey: Keys.firezoneId)
    try? FileManager.default.removeItem(at: containerURL)
  }
}

// Minimal SemanticVersion struct used in migration
private struct SemanticVersion: Codable, CustomStringConvertible {
  let major: Int
  let minor: Int
  let patch: Int
  public var description: String { "\(major).\(minor).\(patch)" }
}

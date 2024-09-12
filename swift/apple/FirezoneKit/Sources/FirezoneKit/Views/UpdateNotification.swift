//
//  UpdateNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//


import Foundation
import UserNotifications
import Cocoa

struct SemanticVersion: Decodable, Encodable, Comparable {
  let major: Int
  let minor: Int
  let patch: Int

  init(major: Int, minor: Int, patch: Int) {
      self.major = major
      self.minor = minor
      self.patch = patch
  }
  
  // This doesn't conform to the full semver spec but it's enough for our use-case
  private static func parse(versionString: String) -> (major: Int, minor: Int, patch: Int)? {
      let components = versionString.split(separator: ".")
      guard components.count == 3,
            let major = Int(components[0]),
            let minor = Int(components[1]),
            let patch = Int(components[2]) else {
          return nil
      }
      return (major, minor, patch)
  }

  init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let versionString = try container.decode(String.self)

      guard let parsed = SemanticVersion.parse(versionString: versionString) else {
          throw DecodingError.dataCorruptedError(in: container,
                                                 debugDescription: "Invalid SemVer string format")
      }

      self.major = parsed.major
      self.minor = parsed.minor
      self.patch = parsed.patch
  }

  static func from(string: String) -> SemanticVersion? {
      guard let parsed = parse(versionString: string) else {
          return nil
      }
      return SemanticVersion(major: parsed.major, minor: parsed.minor, patch: parsed.patch)
  }

  func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      let versionString = "\(major).\(minor).\(patch)"
      try container.encode(versionString)
  }

  static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
      if lhs.major != rhs.major {
          return lhs.major < rhs.major
      }

      if lhs.minor != rhs.minor {
          return lhs.minor < rhs.minor
      }

      return lhs.patch < rhs.patch
  }

  static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
      return lhs.major == rhs.major &&
             lhs.minor == rhs.minor &&
             lhs.patch == rhs.patch
  }
}

private struct VersionInfo: Decodable {
  let apple: SemanticVersion
}

private class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
  @Published private(set) var decision: UNAuthorizationStatus
  private var lastNotifiedVersion: SemanticVersion?
  static let lastDismissedVersionKey = "lastDismissedVersion"
  static let notificationIdentifier = "UPDATE_CATEGORY"

  override public init() {
    try! setLastDissmissedVersion(version:  SemanticVersion.from(string: "0.0.0")!)
    self.decision = .notDetermined
    super.init()

    let notificationCenter = UNUserNotificationCenter.current()

    // Define a custom action
    let dismissAction = UNNotificationAction(identifier: "DISMISS_ACTION",
                                             title: "Dismiss This Version",
                                             options: [.foreground])

    // Define a notification category with the action
    let notificationCategory = UNNotificationCategory(identifier: UpdateNotifier.notificationIdentifier,
                                                       actions: [dismissAction],
                                                       intentIdentifiers: [],
                                                       options: [])

    notificationCenter.setNotificationCategories([notificationCategory])

    notificationCenter.delegate = self
    notificationCenter.requestAuthorization(options: [.sound, .badge, .alert]) { granted, error in
      notificationCenter.getNotificationSettings { notificationSettings in
        self.decision = notificationSettings.authorizationStatus
      }
    }

  }

  public func updateNotification(version: SemanticVersion) {
    Log.app.error("Last dismissed version: \(getLastDismissedVersion())")
    if let lastDismissedVersion = getLastDismissedVersion(), lastDismissedVersion >= version {
      return
    }

    let content = UNMutableNotificationContent()
    lastNotifiedVersion = version
    content.title = "Update Firezone"
    content.body = "New Firezone version available"
    content.sound = .default
    content.categoryIdentifier = UpdateNotifier.notificationIdentifier

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

    let uuidString = UUID().uuidString
    let request = UNNotificationRequest(
      identifier: uuidString, content: content, trigger: trigger
    )

    UNUserNotificationCenter.current().add(request) { error in
      if let error = error {
        Log.app.error("\(#function): Error requesting notification: \(error)")
      }
    }

  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
                              didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
      if response.actionIdentifier == "DISMISS_ACTION" {
        Log.app.error("Dismissing version \(lastNotifiedVersion)")
        try? setLastDissmissedVersion(version: lastNotifiedVersion!)
        return
      }

      if let url = URL(string: "https://apps.apple.com/us/app/firezone/id6443661826") {
        NSWorkspace.shared.open(url)
      }

      completionHandler()
  }
}

class UpdateChecker {
  private var timer: Timer?
  private let updateNotifier: UpdateNotifier = UpdateNotifier()
  private let versionCheckUrl: URL = URL(string: "https://www.firezone.dev/api/releases")!

    init() {
        // Initialize the timer to call the checkForUpdates method every 60 seconds
        startCheckingForUpdates()
    }

    private func startCheckingForUpdates() {
        timer = Timer.scheduledTimer(timeInterval: 6 * 60 * 60, target: self, selector: #selector(checkForUpdates), userInfo: nil, repeats: true)
        checkForUpdates()
    }

    @objc private func checkForUpdates() {
      //let marketingVersion = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
      let marketingVersion = "1.3.0"

      let currentVersion = SemanticVersion.from(string: marketingVersion)!
        let task = URLSession.shared.dataTask(with: versionCheckUrl) { [weak self] data, response, error in
          guard let self = self else { return }


          if let error = error {
            Log.app.error("Error fetching updates: \(error)")
            return
          }

          guard let data = data, let versionString = String(data: data, encoding: .utf8) else {
              Log.app.error("No data or failed to decode data")
              return
            }

          guard let versionString = versionString.data(using: .utf8) else {
            return
          }

          guard let versionInfo = try? JSONDecoder().decode(VersionInfo.self, from: versionString) else {
            return
          }

          let latestVersion = versionInfo.apple

          Log.app.error("Latest version: \(latestVersion)")

          if latestVersion > currentVersion {
            self.updateNotifier.updateNotification(version: latestVersion)
          }

        }

        task.resume()
    }

    deinit {
        timer?.invalidate()
    }
}


func getLastDismissedVersion() -> SemanticVersion? {
  let versionString = UserDefaults.standard.string(forKey: UpdateNotifier.lastDismissedVersionKey)
  guard let versionData = versionString?.data(using: .utf8) else {
    return nil
  }

  return try? JSONDecoder().decode(SemanticVersion.self, from: versionData)
}

func setLastDissmissedVersion(version: SemanticVersion) throws {
  let encodedVersion = try JSONEncoder().encode(version)
  UserDefaults.standard.setValue(String(data: encodedVersion, encoding: .utf8), forKey: UpdateNotifier.lastDismissedVersionKey)
}

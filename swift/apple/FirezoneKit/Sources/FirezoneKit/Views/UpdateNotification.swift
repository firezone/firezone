//
//  UpdateNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Note: it should be easy to expand this module to iOS
#if os(macOS)
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

class UpdateChecker {
  private var timer: Timer?
  private let notificationAdapter: NotificationAdapter = NotificationAdapter()
  private let versionCheckUrl: URL = URL(string: "https://www.firezone.dev/api/releases")!
  private let marketingVersion = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String

  @Published public var updateAvailable: Bool = false

  init() {
      startCheckingForUpdates()
  }

    private func startCheckingForUpdates() {
        timer = Timer.scheduledTimer(timeInterval: 6 * 60 * 60, target: self, selector: #selector(checkForUpdates), userInfo: nil, repeats: true)
        checkForUpdates()
    }

    deinit {
        timer?.invalidate()
    }

    @objc private func checkForUpdates() {

      let currentVersion = SemanticVersion.from(string: marketingVersion)!
        let task = URLSession.shared.dataTask(with: versionCheckUrl) { [weak self] data, response, error in
          guard let self = self else { return }


          if let error = error {
            Log.app.error("Error fetching version manifest: \(error)")
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

          if latestVersion > currentVersion {
            self.updateAvailable = true
            self.notificationAdapter.showUpdateNotification(version: latestVersion)
          }

        }

        task.resume()
    }
}

public let appStoreLink = URL(string: "https://apps.apple.com/app/firezone/id6443661826")!

private class NotificationAdapter: NSObject, UNUserNotificationCenterDelegate {
  private var lastNotifiedVersion: SemanticVersion?
  static let notificationIdentifier = "UPDATE_CATEGORY"
  static let dismissIdentifier = "DISMISS_ACTION"

  override public init() {
    super.init()

    let notificationCenter = UNUserNotificationCenter.current()

    let dismissAction = UNNotificationAction(identifier: NotificationAdapter.dismissIdentifier,
                                             title: "Dismiss This Version",
                                             options: [])

    let notificationCategory = UNNotificationCategory(identifier: NotificationAdapter.notificationIdentifier,
                                                       actions: [dismissAction],
                                                       intentIdentifiers: [],
                                                       options: [])

    notificationCenter.setNotificationCategories([notificationCategory])

    notificationCenter.delegate = self
    notificationCenter.requestAuthorization(options: [.sound, .badge, .alert]) { _, error in
	  if let error = error {
	    Log.app.error("Failed to request authorization for notifications: \(error)")
	  }
    }

  }

  func showUpdateNotification(version: SemanticVersion) {
    if let lastDismissedVersion = getLastDismissedVersion(), lastDismissedVersion >= version {
      return
    }

    let content = UNMutableNotificationContent()
    lastNotifiedVersion = version
    content.title = "Update Firezone"
    content.body = "New Firezone version available"
    content.sound = .default
    content.categoryIdentifier = NotificationAdapter.notificationIdentifier


    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
	  content: content,
	  trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
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
      if response.actionIdentifier == NotificationAdapter.dismissIdentifier {
        try? setLastDismissedVersion(version: lastNotifiedVersion!)
        return
      }

      NSWorkspace.shared.open(appStoreLink)

      completionHandler()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
      UNUserNotificationCenter.current().delegate = self
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
      // Show the notification even when the app is in the foreground
    completionHandler([.badge, .banner, .sound])
  }
}


let lastDismissedVersionKey = "lastDismissedVersion"

func getLastDismissedVersion() -> SemanticVersion? {
  let versionString = UserDefaults.standard.string(forKey: lastDismissedVersionKey)
  guard let versionData = versionString?.data(using: .utf8) else {
    return nil
  }

  return try? JSONDecoder().decode(SemanticVersion.self, from: versionData)
}

func setLastDismissedVersion(version: SemanticVersion) throws {
  let encodedVersion = try JSONEncoder().encode(version)
  UserDefaults.standard.setValue(String(data: encodedVersion, encoding: .utf8), forKey: lastDismissedVersionKey)
}
#endif

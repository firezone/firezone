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

class UpdateChecker {
  enum UpdateError: Error {
    case invalidVersion(String)

    var localizedDescription: String {
      switch self {
      case .invalidVersion(let version):
        return "Invalid version: \(version)"
      }
    }
  }

  private var timer: Timer?
  private let notificationAdapter: NotificationAdapter = NotificationAdapter()
  private let versionCheckUrl: URL = URL(string: "https://www.firezone.dev/api/releases")!
  private let marketingVersion = SemVerString.from(string: Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String)!

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
        let task = URLSession.shared.dataTask(with: versionCheckUrl) { [weak self] data, response, error in
          guard let self = self else { return }

          if let error = error {
            Log.error(error)
            return
          }

          guard let versionInfo = VersionInfo.from(data: data)  else {
            let attemptedVersion = String(data: data ?? Data(), encoding: .utf8) ?? ""
            Log.error(UpdateError.invalidVersion(attemptedVersion))
            return
          }

          let latestVersion = versionInfo.apple

          if latestVersion > marketingVersion {
            self.updateAvailable = true

            if let lastDismissedVersion = getLastDismissedVersion(), lastDismissedVersion >= latestVersion {
              return
            }

            self.notificationAdapter.showUpdateNotification(version: latestVersion)
          }

        }

        task.resume()
    }

  static func downloadURL() -> URL {
    if BundleHelper.isAppStore() {
      return URL(string: "https://apps.apple.com/app/firezone/id6443661826")!
    }

    return URL(string: "https://www.firezone.dev/dl/firezone-client-macos/latest")!
  }
}

private class NotificationAdapter: NSObject, UNUserNotificationCenterDelegate {
  private var lastNotifiedVersion: SemVerString?
  private var lastDismissedVersion: SemVerString?
  static let notificationIdentifier = "UPDATE_CATEGORY"
  static let dismissIdentifier = "DISMISS_ACTION"

  override public init() {
    super.init()

    let notificationCenter = UNUserNotificationCenter.current()

    let dismissAction = UNNotificationAction(identifier: NotificationAdapter.dismissIdentifier,
                                             title: "Ignore Version",
                                             options: [])

    let notificationCategory = UNNotificationCategory(identifier: NotificationAdapter.notificationIdentifier,
                                                       actions: [dismissAction],
                                                       intentIdentifiers: [],
                                                       options: [])

    notificationCenter.setNotificationCategories([notificationCategory])

    notificationCenter.delegate = self
    notificationCenter.requestAuthorization(options: [.sound, .badge, .alert]) { _, error in
      if let error = error {
        Log.error(error)
      }
    }

  }


  func showUpdateNotification(version: SemVerString) {
    let content = UNMutableNotificationContent()
    lastNotifiedVersion = version
    content.title = "Update Firezone"
    content.body = "New version available"
    content.sound = .default
    content.categoryIdentifier = NotificationAdapter.notificationIdentifier


    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
	  content: content,
	  trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
	)

    UNUserNotificationCenter.current().add(request) { error in
      if let error = error {
        Log.error(error)
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

      NSWorkspace.shared.open(UpdateChecker.downloadURL())

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

private func setLastDismissedVersion(version: SemVerString) throws {
  guard let data = version.versionString().data(using: .utf8) else { return }
  UserDefaults.standard.setValue(String(data: data, encoding: .utf8), forKey: lastDismissedVersionKey)
}

private func getLastDismissedVersion() -> SemVerString? {
  guard let versionString = UserDefaults.standard.string(forKey: lastDismissedVersionKey) else { return nil }
  return SemVerString.from(string: versionString)
}


#endif

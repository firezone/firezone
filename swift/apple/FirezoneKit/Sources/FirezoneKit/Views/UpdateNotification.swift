//
//  UpdateNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//


import Foundation
import UserNotifications
import Cocoa

private class UpdateNotifier: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  @Published private(set) var decision: UNAuthorizationStatus
  private var lastNotifiedVersion: String?
  static let lastDismissedVersionKey = "lastDismissedVersion"
  static let notificationIdentifier = "UPDATE_CATEGORY"

  func getLastDismissedVersion() -> String? {
    return UserDefaults.standard.string(forKey: UpdateNotifier.lastDismissedVersionKey)
  }

  override public init() {
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

  public func updateNotification(version: String) {
    if getLastDismissedVersion() == version {
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
      } else {
        Log.app.debug("\(#function): Successfully requested notification")
      }
    }

  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
                              didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
      if response.actionIdentifier == "DISMISS_ACTION" {
        UserDefaults.standard.setValue(lastNotifiedVersion!, forKey: UpdateNotifier.lastDismissedVersionKey)
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

    init() {
        // Initialize the timer to call the checkForUpdates method every 60 seconds
        startCheckingForUpdates()
    }

    private func startCheckingForUpdates() {
        timer = Timer.scheduledTimer(timeInterval: 6 * 60 * 60, target: self, selector: #selector(checkForUpdates), userInfo: nil, repeats: true)
        checkForUpdates()
    }

    @objc private func checkForUpdates() {
      let marketingVersion = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
        guard let url = URL(string: "https://example.com/") else { return }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
          guard let self = self else { return }


          if let error = error {
            Log.app.error("Error fetching updates: \(error)")
            return
          }

          guard let data = data, let responseString = String(data: data, encoding: .utf8) else {
              Log.app.error("No data or failed to decode data")
              return
            }

            // Process the response data (e.g., check for updates)
          Log.app.error("Marketing version  \(marketingVersion)")
          self.updateNotifier.updateNotification(version: "1.3.6")

        }

        // Start the data task
        task.resume()
    }

    deinit {
        // Invalidate the timer when the object is deinitialized
        timer?.invalidate()
    }
}

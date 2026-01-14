//
//  UpdateNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Foundation
  import Combine
  import UserNotifications
  import Cocoa

  @MainActor
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

    private var timerCancellable: AnyCancellable?
    private let notificationAdapter: NotificationAdapter = NotificationAdapter()
    private let versionCheckUrl: URL
    private let marketingVersion: SemanticVersion
    private let configuration: Configuration

    private var cancellables: Set<AnyCancellable> = []

    @Published private(set) var updateAvailable: Bool = false

    init(configuration: Configuration? = nil) {
      self.configuration = configuration ?? Configuration.shared

      guard let versionCheckUrl = URL(string: "https://www.firezone.dev/api/releases"),
        let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        let marketingVersion = try? SemanticVersion(versionString)
      else {
        fatalError("Should be able to initialize the UpdateChecker")
      }

      self.versionCheckUrl = versionCheckUrl
      self.marketingVersion = marketingVersion
      startCheckingForUpdates()
    }

    private func startCheckingForUpdates() {
      guard timerCancellable == nil else { return }

      // Check immediately
      checkForUpdates()

      // Then check every 6 hours
      timerCancellable = Timer.publish(every: 6 * 60 * 60, on: .main, in: .default)
        .autoconnect()
        .sink { [weak self] _ in
          self?.checkForUpdates()
        }
    }

    private func checkForUpdates() {
      if configuration.disableUpdateCheck {
        return
      }

      let task = URLSession.shared.dataTask(with: versionCheckUrl) { [weak self] data, _, error in
        guard let self = self else { return }

        if let error = error as NSError?,
          error.domain == NSURLErrorDomain,
          [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
          ].contains(error.code)
        {  // Don't capture transient errors
          Log.warning("\(#function): Update check failed: \(error)")

          return
        } else if let error = error {
          Log.error(error)

          return
        }

        guard let data = data,
          let versions = try? JSONDecoder().decode([String: String].self, from: data),
          let versionString = versions["apple"],
          let latestVersion = try? SemanticVersion(versionString)
        else {
          Log.error(UpdateError.invalidVersion("data was invalid or 'apple' key not found"))

          return
        }

        if latestVersion > marketingVersion {
          Task {
            await MainActor.run {
              self.updateAvailable = true

              if let lastDismissedVersion = getLastDismissedVersion(),
                lastDismissedVersion >= latestVersion
              {
                return
              }

              self.notificationAdapter.showUpdateNotification(version: latestVersion)
            }
          }
        }
      }

      task.resume()
    }

    static func downloadURL() -> URL {
      // Static URL literal is guaranteed valid
      // swiftlint:disable:next force_unwrapping
      return URL(string: "https://www.firezone.dev/dl/firezone-client-macos/latest")!
    }
  }

  private class NotificationAdapter: NSObject, UNUserNotificationCenterDelegate {
    static let notificationIdentifier = "UPDATE_CATEGORY"
    static let dismissIdentifier = "DISMISS_ACTION"

    override public init() {
      super.init()

      let notificationCenter = UNUserNotificationCenter.current()

      let dismissAction = UNNotificationAction(
        identifier: NotificationAdapter.dismissIdentifier,
        title: "Ignore Version",
        options: [])

      let notificationCategory = UNNotificationCategory(
        identifier: NotificationAdapter.notificationIdentifier,
        actions: [dismissAction],
        intentIdentifiers: [],
        options: [])

      notificationCenter.setNotificationCategories([notificationCategory])

      notificationCenter.delegate = self
      notificationCenter.requestAuthorization(options: [.sound, .badge, .alert]) { _, error in
        guard let error = error else { return }

        // If the user hasn't enabled notifications for Firezone, we may receive
        // a notificationsNotAllowed error here. Don't log it.
        if let unError = error as? UNError,
          unError.code == .notificationsNotAllowed
        {
          return
        }

        // Log all other errors
        Log.error(error)
      }

    }

    @MainActor func showUpdateNotification(version: SemanticVersion) {
      let content = UNMutableNotificationContent()
      setLastNotifiedVersion(version: version)
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

    func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void
    ) {
      if response.actionIdentifier == NotificationAdapter.dismissIdentifier {
        // User dismissed this notification
        if let lastNotifiedVersion = getLastNotifiedVersion() {
          // Don't notify them again for this version
          setLastDismissedVersion(version: lastNotifiedVersion)
        }

        completionHandler()
        return
      }

      // Must be explicitly run from a MainActor context
      Task {
        await MainActor.run {
          Task {
            await NSWorkspace.shared.openAsync(UpdateChecker.downloadURL())
          }
        }
      }

      completionHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler:
        @escaping (
          UNNotificationPresentationOptions
        ) -> Void
    ) {
      // Show the notification even when the app is in the foreground
      completionHandler([.badge, .banner, .sound])
    }

  }

  private let lastDismissedVersionKey = "lastDismissedVersion"
  private let lastNotifiedVersionKey = "lastNotifiedVersion"

  private func setLastDismissedVersion(version: SemanticVersion) {
    setVersion(key: lastDismissedVersionKey, version: version)
  }

  private func setLastNotifiedVersion(version: SemanticVersion) {
    setVersion(key: lastNotifiedVersionKey, version: version)
  }

  private func getLastDismissedVersion() -> SemanticVersion? {
    loadVersion(key: lastDismissedVersionKey)
  }

  private func getLastNotifiedVersion() -> SemanticVersion? {
    loadVersion(key: lastNotifiedVersionKey)
  }

  func setVersion(key: String, version: SemanticVersion) {
    let encoder = PropertyListEncoder()

    do {
      let data = try encoder.encode(version)
      UserDefaults.standard.setValue(data, forKey: key)
    } catch {
      Log.error(error)
    }
  }

  func loadVersion(key: String) -> SemanticVersion? {
    let decoder = PropertyListDecoder()

    guard let data = UserDefaults.standard.object(forKey: lastDismissedVersionKey) as? Data
    else { return nil }

    do {
      let version = try decoder.decode(SemanticVersion.self, from: data)

      return version
    } catch {
      Log.error(error)

      return nil
    }
  }

#endif

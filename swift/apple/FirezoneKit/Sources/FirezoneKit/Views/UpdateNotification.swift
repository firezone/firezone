//
//  UpdateNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Foundation
  import Combine

  /// The one thing the UI needs from the update check.
  ///
  /// `UpdateChecker` reaches the network and installs a repeating timer, neither of which a
  /// test should be doing. Taking the check as a dependency lets a `Store` be built with a
  /// canned answer instead.
  @MainActor
  public protocol UpdateCheckerProtocol {
    var updateAvailable: Bool { get }
  }

  @MainActor
  class UpdateChecker: UpdateCheckerProtocol {
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
    private let sessionNotification: SessionNotificationProtocol
    private let versionCheckUrl: URL
    private let marketingVersion: SemanticVersion
    private let configuration: Configuration
    private let userDefaults: UserDefaults

    private var cancellables: Set<AnyCancellable> = []

    @Published private(set) var updateAvailable: Bool = false

    init(
      configuration: Configuration? = nil,
      userDefaults: UserDefaults,
      sessionNotification: SessionNotificationProtocol
    ) {
      self.configuration = configuration ?? Configuration.shared
      self.userDefaults = userDefaults
      self.sessionNotification = sessionNotification

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

              if let lastDismissedVersion = UpdateNotification.getLastDismissedVersion(
                userDefaults: self.userDefaults),
                lastDismissedVersion >= latestVersion
              {
                return
              }

              UpdateNotification.setLastNotifiedVersion(
                version: latestVersion, userDefaults: self.userDefaults)
              self.sessionNotification.showUpdateNotification()
            }
          }
        }
      }

      task.resume()
    }
  }

  /// What the update check, its notification and the menu bar's update item share.
  enum UpdateNotification {
    static let categoryIdentifier = "UPDATE_CATEGORY"
    static let dismissActionIdentifier = "DISMISS_ACTION"

    static func downloadURL() -> URL {
      // Static URL literal is guaranteed valid
      // swiftlint:disable:next force_unwrapping
      return URL(string: "https://www.firezone.dev/dl/firezone-client-macos/latest")!
    }

    private static let lastDismissedVersionKey = "lastDismissedVersion"
    private static let lastNotifiedVersionKey = "lastNotifiedVersion"

    static func setLastDismissedVersion(version: SemanticVersion, userDefaults: UserDefaults) {
      version.save(to: userDefaults, forKey: lastDismissedVersionKey)
    }

    static func setLastNotifiedVersion(version: SemanticVersion, userDefaults: UserDefaults) {
      version.save(to: userDefaults, forKey: lastNotifiedVersionKey)
    }

    static func getLastDismissedVersion(userDefaults: UserDefaults) -> SemanticVersion? {
      SemanticVersion(from: userDefaults, forKey: lastDismissedVersionKey)
    }

    static func getLastNotifiedVersion(userDefaults: UserDefaults) -> SemanticVersion? {
      SemanticVersion(from: userDefaults, forKey: lastNotifiedVersionKey)
    }
  }

#endif

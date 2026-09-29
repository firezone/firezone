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
    /// Where to download the newer version, `nil` while the client is up to date.
    var downloadURL: URL? { get }
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

    @Published private(set) var downloadURL: URL?

    init(
      configuration: Configuration? = nil,
      userDefaults: UserDefaults,
      sessionNotification: SessionNotificationProtocol
    ) {
      self.configuration = configuration ?? Configuration.shared
      self.userDefaults = userDefaults
      self.sessionNotification = sessionNotification

      guard let versionCheckUrl = URL(string: "https://www.firezone.dev/api/releases"),
        let versionString = UpdateNotification.isDebugUpdateCheck
          ? "1.0.0" : Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
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
              self.downloadURL = Self.latestReleaseURL()

              if let lastDismissedVersion = UpdateNotification.getLastDismissedVersion(
                userDefaults: self.userDefaults),
                lastDismissedVersion >= latestVersion
              {
                return
              }

              UpdateNotification.setLastNotifiedVersion(
                version: latestVersion, userDefaults: self.userDefaults)
              self.sessionNotification.showUpdateNotification(
                downloadURL: Self.latestReleaseURL())
            }
          }
        }
      }

      task.resume()
    }

    private static func latestReleaseURL() -> URL {
      // Static URL literal is guaranteed valid
      // swiftlint:disable:next force_unwrapping
      return URL(string: "https://www.firezone.dev/dl/firezone-client-macos/latest")!
    }
  }

  /// The update notification's identifiers, and the versions it and the update check keep in
  /// `UserDefaults`.
  enum UpdateNotification {
    static let categoryIdentifier = "UPDATE_CATEGORY"
    static let dismissActionIdentifier = "DISMISS_ACTION"
    static let downloadURLKey = "downloadURL"

    /// Set by the `--debug-update-check` launch argument, for testing the notification by hand:
    /// the running version counts as 1.0.0 and a dismissed version is neither read nor saved.
    static let isDebugUpdateCheck = CommandLine.arguments.contains("--debug-update-check")

    private static let lastDismissedVersionKey = "lastDismissedVersion"
    private static let lastNotifiedVersionKey = "lastNotifiedVersion"

    static func setLastDismissedVersion(version: SemanticVersion, userDefaults: UserDefaults) {
      guard !isDebugUpdateCheck else { return }

      version.save(to: userDefaults, forKey: lastDismissedVersionKey)
    }

    static func setLastNotifiedVersion(version: SemanticVersion, userDefaults: UserDefaults) {
      version.save(to: userDefaults, forKey: lastNotifiedVersionKey)
    }

    static func getLastDismissedVersion(userDefaults: UserDefaults) -> SemanticVersion? {
      guard !isDebugUpdateCheck else { return nil }

      return SemanticVersion(from: userDefaults, forKey: lastDismissedVersionKey)
    }

    static func getLastNotifiedVersion(userDefaults: UserDefaults) -> SemanticVersion? {
      SemanticVersion(from: userDefaults, forKey: lastNotifiedVersionKey)
    }
  }

#endif

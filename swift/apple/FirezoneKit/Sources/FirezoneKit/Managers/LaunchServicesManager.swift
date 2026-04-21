#if os(macOS)
  import Foundation
  import ServiceManagement
  import Sentry

  extension SMAppService.Status {
    var isRegistered: Bool {
      switch self {
      case .enabled, .requiresApproval:
        return true
      case .notRegistered, .notFound:
        return false
      @unknown default:
        return false
      }
    }
  }

  enum LaunchServicesManager {
    private static var keepAppRunningService: SMAppService {
      let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.firezone.firezone"
      return SMAppService.agent(plistName: "\(bundleIdentifier).keep-app-running.plist")
    }

    static func sync(forceReregistration: Bool = false) async throws {
      // Getting these statuses appears to be blocking sometimes.
      SentrySDK.pauseAppHangTracking()
      defer { SentrySDK.resumeAppHangTracking() }

      try await syncKeepAppRunningService(
        status: keepAppRunningService.status,
        forceReregistration: forceReregistration
      )
    }

    private static func syncKeepAppRunningService(
      status: SMAppService.Status,
      forceReregistration: Bool
    ) async throws {
      guard !forceReregistration || status != .enabled else {
        try await keepAppRunningService.unregister()
        try keepAppRunningService.register()
        return
      }

      guard !status.isRegistered else {
        return
      }

      try keepAppRunningService.register()
    }
  }
#endif

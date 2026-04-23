import Foundation

#if os(macOS)
  import Sentry
  import ServiceManagement
#endif

enum LaunchAgentManager {
  static func syncKeepAppRunning() async throws {
    #if os(macOS)
      // Getting these statuses appears to be blocking sometimes.
      SentrySDK.pauseAppHangTracking()
      defer { SentrySDK.resumeAppHangTracking() }

      if keepAppRunningService.status.isRegistered {
        return
      }

      try keepAppRunningService.register()
    #endif
  }
}

#if os(macOS)
  private var keepAppRunningService: SMAppService {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.firezone.firezone"
    return SMAppService.agent(plistName: "\(bundleIdentifier).keep-app-running.plist")
  }

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
#endif

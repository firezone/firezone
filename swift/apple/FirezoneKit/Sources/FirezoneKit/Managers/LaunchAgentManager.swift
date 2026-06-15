import Foundation

#if os(macOS)
  import ServiceManagement
#endif

enum LaunchAgentManager {
  static func syncKeepAppRunning() async throws {
    #if os(macOS)
      // `SMAppService.status` and `register()` block on a synchronous XPC round-trip
      // to `smd`. With approachable concurrency, `nonisolated async` functions run on
      // the caller's executor (the MainActor), so hop onto a detached task to keep the
      // blocking work off the main thread and avoid freezing the UI.
      let isRegistered = await Task.detached(priority: .userInitiated) {
        keepAppRunningService().status.isRegistered
      }.value

      if isRegistered {
        return
      }

      try await Task.detached(priority: .userInitiated) {
        try keepAppRunningService().register()
      }.value
    #endif
  }
}

#if os(macOS)
  private func keepAppRunningService() -> SMAppService {
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

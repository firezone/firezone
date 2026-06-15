import Foundation

#if os(macOS)
  import ServiceManagement
#endif

enum LoginItemManager {
  static func syncStartOnLogin(startOnLogin: Bool) async throws {
    #if os(macOS)
      // `SMAppService.status` and `register()` perform a synchronous XPC round-trip
      // to `smd` that can block the caller for seconds. With approachable concurrency,
      // `nonisolated async` functions run on the caller's executor — here the
      // MainActor — so run the whole check-and-update on a single detached task to
      // keep the blocking work off the main thread. Otherwise the UI freezes and
      // Sentry records an App Hang.
      try await Task.detached(priority: .userInitiated) {
        let service = SMAppService.mainApp
        let isRegistered = service.status.isRegistered

        if !startOnLogin, isRegistered {
          try await service.unregister()
        } else if startOnLogin, !isRegistered {
          try service.register()
        }
      }.value
    #endif
  }
}

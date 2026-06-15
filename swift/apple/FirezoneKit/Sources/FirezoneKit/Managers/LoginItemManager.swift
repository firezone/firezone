import Foundation

#if os(macOS)
  import ServiceManagement
#endif

enum LoginItemManager {
  static func syncStartOnLogin(startOnLogin: Bool) async throws {
    #if os(macOS)
      // `SMAppService.status` and `register()` perform a synchronous XPC round-trip
      // to `smd` that can block the calling thread for seconds. With approachable
      // concurrency, `nonisolated async` functions run on the caller's executor —
      // here the MainActor — so we hop onto a detached task to keep the blocking
      // work off the main thread. Otherwise the UI freezes and Sentry records an
      // App Hang. `unregister()` is already async and does not block the caller.
      let status = await Task.detached(priority: .userInitiated) {
        SMAppService.mainApp.status
      }.value

      if !startOnLogin, status == .enabled {
        try await SMAppService.mainApp.unregister()
        return
      }

      if startOnLogin, status != .enabled {
        try await Task.detached(priority: .userInitiated) {
          try SMAppService.mainApp.register()
        }.value
      }
    #endif
  }
}

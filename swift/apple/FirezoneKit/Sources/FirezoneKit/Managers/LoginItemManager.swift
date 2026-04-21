import Foundation

#if os(macOS)
  import Sentry
  import ServiceManagement
#endif

enum LoginItemManager {
  static func sync(startOnLogin: Bool) async throws {
    #if os(macOS)
      SentrySDK.pauseAppHangTracking()
      defer { SentrySDK.resumeAppHangTracking() }
      let status = SMAppService.mainApp.status

      if !startOnLogin, status == .enabled {
        try await SMAppService.mainApp.unregister()
        return
      }

      if startOnLogin, status != .enabled {
        try SMAppService.mainApp.register()
      }
    #endif
  }
}

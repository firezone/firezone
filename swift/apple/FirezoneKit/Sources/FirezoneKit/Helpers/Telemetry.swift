//
//  Telemetry.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Sentry

public enum Telemetry {
  /// Sets the Sentry user from the firezone device ID and account slug.
  public static func setUser(firezoneId: String, accountSlug: String) {
    SentrySDK.configureScope { scope in
      let user = User(userId: firezoneId)
      user.data = ["account_slug": accountSlug]
      scope.setUser(user)
    }
  }

  public static func start(enableAppHangTracking: Bool = true) {
    SentrySDK.start { options in
      options.dsn =
        "https://66c71f83675f01abfffa8eb977bcbbf7@o4507971108339712.ingest.us.sentry.io/4508175177023488"
      options.environment = "entrypoint"  // will be reconfigured in VPNConfigurationManager
      options.releaseName = releaseName()
      options.dist = distributionType()
      options.enableAppHangTracking = enableAppHangTracking
    }
  }

  public static func setEnvironmentOrClose(_ apiURL: String) {
    var environment: String?

    if apiURL.starts(with: "wss://api.firezone.dev") {
      environment = "production"
    } else if apiURL.starts(with: "wss://api.firez.one") {
      environment = "staging"
    }

    guard let environment
    else {
      // Disable Sentry in unknown environments
      SentrySDK.close()

      return
    }

    SentrySDK.configureScope { configuration in
      configuration.setEnvironment(environment)
    }
  }

  public static func capture(_ err: Error) {
    SentrySDK.capture(error: err)
  }

  private static func distributionType() -> String {
    // Apps from the app store have a receipt file
    if BundleHelper.isAppStore() {
      return "appstore"
    }

    return "standalone"
  }

  private static func releaseName() -> String {
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"]
      as? String ?? "unknown"

    #if os(iOS)
      return "ios-client@\(version)"
    #else
      return "macos-client@\(version)"
    #endif
  }
}

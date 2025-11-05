//
//  Telemetry.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Sentry

/// Actor that manages telemetry state with thread-safe access.
actor TelemetryState {
  private var firezoneId: String?
  private var accountSlug: String?

  func setFirezoneId(_ id: String?) {
    firezoneId = id
    updateUser()
  }

  func setAccountSlug(_ slug: String?) {
    accountSlug = slug
    updateUser()
  }

  private func updateUser() {
    guard let firezoneId, let accountSlug else {
      return
    }

    SentrySDK.configureScope { configuration in
      // Matches the format we use in rust/telemetry/lib.rs
      let user = User(userId: firezoneId)
      user.data = ["account_slug": accountSlug]

      configuration.setUser(user)
    }
  }
}

public enum Telemetry {
  // We can only create a new User object after Sentry is started; not retrieve
  // the existing one. So we need to collect these fields from various codepaths
  // during initialization / sign in so we can build a new User object any time
  // one of these is updated.

  private static let state = TelemetryState()

  public static func setFirezoneId(_ id: String?) async {
    await state.setFirezoneId(id)
  }

  public static func setAccountSlug(_ slug: String?) async {
    await state.setAccountSlug(slug)
  }

  public static func start() {
    SentrySDK.start { options in
      options.dsn =
        "https://66c71f83675f01abfffa8eb977bcbbf7@o4507971108339712.ingest.us.sentry.io/4508175177023488"
      options.environment = "entrypoint"  // will be reconfigured in VPNConfigurationManager
      options.releaseName = releaseName()
      options.dist = distributionType()
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

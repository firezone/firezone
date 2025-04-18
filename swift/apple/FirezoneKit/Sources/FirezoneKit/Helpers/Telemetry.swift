//
//  Telemetry.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Sentry

public enum Telemetry {
  // We can only create a new User object after Sentry is started; not retrieve
  // the existing one. So we need to collect these fields from various codepaths
  // during initialization / sign in so we can build a new User object any time
  // one of these is updated.
  private static var _firezoneId: String?
  private static var _accountSlug: String?
  public static var firezoneId: String? {
    get {
      return self._firezoneId
    }
    set {
      self._firezoneId = newValue
      updateUser(id: self._firezoneId, slug: self._accountSlug)
    }
  }
  public static var accountSlug: String? {
    get {
      return self._accountSlug
    }
    set {
      self._accountSlug = newValue
      updateUser(id: self._firezoneId, slug: self._accountSlug)
    }
  }

  public static func start() {
    SentrySDK.start { options in
      options.dsn = "https://66c71f83675f01abfffa8eb977bcbbf7@o4507971108339712.ingest.us.sentry.io/4508175177023488"
      options.environment = "entrypoint" // will be reconfigured in VPNConfigurationManager
      options.releaseName = releaseName()
      options.dist = distributionType()
    }
  }

  public static func setEnvironmentOrClose(_ apiURLString: String) {
    var environment: String?

    if apiURLString.starts(with: "wss://api.firezone.dev") {
      environment = "production"
    } else if apiURLString.starts(with: "wss://api.firez.one") {
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

  private static func updateUser(id: String?, slug: String?) {
    guard let id,
          let slug
    else {
      return
    }

    SentrySDK.configureScope { configuration in
      // Matches the format we use in rust/telemetry/lib.rs
      let user = User(userId: id)
      user.data = ["account_slug": slug]

      configuration.setUser(user)
    }
  }

  private static func distributionType() -> String {
    // Apps from the app store have a receipt file
    if BundleHelper.isAppStore() {
      return "appstore"
    }

    return "standalone"
  }

  private static func releaseName() -> String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
    as? String ?? "unknown"

#if os(iOS)
    return "ios-client@\(version)"
#else
    return "macos-client@\(version)"
#endif
  }
}

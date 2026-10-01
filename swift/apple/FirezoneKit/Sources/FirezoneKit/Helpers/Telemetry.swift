//
//  Telemetry.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Sentry

public enum Telemetry {
  /// Sets the Sentry user on both the scope (for error events) and log attributes.
  public static func setUser(firezoneId: String, accountSlug: String) {
    Log.info("Configuring Sentry user: firezone_id=\(firezoneId), account_slug=\(accountSlug)")
    Log.setUser(firezoneId: firezoneId, accountSlug: accountSlug)
    SentrySDK.configureScope { scope in
      let user = User(userId: firezoneId)
      user.data = ["account_slug": accountSlug]
      scope.setUser(user)
    }
  }

  public static func start(enableAppHangTracking: Bool = true) {
    guard !BundleHelper.noTelemetry else {
      Log.info("Telemetry is switched off for this build")

      return
    }

    SentrySDK.start { options in
      options.dsn =
        "https://66c71f83675f01abfffa8eb977bcbbf7@o4507971108339712.ingest.us.sentry.io/4508175177023488"
      options.environment = "entrypoint"  // will be reconfigured in VPNConfigurationManager
      options.releaseName = releaseName()
      options.dist = distributionType()
      options.enableAppHangTracking = enableAppHangTracking
      options.enableMetricKit = true
      options.enableLogs = true
      options.beforeSend = { event in
        retitleWithLocalizedDescription(event)

        return event
      }
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

    Log.setEnvironment(environment)
    SentrySDK.configureScope { configuration in
      configuration.setEnvironment(environment)
    }
  }

  // These events carry no stack trace, so they are grouped by fingerprint: the error's domain,
  // code and call site. Localized text would split one fault per locale.
  public static func capture(
    _ err: Error,
    fileID: String = #fileID,
    function: String = #function
  ) {
    let error = reportableError(err)
    let fingerprint = [error.domain, String(error.code), fileID, function]

    SentrySDK.capture(error: error) { scope in
      scope.setFingerprint(fingerprint)
    }
  }

  private static func reportableError(_ err: Error) -> NSError {
    let error = err as NSError

    guard let description = fallbackDescription(of: err) else { return error }

    var userInfo = error.userInfo
    userInfo[NSLocalizedDescriptionKey] = description

    return NSError(domain: error.domain, code: error.code, userInfo: userInfo)
  }

  /// Returns the type and case of a Swift error that has no description of its own.
  ///
  /// Such an error bridges to "The operation couldn't be completed", which says nothing.
  /// Associated values are left out because they can carry file paths or tokens.
  static func fallbackDescription(of err: Error) -> String? {
    let typeName = String(reflecting: type(of: err))
    let error = err as NSError

    // Swift names the domain after the type unless the error picks its own, as Apple's do.
    guard (err as? LocalizedError)?.errorDescription == nil,
      error.userInfo[NSLocalizedDescriptionKey] == nil,
      error.domain == typeName
    else { return nil }

    let name = typeName.split(separator: ".", maxSplits: 1).last.map(String.init) ?? typeName
    let mirror = Mirror(reflecting: err)

    guard mirror.displayStyle == .enum else { return name }

    if let caseName = mirror.children.first?.label {
      return "\(name).\(caseName)"
    }

    guard !(err is CustomStringConvertible), !(err is CustomDebugStringConvertible)
    else { return name }

    return "\(name).\(err)"
  }

  private static func retitleWithLocalizedDescription(_ event: Event) {
    guard let error = event.error as NSError?,
      let exception = event.exceptions?.last
    else { return }

    event.fingerprint = event.fingerprint ?? [error.domain, String(error.code)]

    let description = error.localizedDescription

    guard !description.isEmpty else { return }

    exception.value = description
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

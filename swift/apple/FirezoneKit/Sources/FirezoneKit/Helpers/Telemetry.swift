//
//  Telemetry.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Sentry

public enum Telemetry {
  public static func start() {
    SentrySDK.start { options in

      // Different Sentry projects for macOS and iOS
#if os(macOS)
      options.dsn = "https://5420feea6f18a799f28a34f30cdcd555@o4507971108339712.ingest.us.sentry.io/4508564061224960"
#elseif os(iOS)
      options.dsn = "https://617b332660d27526eb96e39571b62f27@o4507971108339712.ingest.us.sentry.io/4508564070989824"
#endif

      options.releaseName = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
      options.environment = "entrypoint" // will be reconfigured in TunnelManager

#if DEBUG
      options.debug = true
#endif
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
}

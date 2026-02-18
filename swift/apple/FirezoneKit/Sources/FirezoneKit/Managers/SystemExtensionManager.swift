//
//  SystemExtensionManager.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import SystemExtensions

  enum SystemExtensionError: Error {
    case unknownResult(OSSystemExtensionRequest.Result)

    var description: String {
      switch self {
      case .unknownResult(let result):
        return "Unknown result: \(result)"
      }
    }
  }

  public enum SystemExtensionStatus: Equatable, Sendable {
    // Not installed or enabled at all
    case needsInstall

    // Version of the extension is installed that differs from our bundle version.
    // "Installing" it will replace it without prompting the user.
    case needsReplacement

    // Installed and version is current with our app bundle
    case installed

    /// Determines extension status by comparing installed extensions against the app version.
    static func fromInstalledExtensions(
      _ extensions: [(bundleVersion: String, bundleShortVersion: String)],
      appBundleVersion: String,
      appBundleShortVersion: String
    ) -> SystemExtensionStatus {
      let isCurrentVersionInstalled = extensions.contains { ext in
        ext.bundleVersion == appBundleVersion
          && ext.bundleShortVersion == appBundleShortVersion
      }
      if isCurrentVersionInstalled {
        return .installed
      }

      if extensions.first != nil {
        return .needsReplacement
      }

      return .needsInstall
    }
  }

  @MainActor
  public protocol SystemExtensionManagerProtocol: Sendable {
    func check() async throws -> SystemExtensionStatus
    func tryInstall() async throws -> SystemExtensionStatus
  }

  enum SystemExtensionRequestType {
    case install
    case check
  }

  @MainActor
  class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate, ObservableObject,
    SystemExtensionManagerProtocol
  {
    // Delegate methods complete with either a true or false outcome or an Error
    private var continuation: CheckedContinuation<SystemExtensionStatus, Error>?

    // MARK: - OSSystemExtensionRequestDelegate

    // Delegate callbacks are non-async and nonisolated.
    // Use Task { @MainActor in } to safely hop to our actor.

    nonisolated func request(
      _ request: OSSystemExtensionRequest,
      didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
      Task { @MainActor in
        guard result == .completed else {
          self.resumeErr(throwing: SystemExtensionError.unknownResult(result))
          return
        }
        self.resumeOk(returning: .installed)
      }
    }

    nonisolated func request(
      _ request: OSSystemExtensionRequest,
      foundProperties properties: [OSSystemExtensionProperties]
    ) {
      // Standard keys in any bundle. If missing, we've got bigger issues.
      guard
        let ourBundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
          as? String,
        let ourBundleShortVersion = Bundle.main.object(
          forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      else {
        fatalError("Version should exist in bundle")
      }

      let enabledExtensions =
        properties
        .filter { $0.isEnabled }
        .map { (bundleVersion: $0.bundleVersion, bundleShortVersion: $0.bundleShortVersion) }

      Task { @MainActor in
        Log.info(
          "Checking system extension - Client version: \(ourBundleShortVersion) (\(ourBundleVersion))"
        )

        for sysex in enabledExtensions {
          Log.info(
            "Found enabled extension - Version: \(sysex.bundleShortVersion) (\(sysex.bundleVersion))"
          )
        }

        let status = SystemExtensionStatus.fromInstalledExtensions(
          enabledExtensions,
          appBundleVersion: ourBundleVersion,
          appBundleShortVersion: ourBundleShortVersion
        )

        if case .needsReplacement = status, let ext = enabledExtensions.first {
          Log.warning(
            "Extension version mismatch - Installed: \(ext.bundleShortVersion) (\(ext.bundleVersion)), Expected: \(ourBundleShortVersion) (\(ourBundleVersion))"
          )
        } else if case .needsInstall = status {
          Log.info("No system extension found - needs install")
        }

        self.resumeOk(returning: status)
      }
    }

    nonisolated func request(
      _ request: OSSystemExtensionRequest,
      didFailWithError error: Error
    ) {
      Task { @MainActor in
        self.resumeErr(throwing: error)
      }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
      // We assume this state until we receive a success response.
    }

    nonisolated func request(
      _ request: OSSystemExtensionRequest,
      actionForReplacingExtension existing: OSSystemExtensionProperties,
      withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
      return .replace
    }

    // MARK: - SystemExtensionManagerProtocol

    func check() async throws -> SystemExtensionStatus {
      try await withCheckedThrowingContinuation { continuation in
        sendRequest(
          requestType: .check,
          identifier: VPNConfigurationManager.bundleIdentifier,
          continuation: continuation
        )
      }
    }

    func tryInstall() async throws -> SystemExtensionStatus {
      try await withCheckedThrowingContinuation { continuation in
        sendRequest(
          requestType: .install,
          identifier: VPNConfigurationManager.bundleIdentifier,
          continuation: continuation
        )
      }
    }

    private func sendRequest(
      requestType: SystemExtensionRequestType,
      identifier: String,
      continuation: CheckedContinuation<SystemExtensionStatus, Error>
    ) {
      self.continuation = continuation

      let request =
        switch requestType {
        case .install:
          OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier, queue: .main)
        case .check:
          OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: identifier,
            queue: .main
          )
        }

      request.delegate = self

      OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func resumeErr(throwing error: Error) {
      self.continuation?.resume(throwing: error)
      self.continuation = nil
    }

    private func resumeOk(returning val: SystemExtensionStatus) {
      self.continuation?.resume(returning: val)
      self.continuation = nil
    }
  }
#endif

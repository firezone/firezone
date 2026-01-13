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

  public enum SystemExtensionStatus: Sendable {
    // Not installed or enabled at all
    case needsInstall

    // Version of the extension is installed that differs from our bundle version.
    // "Installing" it will replace it without prompting the user.
    case needsReplacement

    // Installed and version is current with our app bundle
    case installed
  }

  enum SystemExtensionRequestType {
    case install
    case check
  }

  public class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate, ObservableObject,
    SystemExtensionManagerProtocol, @unchecked Sendable
  {
    // Delegate methods complete with either a true or false outcome or an Error
    private var continuation: CheckedContinuation<SystemExtensionStatus, Error>?

    override public init() {
      super.init()
    }

    // MARK: - SystemExtensionManagerProtocol

    public func checkStatus() async throws -> SystemExtensionStatus {
      try await withCheckedThrowingContinuation { continuation in
        sendRequest(
          requestType: .check,
          identifier: VPNConfigurationManager.bundleIdentifier,
          continuation: continuation
        )
      }
    }

    public func install() async throws -> SystemExtensionStatus {
      try await withCheckedThrowingContinuation { continuation in
        sendRequest(
          requestType: .install,
          identifier: VPNConfigurationManager.bundleIdentifier,
          continuation: continuation
        )
      }
    }

    // MARK: - Internal

    func sendRequest(
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

    // MARK: - OSSystemExtensionRequestDelegate

    // Result of system extension installation
    public func request(
      _ request: OSSystemExtensionRequest,
      didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
      guard result == .completed else {
        resume(throwing: SystemExtensionError.unknownResult(result))

        return
      }

      // Installation succeeded
      resume(returning: .installed)
    }

    // Result of properties request
    public func request(
      _ request: OSSystemExtensionRequest,
      foundProperties properties: [OSSystemExtensionProperties]
    ) {
      // Standard keys in any bundle. If missing, we've got bigger issues.
      // In test environment, Bundle.main may not have version info
      let ourBundleVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
        as? String ?? "0"
      let ourBundleShortVersion =
        Bundle.main.object(
          forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

      Log.info(
        "Checking system extension - Client version: \(ourBundleShortVersion) (\(ourBundleVersion))"
      )

      // Log all found extensions for debugging
      for sysex in properties where sysex.isEnabled {
        Log.info(
          "Found enabled extension - Version: \(sysex.bundleShortVersion) (\(sysex.bundleVersion))"
        )
      }

      // Up to date if version and build number match
      let isCurrentVersionInstalled = properties.contains { sysex in
        sysex.isEnabled
          && sysex.bundleVersion == ourBundleVersion
          && sysex.bundleShortVersion == ourBundleShortVersion
      }
      if isCurrentVersionInstalled {
        resume(returning: .installed)

        return
      }

      // Needs replacement if we found our extension, but its version doesn't match
      // Note this can happen for upgrades _or_ downgrades
      let enabledExtension = properties.first { $0.isEnabled }
      if let enabledExtension = enabledExtension {
        Log.warning(
          "Extension version mismatch - Installed: \(enabledExtension.bundleShortVersion) (\(enabledExtension.bundleVersion)), Expected: \(ourBundleShortVersion) (\(ourBundleVersion))"
        )
        resume(returning: .needsReplacement)

        return
      }

      Log.info("No system extension found - needs install")
      resume(returning: .needsInstall)
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
      resume(throwing: error)
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
      // We assume this state until we receive a success response.
    }

    public func request(
      _ request: OSSystemExtensionRequest,
      actionForReplacingExtension existing: OSSystemExtensionProperties,
      withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
      return .replace
    }

    private func resume(throwing error: Error) {
      self.continuation?.resume(throwing: error)
      self.continuation = nil
    }

    private func resume(returning val: SystemExtensionStatus) {
      self.continuation?.resume(returning: val)
      self.continuation = nil
    }
  }
#endif

//
//  SystemExtensionManager.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import NetworkExtension
  import SystemExtensions

  enum SystemExtensionError: Error, CustomStringConvertible, LocalizedError {
    case unknownResult(OSSystemExtensionRequest.Result)

    var description: String {
      switch self {
      case .unknownResult(let result):
        return "Unknown result: \(result)"
      }
    }

    var errorDescription: String? { description }
  }

  public enum SystemExtensionStatus: Equatable, Sendable {
    // Not installed or enabled at all
    case needsInstall

    // Version of the extension is installed that differs from our bundle version.
    // "Installing" it will replace it without prompting the user.
    case needsReplacement

    // Installed and version is current with our app bundle
    case installed

    // The replacement is staged, but macOS could not swap the extension it is
    // replacing, so the previous version keeps running until the Mac restarts.
    // Only an install request reports this; a properties request cannot see it.
    case needsReboot

    /// Whether the extension the system has can serve the app right now.
    ///
    /// A staged replacement leaves the previous version installed and running, so the app
    /// works. It just isn't the version we shipped with, and only a restart changes that.
    var isUsable: Bool {
      self == .installed || self == .needsReboot
    }

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

  /// Stands in for the manager in a build whose provider is bundled as an app
  /// extension.
  ///
  /// Such a provider ships inside the app and needs no install, no approval and no
  /// version comparison, so there is nothing for the user to do and nothing that can
  /// go stale. Reporting it installed is what leaves the rest of the app, which is
  /// written against a system extension, with nothing to ask for.
  @MainActor
  public struct BundledExtensionManager: SystemExtensionManagerProtocol {
    public init() {}

    public func check() async throws -> SystemExtensionStatus { .installed }
    public func tryInstall() async throws -> SystemExtensionStatus { .installed }
  }

  enum SystemExtensionRequestType {
    case install
    case check
  }

  @MainActor
  public class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate, ObservableObject,
    SystemExtensionManagerProtocol
  {
    // Delegate methods complete with either a true or false outcome or an Error
    private var continuation: CheckedContinuation<SystemExtensionStatus, Error>?

    override public init() {
      super.init()
    }

    // MARK: - OSSystemExtensionRequestDelegate

    // Delegate callbacks are non-async and nonisolated.
    // Use Task { @MainActor in } to safely hop to our actor.

    nonisolated public func request(
      _ request: OSSystemExtensionRequest,
      didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
      Task { @MainActor in
        switch result {
        case .completed:
          self.resumeOk(returning: .installed)
        case .willCompleteAfterReboot:
          Log.info("System extension replacement is staged until the next restart")
          self.resumeOk(returning: .needsReboot)
        @unknown default:
          self.resumeErr(throwing: SystemExtensionError.unknownResult(result))
        }
      }
    }

    nonisolated public func request(
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

    nonisolated public func request(
      _ request: OSSystemExtensionRequest,
      didFailWithError error: Error
    ) {
      Task { @MainActor in
        self.resumeErr(throwing: error)
      }
    }

    nonisolated public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
      // We assume this state until we receive a success response.
    }

    nonisolated public func request(
      _ request: OSSystemExtensionRequest,
      actionForReplacingExtension existing: OSSystemExtensionProperties,
      withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
      return .replace
    }

    // MARK: - SystemExtensionManagerProtocol

    public func check() async throws -> SystemExtensionStatus {
      try await withCheckedThrowingContinuation { continuation in
        sendRequest(
          requestType: .check,
          identifier: NETunnelProviderManager.extensionBundleIdentifier,
          continuation: continuation
        )
      }
    }

    public func tryInstall() async throws -> SystemExtensionStatus {
      try await withCheckedThrowingContinuation { continuation in
        sendRequest(
          requestType: .install,
          identifier: NETunnelProviderManager.extensionBundleIdentifier,
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

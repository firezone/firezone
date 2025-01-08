//
//  SystemExtensionManager.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
import SystemExtensions

public enum SystemExtensionError: Error {
  case unknownResult(OSSystemExtensionRequest.Result)

  var description: String {
    switch self {
    case .unknownResult(let result):
      return "Unknown result: \(result)"
    }
  }
}

public class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate, ObservableObject {
  // Delegate methods complete with either a true or false outcome or an Error
  private var continuation: CheckedContinuation<Bool, Error>?

  public func installSystemExtension(
    identifier: String,
    continuation: CheckedContinuation<Bool, Error>
  ) {
    self.continuation = continuation

    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
    request.delegate = self

    // Install extension
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  public func isInstalled(
    identifier: String,
    continuation: CheckedContinuation<Bool, Error>
  ) {
    self.continuation = continuation

    let request = OSSystemExtensionRequest.propertiesRequest(
      forExtensionWithIdentifier: identifier,
      queue: .main
    )
    request.delegate = self

    // Send request
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  // MARK: - OSSystemExtensionRequestDelegate

  // Result of system extension installation
  public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    guard result == .completed else {
      resume(throwing: SystemExtensionError.unknownResult(result))

      return
    }

    // Installation succeeded
    resume(returning: true)
  }

  // Result of properties request
  public func request(
    _ request: OSSystemExtensionRequest,
    foundProperties properties: [OSSystemExtensionProperties]
  ) {
    // Returns true if we find any extension installed matching the bundle id
    // Otherwise false
    continuation?.resume(returning: properties.contains { $0.isEnabled })
  }

  public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    resume(throwing: error)
  }

  public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    // We assume this state until we receive a success response.
  }

  public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
    return .replace
  }

  private func resume(throwing error: Error) {
    self.continuation?.resume(throwing: error)
    self.continuation = nil
  }

  private func resume(returning val: Bool) {
    self.continuation?.resume(returning: val)
    self.continuation = nil
  }
}
#endif

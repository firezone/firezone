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
  // Maintain a static handle to the extension manager for tracking the state of the extension activation.
  public static let shared = SystemExtensionManager()

  private var continuation: CheckedContinuation<Void, Error>?

  public func installSystemExtension(
    identifier: String,
    continuation: CheckedContinuation<Void, Error>
  ) {
    self.continuation = continuation

    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
    request.delegate = self

    // Install extension
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  // MARK: - OSSystemExtensionRequestDelegate

  public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    guard result == .completed else {
      consumeContinuation(throwing: SystemExtensionError.unknownResult(result))

      return
    }

    // Success
    consumeContinuation()
  }

  public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    consumeContinuation(throwing: error)
  }

  public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    // We assume this state until we receive a success response.
  }

  public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
    return .replace
  }

  private func consumeContinuation(throwing error: Error) {
    self.continuation?.resume(throwing: error)
    self.continuation = nil
  }

  private func consumeContinuation() {
    self.continuation?.resume()
    self.continuation = nil
  }
}
#endif

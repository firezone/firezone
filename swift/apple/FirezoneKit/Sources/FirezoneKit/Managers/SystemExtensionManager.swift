//
//  SystemExtensionManager.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
import SystemExtensions

public enum SystemExtensionError: Error {
  case unknownResult(OSSystemExtensionRequest.Result)
  case needsUserApproval

  var description: String {
    switch self {
    case .unknownResult(let result):
      return "Unknown result: \(result)"
    case .needsUserApproval:
      return "Needs user approval"
    }
  }
}

public class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate, ObservableObject {
  // Maintain a static handle to the extension manager for tracking the state of the extension activation.
  public static let shared = SystemExtensionManager()

  private var completionHandler: ((Error?) -> Void)?

  public func installSystemExtension(
    identifier: String,
    completionHandler: @escaping (Error?) -> Void
  ) {
    self.completionHandler = completionHandler

    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
    request.delegate = self

    // Install extension
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  // MARK: - OSSystemExtensionRequestDelegate

  public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    guard result == .completed else {
      completionHandler?(SystemExtensionError.unknownResult(result))

      return
    }

    // Success
    completionHandler?(nil)
  }

  public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    completionHandler?(error)
  }

  public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    completionHandler?(SystemExtensionError.needsUserApproval)
  }

  public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
    return .replace
  }
}
#endif

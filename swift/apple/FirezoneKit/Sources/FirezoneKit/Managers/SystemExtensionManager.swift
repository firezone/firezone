//
//  SystemExtensionManager.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
import SystemExtensions

enum SystemExtensionError: Error {
  case UnexpectedResult(result: OSSystemExtensionRequest.Result)
  case NeedsUserApproval
}

public class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
  private var completionHandler: ((Error?) -> Void)?

  public func installSystemExtension(
    identifier: String?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let identifier = identifier else { return }
    self.completionHandler = completionHandler

    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
    request.delegate = self

    // Install extension
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  // MARK: - OSSystemExtensionRequestDelegate

  public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    guard result == .completed else {
      completionHandler?(SystemExtensionError.UnexpectedResult(result: result))

      return
    }

    // Success
    completionHandler?(nil)
  }

  public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    completionHandler?(error)
  }

  public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    completionHandler?(SystemExtensionError.NeedsUserApproval)

    // TODO: Inform the user to approve the system extension in System Preferences > Security & Privacy.
  }

  public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
    return .replace
  }
}
#endif

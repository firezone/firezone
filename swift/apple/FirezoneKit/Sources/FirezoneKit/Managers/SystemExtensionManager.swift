//
//  SystemExtensionManager.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
import SystemExtensions

public class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate, ObservableObject {
  // Maintain a static handle to the extension manager for tracking the state of the extension activation.
  public static let shared = SystemExtensionManager()

  @Published public var status: ExtensionStatus = .unknown

  public enum ExtensionStatus {
    case awaitingUserApproval
    case installed
    case unknown
  }

  public func installSystemExtension(identifier: String) {

    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
    request.delegate = self

    // Install extension
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  // MARK: - OSSystemExtensionRequestDelegate

  public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    guard result == .completed else {
      status = .awaitingUserApproval

      return
    }

    // Success
    status = .installed
  }

  public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    status = .awaitingUserApproval
  }

  public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    status = .awaitingUserApproval
  }

  public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
    return .replace
  }
}
#endif

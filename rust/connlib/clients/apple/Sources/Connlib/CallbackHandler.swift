//
//  CallbackHandler.swift
//

import NetworkExtension
import os.log

// When the FFI changes from the Rust side, change the CallbackHandler
// functions along with that, but not the delegate protocol.
// When the app gets updated to use the FFI, the delegate protocol
// shall get updated.
// This is so that the app stays buildable even when the FFI changes.

// TODO: https://github.com/chinedufn/swift-bridge/issues/150
extension SwiftConnlibError: @unchecked Sendable {}
extension SwiftConnlibError: Error {}

public protocol CallbackHandlerDelegate: AnyObject {
  func onSetInterfaceConfig(tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddress: String)
  func onTunnelReady()
  func onAddRoute(_: String)
  func onRemoveRoute(_: String)
  func onUpdateResources(resourceList: String)
  func onDisconnect(error: Error)
  func onError(error: Error)
}

public class CallbackHandler {
  public weak var delegate: CallbackHandlerDelegate?
  private let logger = Logger(subsystem: "dev.firezone.firezone", category: "callbackhandler")

  func onSetInterfaceConfig(tunnelAddresses: TunnelAddresses, dnsAddress: RustString) {
    logger.debug("CallbackHandler.onSetInterfaceConfig: IPv4: \(tunnelAddresses.address4.toString(), privacy: .public), IPv6: \(tunnelAddresses.address6.toString(), privacy: .public), DNS: \(dnsAddress.toString(), privacy: .public)")
    delegate?.onSetInterfaceConfig(
      tunnelAddressIPv4: tunnelAddresses.address4.toString(),
      tunnelAddressIPv6: tunnelAddresses.address6.toString(),
      dnsAddress: dnsAddress.toString()
    )
  }

  func onTunnelReady() {
    logger.debug("CallbackHandler.onTunnelReady")
    delegate?.onTunnelReady()
  }

  func onAddRoute(route: RustString) {
    logger.debug("CallbackHandler.onAddRoute: \(route.toString(), privacy: .public)")
    delegate?.onAddRoute(route.toString())
  }

  func onRemoveRoute(route: RustString) {
    logger.debug("CallbackHandler.onRemoveRoute: \(route.toString(), privacy: .public)")
    delegate?.onRemoveRoute(route.toString())
  }

  func onUpdateResources(resourceList: RustString) {
    logger.debug("CallbackHandler.onUpdateResources: \(resourceList.toString(), privacy: .public)")
    delegate?.onUpdateResources(resourceList: resourceList.toString())
  }

  func onDisconnect(error: SwiftConnlibError) {
    switch error {
    case .Io(let description, let value):
        logger.debug("CallbackHandler.onDisconnect: Io error with description: \(description) and value: \(value)")
    // Add similar cases for other error variants
    default:
        logger.debug("CallbackHandler.onDisconnect: \(error, privacy: .public)")
    }
    // TODO: convert `error` to `Optional` by checking for `None` case
    delegate?.onDisconnect(error: error)
  }

  func onError(error: SwiftConnlibError) {
    switch error {
    case .Io(let description, let value):
        logger.debug("CallbackHandler.onError: Io error with description: \(description) and value: \(value)")
    // Add similar cases for other error variants
    default:
        logger.debug("CallbackHandler.onError: \(error, privacy: .public)")
    }
    delegate?.onError(error: error)
  }
}

//
//  CallbackHandler.swift
//

import FirezoneKit
import NetworkExtension
import OSLog

// When the FFI changes from the Rust side, change the CallbackHandler
// functions along with that, but not the delegate protocol.
// When the app gets updated to use the FFI, the delegate protocol
// shall get updated.
// This is so that the app stays buildable even when the FFI changes.

// TODO: https://github.com/chinedufn/swift-bridge/issues/150
extension RustString: @unchecked Sendable {}
extension RustString: Error {}

public protocol CallbackHandlerDelegate: AnyObject {
  func onSetInterfaceConfig(
    tunnelAddressIPv4: String,
    tunnelAddressIPv6: String,
    dnsAddresses: [String]
  )
  func onTunnelReady()
  func onUpdateRoutes(routeList4: String, routeList6: String)
  func onUpdateResources(resourceList: String)
  func onDisconnect(error: String?)
}

public class CallbackHandler {
  public weak var delegate: CallbackHandlerDelegate?
  private var systemDefaultResolvers: [String] = []
  private let logger: AppLogger

  init(logger: AppLogger) {
    self.logger = logger
  }
  func onSetInterfaceConfig(
    tunnelAddressIPv4: RustString,
    tunnelAddressIPv6: RustString,
    dnsAddresses: RustString
  ) {
    logger.log(
      """
        CallbackHandler.onSetInterfaceConfig:
          IPv4: \(tunnelAddressIPv4.toString())
          IPv6: \(tunnelAddressIPv6.toString())
          DNS: \(dnsAddresses.toString())
      """)

    guard let dnsData = dnsAddresses.toString().data(using: .utf8) else {
      return
    }
    guard let dnsArray = try? JSONDecoder().decode([String].self, from: dnsData)
    else {
      return
    }

    delegate?.onSetInterfaceConfig(
      tunnelAddressIPv4: tunnelAddressIPv4.toString(),
      tunnelAddressIPv6: tunnelAddressIPv6.toString(),
      dnsAddresses: dnsArray
    )
  }

  func onTunnelReady() {
    logger.log("CallbackHandler.onTunnelReady")
    delegate?.onTunnelReady()
  }

  func onUpdateRoutes(routeList4: RustString, routeList6: RustString) {
    logger.log("CallbackHandler.onUpdateRoutes: \(routeList4) \(routeList6)")
    delegate?.onUpdateRoutes(routeList4: routeList4.toString(), routeList6: routeList6.toString())
  }

  func onUpdateResources(resourceList: RustString) {
    logger.log("CallbackHandler.onUpdateResources: \(resourceList.toString())")
    delegate?.onUpdateResources(resourceList: resourceList.toString())
  }

  func onDisconnect(error: RustString) {
    logger.log("CallbackHandler.onDisconnect: \(error.toString())")
    let error = error.toString()
    var optionalError = Optional.some(error)
    if error.isEmpty {
      optionalError = Optional.none
    }
    delegate?.onDisconnect(error: optionalError)
  }

  func setSystemDefaultResolvers(resolvers: [String]) {
    logger.log(
      "CallbackHandler.setSystemDefaultResolvers: \(resolvers)")
    self.systemDefaultResolvers = resolvers
  }

  func getSystemDefaultResolvers() -> RustString {
    logger.log(
      "CallbackHandler.getSystemDefaultResolvers: \(self.systemDefaultResolvers)"
    )

    return try! String(
      decoding: JSONEncoder().encode(self.systemDefaultResolvers),
      as: UTF8.self
    ).intoRustString()
  }
}

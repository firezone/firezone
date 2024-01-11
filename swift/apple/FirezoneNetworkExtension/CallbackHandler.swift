//
//  CallbackHandler.swift
//

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
  func onAddRoute(_: String)
  func onRemoveRoute(_: String)
  func onUpdateResources(resourceList: String)
  func onDisconnect(error: String?)
}

public class CallbackHandler {
  public weak var delegate: CallbackHandlerDelegate?
  private var systemDefaultResolvers: RustString = "[]".intoRustString()
  private let logger = Logger.make(for: CallbackHandler.self)

  func onSetInterfaceConfig(
    tunnelAddressIPv4: RustString,
    tunnelAddressIPv6: RustString,
    dnsAddresses: RustString
  ) {
    logger.log(
      """
        CallbackHandler.onSetInterfaceConfig:
          IPv4: \(tunnelAddressIPv4.toString(), privacy: .public)
          IPv6: \(tunnelAddressIPv6.toString(), privacy: .public)
          DNS: \(dnsAddress.toString(), privacy: .public)
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
      dnsAddress: dnsAddress.toString()
    )
  }

  func onTunnelReady() {
    logger.log("CallbackHandler.onTunnelReady")
    delegate?.onTunnelReady()
  }

  func onAddRoute(route: RustString) {
    logger.log("CallbackHandler.onAddRoute: \(route.toString(), privacy: .public)")
    delegate?.onAddRoute(route.toString())
  }

  func onRemoveRoute(route: RustString) {
    logger.log("CallbackHandler.onRemoveRoute: \(route.toString(), privacy: .public)")
    delegate?.onRemoveRoute(route.toString())
  }

  func onUpdateResources(resourceList: RustString) {
    logger.log("CallbackHandler.onUpdateResources: \(resourceList.toString(), privacy: .public)")
    delegate?.onUpdateResources(resourceList: resourceList.toString())
  }

  func onDisconnect(error: RustString) {
    logger.log("CallbackHandler.onDisconnect: \(error.toString(), privacy: .public)")
    let error = error.toString()
    var optionalError = Optional.some(error)
    if error.isEmpty {
      optionalError = Optional.none
    }
    delegate?.onDisconnect(error: optionalError)
  }

  func setSystemDefaultResolvers(resolvers: [String]) {
    logger.log(
      "CallbackHandler.setSystemDefaultResolvers: \(resolvers, privacy: .public)")
    do {
      self.systemDefaultResolvers = try String(
        decoding: JSONEncoder().encode(resolvers), as: UTF8.self
      )
      .intoRustString()
    } catch {
      logger.log("CallbackHandler.setSystemDefaultResolvers: \(error, privacy: .public)")
      self.systemDefaultResolvers = "[]".intoRustString()
    }
  }

  func getSystemDefaultResolvers() -> RustString {
    logger.log(
      "CallbackHandler.getSystemDefaultResolvers: \(self.systemDefaultResolvers, privacy: .public)"
    )

    return systemDefaultResolvers
  }
}

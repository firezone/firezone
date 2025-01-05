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
  func onUpdateRoutes(routeList4: String, routeList6: String)
  func onUpdateResources(resourceList: String)
  func onDisconnect(error: String)
}

public class CallbackHandler {
  public weak var delegate: CallbackHandlerDelegate?

  func onSetInterfaceConfig(
    tunnelAddressIPv4: RustString,
    tunnelAddressIPv6: RustString,
    dnsAddresses: RustString
  ) {
    Log.log(
      """
        CallbackHandler.onSetInterfaceConfig:
          IPv4: \(tunnelAddressIPv4.toString())
          IPv6: \(tunnelAddressIPv6.toString())
          DNS: \(dnsAddresses.toString())
      """)

    let dnsData = dnsAddresses.toString().data(using: .utf8)!
    let dnsArray = try! JSONDecoder().decode([String].self, from: dnsData)

    delegate?.onSetInterfaceConfig(
      tunnelAddressIPv4: tunnelAddressIPv4.toString(),
      tunnelAddressIPv6: tunnelAddressIPv6.toString(),
      dnsAddresses: dnsArray
    )
  }

  func onUpdateRoutes(routeList4: RustString, routeList6: RustString) {
    Log.log("CallbackHandler.onUpdateRoutes: \(routeList4) \(routeList6)")
    delegate?.onUpdateRoutes(routeList4: routeList4.toString(), routeList6: routeList6.toString())
  }

  func onUpdateResources(resourceList: RustString) {
    Log.log("CallbackHandler.onUpdateResources: \(resourceList.toString())")
    delegate?.onUpdateResources(resourceList: resourceList.toString())
  }

  func onDisconnect(error: RustString) {
    let error = error.toString()
    Log.log("CallbackHandler.onDisconnect: \(error)")
    delegate?.onDisconnect(error: error)
  }
}

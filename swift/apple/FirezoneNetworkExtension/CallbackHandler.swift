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

// See https://github.com/chinedufn/swift-bridge/issues/150
extension RustString: @unchecked Sendable {}
extension RustString: Error {}

public protocol CallbackHandlerDelegate: AnyObject {
  // swiftlint:disable:next function_parameter_count
  func onSetInterfaceConfig(
    tunnelAddressIPv4: String,
    tunnelAddressIPv6: String,
    searchDomain: String?,
    dnsAddresses: [String],
    routeListv4: String,
    routeListv6: String
  )
  func onUpdateResources(resourceList: String)
  func onDisconnect(error: String)
}

public class CallbackHandler {
  public weak var delegate: CallbackHandlerDelegate?
  // swiftlint:disable:next function_parameter_count
  func onSetInterfaceConfig(
    tunnelAddressIPv4: RustString,
    tunnelAddressIPv6: RustString,
    searchDomain: RustString?,
    dnsAddresses: RustString,
    routeListv4: RustString,
    routeListv6: RustString
  ) {
    Log.log(
      """
        CallbackHandler.onSetInterfaceConfig:
          IPv4: \(tunnelAddressIPv4.toString())
          IPv6: \(tunnelAddressIPv6.toString())
          SearchDomain: \(String(describing: (searchDomain?.toString())))
          DNS: \(dnsAddresses.toString())
          IPv4 routes:  \(routeListv4.toString())
          IPv6 routes: \(routeListv6.toString())
      """)

    guard let dnsData = dnsAddresses.toString().data(using: .utf8),
          let dnsArray = try? JSONDecoder().decode([String].self, from: dnsData)
    else {
      fatalError("Should be able to decode DNS Addresses from connlib")
    }

    delegate?.onSetInterfaceConfig(
      tunnelAddressIPv4: tunnelAddressIPv4.toString(),
      tunnelAddressIPv6: tunnelAddressIPv6.toString(),
      searchDomain: searchDomain?.toString(),
      dnsAddresses: dnsArray,
      routeListv4: routeListv4.toString(),
      routeListv6: routeListv6.toString()
    )
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

//
//  Callbacks.swift
//  connlib
//
//  Created by Jamil Bou Kheir on 4/3/23.
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
    func onConnect(tunnelAddressIPv4: String, tunnelAddressIPv6: String)
    func onUpdateResources(resourceList: String)
    func onDisconnect()
    func onError(error: Error, isRecoverable: Bool)
}

public class CallbackHandler {
    public weak var delegate: CallbackHandlerDelegate?

    func onUpdateResources(resourceList: ResourceList) {
        delegate?.onUpdateResources(resourceList: resourceList.resources.toString())
    }

    func onConnect(tunnelAddresses: TunnelAddresses) {
        delegate?.onConnect(
            tunnelAddressIPv4: tunnelAddresses.address4.toString(),
            tunnelAddressIPv6: tunnelAddresses.address6.toString()
        )
    }

    func onDisconnect() {
        delegate?.onDisconnect()
    }

    func onError(error: SwiftConnlibError, error_type: SwiftErrorType) {
        delegate?.onError(error: error, isRecoverable: error_type == .Recoverable)
    }
}

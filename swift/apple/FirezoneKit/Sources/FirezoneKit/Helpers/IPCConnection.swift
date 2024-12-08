//
//  IPCService.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Used to facilitate IPC between app and system extension outside
//  of the context of the Network Extension.

import Foundation

@objc protocol ProviderCommunication {
  func register(_ completionHandler: @escaping (Bool) -> Void)
  func getDirHandle(logDir: String, _ completionHandler: @escaping (Int32) -> Void)
}

@objc public protocol AppCommunication {}

public class IPCConnection: NSObject {
  var listener: NSXPCListener?
  var currentConnection: NSXPCConnection?
  weak var delegate: AppCommunication?
  public static let shared = IPCConnection()

  private func extensionMachServiceName(from bundle: Bundle) -> String {

    guard let networkExtensionKeys = bundle.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
          let machServiceName = networkExtensionKeys["NEMachServiceName"] as? String else {
      fatalError("Mach service name is missing from the Info.plist")
    }

    return machServiceName
  }

  public func startListener() {

    let machServiceName = extensionMachServiceName(from: Bundle.main)
    Log.tunnel.log("Starting XPC listener for mach service \(machServiceName)")

    let newListener = NSXPCListener(machServiceName: machServiceName)
    newListener.delegate = self
    newListener.resume()
    listener = newListener
  }

  public func register(withExtension bundle: Bundle, delegate: AppCommunication, completionHandler: @escaping (Bool) -> Void) {
    self.delegate = delegate

    guard currentConnection == nil else {
      Log.app.log("Already registered with the provider")
      completionHandler(true)
      return
    }

    let machServiceName = extensionMachServiceName(from: bundle)
    let newConnection = NSXPCConnection(machServiceName: machServiceName, options: [])

    // The exported object is the delegate.
    newConnection.exportedInterface = NSXPCInterface(with: AppCommunication.self)
    newConnection.exportedObject = delegate

    // The remote object is the provider's IPCConnection instance.
    newConnection.remoteObjectInterface = NSXPCInterface(with: ProviderCommunication.self)

    currentConnection = newConnection
    newConnection.resume()

    guard let providerProxy = newConnection.remoteObjectProxyWithErrorHandler({ registerError in
      Log.app.log("Failed to register with the provider: \(registerError.localizedDescription)")
      self.currentConnection?.invalidate()
      self.currentConnection = nil
      completionHandler(false)
    }) as? ProviderCommunication else {
      fatalError("Failed to create a remote object proxy for the provider")
    }

    providerProxy.register(completionHandler)
  }
}

extension IPCConnection: NSXPCListenerDelegate {
  public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {

    // The exported object is this IPCConnection instance.
    newConnection.exportedInterface = NSXPCInterface(with: ProviderCommunication.self)
    newConnection.exportedObject = self

    // The remote object is the delegate of the app's IPCConnection instance.
    newConnection.remoteObjectInterface = NSXPCInterface(with: AppCommunication.self)

    newConnection.invalidationHandler = {
      self.currentConnection = nil
    }

    newConnection.interruptionHandler = {
      self.currentConnection = nil
    }

    currentConnection = newConnection
    newConnection.resume()

    return true
  }
}

extension IPCConnection: ProviderCommunication {

  // MARK: ProviderCommunication

  func register(_ completionHandler: @escaping (Bool) -> Void) {
    Log.tunnel.log("App registered")
    completionHandler(true)
  }

  func getDirHandle(logDir: String, _ completionHandler: @escaping (Int32) -> Void) {
    Log.tunnel.log("App requesting dir handle for \(logDir)")
    completionHandler(-1)
  }
}

//
//  SystemConfigurationResolvers.swift
//  FirezoneNetworkExtensionmacOS
//
//  Created by Jamil Bou Kheir on 2/26/24.
//

import FirezoneKit
import Foundation
import SystemConfiguration

class SystemConfigurationResolvers {
  enum SystemConfigurationError: Error {
    case failedToCreateDynamicStore(code: Int32)
    case unableToRetrieveNetworkServices(code: Int32)
    case unableToCopyValue(path: String, code: Int32)

    var localizedDescription: String {
      switch self {
      case .failedToCreateDynamicStore(let code):
        return "Failed to create dynamic store. Code: \(code)"
      case .unableToRetrieveNetworkServices(let code):
        return "Unable to retrieve network services. Code: \(code)"
      case .unableToCopyValue(let path, let code):
        return "Unable to copy value from path \(path). Code: \(code)"
      }
    }
  }
  private var dynamicStore: SCDynamicStore?

  // Arbitrary name for the connection to the store
  private let storeName = "dev.firezone.firezone.dns" as CFString

  init() {
    guard let dynamicStore = SCDynamicStoreCreate(nil, storeName, nil, nil)
    else {
      let code = SCError()
      Log.error(SystemConfigurationError.failedToCreateDynamicStore(code: code))
      self.dynamicStore = nil
      return
    }

    self.dynamicStore = dynamicStore
  }

  /// 1. First, find the service ID that corresponds to the interface we're interested in.
  ///    We do this by searching the configuration store at "Setup:/Network/Service/<service-id>/Interface"
  ///    for a matching "InterfaceName".
  /// 2. When we get a hit, save the service id we found.
  /// 3. The DNS ServerAddresses can be found in two places:
  ///    * If the user has manually overridden the DNS servers for an interface,
  ///      they'll be at "Setup:/Network/Service/<service-id>/DNS"
  ///    * If they haven't, then the DHCP server addresses can be found at
  ///      State:/Network/Service/<service-id>/DNS
  /// 4. We assume manually-set DNS servers take precedence over DHCP ones,
  ///    so return those if found. Otherwise, return the DHCP ones.
  public func getDefaultDNSServers(interfaceName: String?) -> [String] {
    guard let dynamicStore = dynamicStore,
          let interfaceName = interfaceName
    else {
      return []
    }

    let interfaceSearchKey = "Setup:/Network/Service/.*/Interface" as CFString
    guard let services = SCDynamicStoreCopyKeyList(dynamicStore, interfaceSearchKey) as? [String]
    else {
      let code = SCError()
      Log.error(SystemConfigurationError.unableToRetrieveNetworkServices(code: code))
      return []
    }

    // Loop over all the services found, checking for the one we want
    for service in services {
      guard let configInterfaceName = fetch(path: service, key: "DeviceName") as? String,
            configInterfaceName == interfaceName
      else { continue }

      // Extract our serviceId
      let serviceId = service.split(separator: "/")[3]

      // Try to get any manually-assigned DNS servers
      let manualDnsPath = "Setup:/Network/Service/\(serviceId)/DNS"
      if let serverAddresses = fetch(path: manualDnsPath, key: "ServerAddresses") as? [String] {
        return serverAddresses
      }

      // None found. Try getting the DHCP ones instead.
      let dhcpDnsPath = "State:/Network/Service/\(serviceId)/DNS"
      if let serverAddresses = fetch(path: dhcpDnsPath, key: "ServerAddresses") as? [String] {
        return serverAddresses
      }
    }

    // Otherwise, we failed
    return []
  }

  private func fetch(path: String, key: String) -> Any? {
    guard let dynamicStore = dynamicStore
    else { return nil }

    guard let result = SCDynamicStoreCopyValue(dynamicStore, path as CFString)
    else {
      let code = SCError()

      // kSCStatusNoKey indicates the key is missing, which is expected if the
      // interface has no DNS configuration.
      if code == kSCStatusNoKey {
        return nil
      }

      Log.error(SystemConfigurationError.unableToCopyValue(path: path, code: code))

      return nil
    }

    guard let value = result[key]
    else { return nil }

    return value
  }
}

//
//  SystemConfiguration.swift
//  FirezoneNetworkExtensionmacOS
//
//  Created by Jamil Bou Kheir on 2/26/24.
//

import Foundation
import SystemConfiguration
import FirezoneKit

class SystemConfigurationResolvers {
  private let logger: AppLogger

  init(logger: AppLogger) {
    self.logger = logger
  }

  func getDefaultDNSServers() -> [String] {
      var dnsServers: [String] = []

      // Create a dynamic store reference
      guard let dynamicStore = SCDynamicStoreCreate(nil, "GetDefaultDNSServers" as CFString, nil, nil) else {
        self.logger.error("\(#function): Failed to create dynamic store")
        return []
      }

      // Specify the DNS key to fetch the current DNS servers
      let dnsKey = "State:/Network/Global/DNS" as CFString

      // Retrieve the current DNS server configuration from the dynamic store
      guard let dnsInfo = SCDynamicStoreCopyValue(dynamicStore, dnsKey) as? [String: Any],
        let servers = dnsInfo[kSCPropNetDNSServerAddresses as String] as? [String] else {
          self.logger.error("\(#function): Failed to retrieve DNS server information")
          return []
        }

      // Append the retrieved DNS servers to the result array
      dnsServers.append(contentsOf: servers)

      return dnsServers
  }
}

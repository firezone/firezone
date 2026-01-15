//
//  SystemConfigurationResolvers.swift
//  (c) 2024-2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

#if os(macOS)
  import SystemConfiguration
#endif

/// Provides access to the system's DNS resolver configuration.
///
/// On macOS, this uses the public SystemConfiguration framework to read DNS servers
/// from SCDynamicStore.
///
/// On iOS, the SystemConfiguration framework is not available in Network Extensions.
/// Instead, we use dlsym to access the `dns_configuration_copy` function, which returns
/// scoped resolvers that aren't shadowed by our tunnel's DNS settings.
public class SystemConfigurationResolvers {

  public init() {}

  /// Returns the DNS servers configured for the given interface using the
  /// platform-appropriate method.
  ///
  /// - On macOS: Uses the SystemConfiguration framework (public API)
  /// - On iOS: Uses dlsym to access `dns_configuration_copy` (private API)
  public func getDefaultDNSServers(interfaceName: String?) -> [String] {
    #if os(macOS)
      return getDefaultDNSServersViaSystemConfiguration(interfaceName: interfaceName)
    #else
      return getDefaultDNSServersViaScopedResolvers(interfaceName: interfaceName)
    #endif
  }

  // MARK: - Scoped Resolvers Implementation (via dlsym)

  /// Returns the DNS servers configured for the given interface using the
  /// `dns_configuration_copy` private API via dlsym.
  ///
  /// This method is available on both macOS and iOS, making it testable in CI.
  /// On iOS, this is the primary method used since SystemConfiguration is unavailable
  /// in Network Extensions.
  ///
  /// - Parameter interfaceName: The network interface name (e.g., "en0", "pdp_ip0")
  /// - Returns: Array of DNS server IP addresses, or empty array if unavailable
  public func getDefaultDNSServersViaScopedResolvers(interfaceName: String?) -> [String] {
    guard let interfaceName = interfaceName else {
      return []
    }

    guard let copyFn = Self.dnsConfigurationCopy,
      let freeFn = Self.dnsConfigurationFree,
      let configPtr = copyFn()
    else {
      Log.warning("Failed to get DNS configuration via dns_configuration_copy")
      return []
    }
    defer { freeFn(configPtr) }

    let config = UnsafeRawPointer(configPtr)

    // dns_config layout (pack(4)):
    //   0: n_resolver (int32_t)
    //   4: resolver (uint64_t union)
    //  12: n_scoped_resolver (int32_t)
    //  16: scoped_resolver (uint64_t union)

    let nScopedResolver: Int32 = Self.readUnaligned(from: config, offset: 12)
    guard nScopedResolver > 0 else { return [] }

    let scopedResolverArrayAddr: UInt = Self.readUnaligned(from: config, offset: 16)
    guard scopedResolverArrayAddr != 0 else { return [] }

    let resolverPtrArray = UnsafeRawPointer(bitPattern: scopedResolverArrayAddr)!

    for i in 0..<Int(nScopedResolver) {
      let resolverAddr: UInt = Self.readUnaligned(
        from: resolverPtrArray, offset: i * MemoryLayout<UInt>.size)
      guard resolverAddr != 0 else { continue }

      let resolver = UnsafeRawPointer(bitPattern: resolverAddr)!

      // dns_resolver layout (pack(4)):
      //   0: domain (uint64_t union)
      //   8: n_nameserver (int32_t)
      //  12: nameserver (uint64_t union)
      //  20: port (uint16_t)
      //  22: padding
      //  24: n_search (int32_t)
      //  28: search (uint64_t union)
      //  36: n_sortaddr (int32_t)
      //  40: sortaddr (uint64_t union)
      //  48: options (uint64_t union)
      //  56: timeout (uint32_t)
      //  60: search_order (uint32_t)
      //  64: if_index (uint32_t)

      let ifIndex: UInt32 = Self.readUnaligned(from: resolver, offset: 64)
      guard ifIndex > 0,
        let ifName = Self.interfaceName(for: ifIndex),
        ifName == interfaceName
      else { continue }

      let nNameserver: Int32 = Self.readUnaligned(from: resolver, offset: 8)
      let nameserverArrayAddr: UInt = Self.readUnaligned(from: resolver, offset: 12)

      guard nNameserver > 0, nameserverArrayAddr != 0 else { continue }

      let nameserverArray = UnsafeRawPointer(bitPattern: nameserverArrayAddr)!
      var servers: [String] = []

      for j in 0..<Int(nNameserver) {
        let saAddr: UInt = Self.readUnaligned(
          from: nameserverArray, offset: j * MemoryLayout<UInt>.size)
        guard saAddr != 0 else { continue }

        let sa = UnsafeRawPointer(bitPattern: saAddr)!.assumingMemoryBound(to: sockaddr.self)
        if let ip = Self.stringFromSockaddr(sa) {
          servers.append(ip)
        }
      }

      if !servers.isEmpty {
        return servers
      }
    }

    return []
  }

  // MARK: - Private: Unaligned memory read

  private static func readUnaligned<T>(from pointer: UnsafeRawPointer, offset: Int) -> T {
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    memcpy(value, pointer.advanced(by: offset), MemoryLayout<T>.size)
    return value.pointee
  }

  // MARK: - Private: dns_configuration via dlsym

  private typealias DnsConfigurationCopyFn = @convention(c) () -> UnsafeMutableRawPointer?
  private typealias DnsConfigurationFreeFn = @convention(c) (UnsafeMutableRawPointer) -> Void

  private static let dnsConfigurationCopy: DnsConfigurationCopyFn? = {
    dlsym(dlopen(nil, RTLD_LAZY), "dns_configuration_copy")
      .map { unsafeBitCast($0, to: DnsConfigurationCopyFn.self) }
  }()

  private static let dnsConfigurationFree: DnsConfigurationFreeFn? = {
    dlsym(dlopen(nil, RTLD_LAZY), "dns_configuration_free")
      .map { unsafeBitCast($0, to: DnsConfigurationFreeFn.self) }
  }()

  // MARK: - Private: Helpers

  private static func interfaceName(for index: UInt32) -> String? {
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    guard if_indextoname(index, &buf) != nil else { return nil }
    return buf.withUnsafeBufferPointer { ptr in
      String(
        decoding: ptr.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }

  private static func stringFromSockaddr(_ sa: UnsafePointer<sockaddr>) -> String? {
    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let len: socklen_t
    switch Int32(sa.pointee.sa_family) {
    case AF_INET:
      len = socklen_t(MemoryLayout<sockaddr_in>.size)
    case AF_INET6:
      len = socklen_t(MemoryLayout<sockaddr_in6>.size)
    default:
      return nil
    }
    guard getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else {
      return nil
    }
    return buf.withUnsafeBufferPointer { ptr in
      String(
        decoding: ptr.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }

  #if os(macOS)
    // MARK: - SystemConfiguration Implementation (macOS only)

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

    /// We use a computed property to memoize the creation of SC Dynamic Store, since this
    /// can fail in some circumstances to initialize, like because of allocation failures.
    private var _dynamicStore: SCDynamicStore?
    private var dynamicStore: SCDynamicStore? {
      if self._dynamicStore == nil {
        guard let dynamicStore = SCDynamicStoreCreate(nil, storeName, nil, nil)
        else {
          let code = SCError()
          Log.error(SystemConfigurationError.failedToCreateDynamicStore(code: code))
          return nil
        }

        self._dynamicStore = dynamicStore
      }

      return self._dynamicStore
    }

    // Arbitrary name for the connection to the store
    private let storeName = "dev.firezone.firezone.dns" as CFString

    /// Returns the DNS servers configured for the given interface using the
    /// SystemConfiguration framework.
    ///
    /// This method is only available on macOS.
    ///
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
    public func getDefaultDNSServersViaSystemConfiguration(interfaceName: String?) -> [String] {
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
  #endif
}

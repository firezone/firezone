//
//  ScopedResolvers.swift
//  (c) 2024-2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Provides access to the system's DNS resolver configuration using scoped resolvers.
///
/// This uses dlsym to access the `dns_configuration_copy` private API, which returns
/// scoped resolvers that aren't shadowed by our tunnel's DNS settings.
public class ScopedResolvers {

  public init() {}

  /// Returns the DNS servers configured for the given interface.
  ///
  /// - Parameter interfaceName: The network interface name (e.g., "en0", "pdp_ip0")
  /// - Returns: Array of DNS server IP addresses, or empty array if unavailable
  public func getDefaultDNSServers(interfaceName: String?) -> [String] {
    guard let interfaceName = interfaceName, !interfaceName.isEmpty else {
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
    guard scopedResolverArrayAddr != 0,
      let resolverPtrArray = UnsafeRawPointer(bitPattern: scopedResolverArrayAddr)
    else { return [] }

    for i in 0..<Int(nScopedResolver) {
      let resolverAddr: UInt = Self.readUnaligned(
        from: resolverPtrArray, offset: i * MemoryLayout<UInt>.size)
      guard resolverAddr != 0,
        let resolver = UnsafeRawPointer(bitPattern: resolverAddr)
      else { continue }

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

      guard nNameserver > 0, nameserverArrayAddr != 0,
        let nameserverArray = UnsafeRawPointer(bitPattern: nameserverArrayAddr)
      else { continue }

      var servers: [String] = []

      for j in 0..<Int(nNameserver) {
        let saAddr: UInt = Self.readUnaligned(
          from: nameserverArray, offset: j * MemoryLayout<UInt>.size)
        guard saAddr != 0,
          let saPtr = UnsafeRawPointer(bitPattern: saAddr)
        else { continue }

        let sa = saPtr.assumingMemoryBound(to: sockaddr.self)
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
    // Use Swift's unaligned load to avoid heap allocations in tight loops
    return pointer.loadUnaligned(fromByteOffset: offset, as: T.self)
  }

  // MARK: - Private: dns_configuration via dlsym

  private typealias DnsConfigurationCopyFn = @convention(c) () -> UnsafeMutableRawPointer?
  private typealias DnsConfigurationFreeFn = @convention(c) (UnsafeMutableRawPointer) -> Void

  // Note: dlopen(nil, RTLD_LAZY) returns a handle to the main program itself.
  // This handle should not be closed with dlclose() as it doesn't represent a
  // separately loaded library. The handle is intentionally stored in static
  // properties for the lifetime of the process.
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
    return stringFromCCharArray(buf)
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
    var result = stringFromCCharArray(buf)
    // Strip IPv6 scope suffix (e.g., "fe80::1%en0" -> "fe80::1")
    if let percentIndex = result.firstIndex(of: "%") {
      result = String(result[..<percentIndex])
    }
    return result
  }

  private static func stringFromCCharArray(_ array: [CChar]) -> String {
    // Convert a null-terminated CChar array to a Swift String by reading up to the first NUL and decoding as UTF-8
    return array.withUnsafeBufferPointer { buffer in
      // swiftlint:disable:next optional_data_string_conversion
      String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }
}

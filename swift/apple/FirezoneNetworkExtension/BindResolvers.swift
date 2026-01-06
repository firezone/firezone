//
//  BindResolvers.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
// Reads system resolvers from libresolv, similar to reading /etc/resolv.conf but this also works on iOS

import FirezoneKit

enum BindResolvers {

  static func getServers() -> [String] {
    // 1. Manually allocate memory for one __res_9_state struct. On iOS 17 and below, this prevents the linker
    // from attempting to link to libresolv9 which prevents an "Symbol not found" error.
    // See https://github.com/firezone/firezone/issues/10108
    let statePtr = UnsafeMutablePointer<__res_9_state>.allocate(capacity: 1)
    statePtr.initialize(to: __res_9_state())  // Zero-initialize the allocated memory.

    // 2. Ensure memory is cleaned up.
    defer {
      res_9_ndestroy(statePtr)
      statePtr.deinitialize(count: 1)
      statePtr.deallocate()
    }

    // 3. Initialize the resolver state by passing the pointer directly.
    guard res_9_ninit(statePtr) == 0 else {
      Log.warning("Failed to initialize resolver state")

      // Cleanup will happen via defer.
      return []
    }

    // 4. Get the servers.
    var servers = [res_9_sockaddr_union](repeating: res_9_sockaddr_union(), count: 10)
    let foundCount = Int(res_9_getservers(statePtr, &servers, Int32(servers.count)))

    // 5. Process the results.
    let validServers = Array(servers[0..<foundCount]).filter { $0.sin.sin_len > 0 }
    return validServers.map { getnameinfo($0) }
  }

  private static func getnameinfo(_ sock: res_9_sockaddr_union) -> String {
    var sockUnion = sock
    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let sinlen = socklen_t(sockUnion.sin.sin_len)

    _ = withUnsafePointer(to: &sockUnion) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.getnameinfo(
          $0, sinlen,
          &hostBuffer, socklen_t(hostBuffer.count),
          nil, 0,
          NI_NUMERICHOST)
      }
    }
    // Truncate null termination and decode as UTF-8
    // Convert CChar (Int8) to UInt8 for String(decoding:)
    if let nullIndex = hostBuffer.firstIndex(of: 0) {
      let bytes = hostBuffer[..<nullIndex].map { UInt8(bitPattern: $0) }
      return String(decoding: bytes, as: UTF8.self)
    } else {
      let bytes = hostBuffer.map { UInt8(bitPattern: $0) }
      return String(decoding: bytes, as: UTF8.self)
    }
  }
}

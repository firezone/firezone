//
//  BindResolvers.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
// Reads system resolvers from libresolv, similar to reading /etc/resolv.conf but this also works on iOS

import FirezoneKit

public class BindResolvers {
  var state: __res_9_state

  public init() {
    self.state = __res_9_state()

    res_9_ninit(&state)
  }

  deinit {
    res_9_ndestroy(&state)
  }

  public final func getservers() -> [res_9_sockaddr_union] {
    let maxServers = 10
    var servers = [res_9_sockaddr_union](repeating: res_9_sockaddr_union(), count: maxServers)
    let found = Int(res_9_getservers(&state, &servers, Int32(maxServers)))

    // filter is to remove the erroneous empty entry when there's no real servers
    return Array(servers[0..<found]).filter { $0.sin.sin_len > 0 }
  }
}

extension BindResolvers {
  public static func getnameinfo(_ sock: res_9_sockaddr_union) -> String {
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

    return String(cString: hostBuffer)
  }
}

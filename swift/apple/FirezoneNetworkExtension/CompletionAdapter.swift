// (c) 2026 Firezone, Inc.
// LICENSE: Apache-2.0

import FirezoneKit
import Foundation
import Network
import NetworkExtension

/// All state and I/O submissions are serialized on `queue`.
final class CompletionAdapter: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.firezone.completion", qos: .userInteractive)
  private let flow: NEPacketTunnelFlow
  private let provider: NEPacketTunnelProvider
  private var session: OpaquePointer?
  private var timer: DispatchSourceTimer?
  private var listeners: [NWListener] = []
  private var connections: [String: NWConnection] = [:]
  private var generation: UInt64 = 0
  private var running = false
  private var stopping = false
  private var onStopped: (@Sendable () -> Void)?
  private let pathMonitor = NWPathMonitor()
  private var lastInterface: String?
  private var settings = NetworkSettings()
  private var onStarted: (@Sendable (Error?) -> Void)?

  init(provider: NEPacketTunnelProvider) {
    self.provider = provider
    self.flow = provider.packetFlow
  }

  func start(config: Data, completion: @escaping @Sendable (Error?) -> Void) {
    queue.async {
      var error: UnsafeMutablePointer<CChar>?
      self.session = config.withUnsafeBytes { bytes in
        let text = String(decoding: bytes, as: UTF8.self)
        return text.withCString { fz_completion_new($0, &error) }
      }
      guard self.session != nil else {
        let message = error.map { String(cString: $0) } ?? "Unable to create Rust driver"
        if let error { fz_completion_string_free(error) }
        completion(CompletionError(message))
        return
      }
      self.running = true
      self.onStarted = completion
      do { try self.bindListeners() } catch { self.fail(error); return }
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      // This services the existing Rust portal/DNS reactor and timers. Packet
      // completions call `pump` immediately without waiting for this timer.
      timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
      timer.setEventHandler { [weak self] in self?.pump() }
      self.timer = timer
      timer.resume()
      self.pathMonitor.pathUpdateHandler = { [weak self] path in
        guard let self else { return }
        self.setDNS(ScopedResolvers.getDefaultDNSServers(interfaceName: path.availableInterfaces.first?.name))
        let interface = path.availableInterfaces.first?.name
        if self.lastInterface != nil, interface != self.lastInterface { self.reset() }
        self.lastInterface = interface
      }
      self.pathMonitor.start(queue: self.queue)
      self.readTun()
    }
  }

  func reset() {
    queue.async {
      guard let session = self.session else { return }
      _ = fz_completion_reset(session)
      self.pump()
    }
  }

  func setDNS(_ addresses: [String]) {
    queue.async {
      guard let session = self.session,
        let data = try? JSONEncoder().encode(addresses),
        let json = String(data: data, encoding: .utf8)
      else { return }
      json.withCString { _ = fz_completion_set_dns(session, $0) }
      self.pump()
    }
  }

  func stop(completion: @escaping @Sendable () -> Void) {
    queue.async {
      guard let session = self.session else { completion(); return }
      self.onStopped = completion
      self.stopping = true
      _ = fz_completion_stop(session)
      self.pump()
    }
  }

  private func pump() {
    guard running, let session else { return }
    let status = fz_completion_poll(session)
    if status < 0 { fail(driverError()); return }
    while let pointer = fz_completion_next_event(session) {
      let data = Data(String(cString: pointer).utf8)
      fz_completion_string_free(pointer)
      do { try handleEvent(data) } catch { fail(error); return }
    }
    var operation = FzPacketOperation()
    while fz_completion_next_operation(session, &operation) == 0 {
      submit(operation)
    }
    if status == 2 { destroy() }
  }

  private func submit(_ operation: FzPacketOperation) {
    guard let session, let buffer = operation.buffer else { return }
    let owner = OutputBuffer(buffer)
    switch operation.kind {
    case 1:
      do {
        let connection = try connection(for: operation)
        let completion = SendCompletion(id: operation.id, remaining: operation.packets)
        connection.batch {
          for index in 0..<operation.packets {
            guard let data = owner.packet(index) else { fail(CompletionError("Invalid packet lease")); return }
            let context = NWConnection.ContentContext(identifier: "firezone", metadata: [ipMetadata(operation.ecn)])
            connection.send(content: data, contentContext: context, completion: .contentProcessed { [weak self] error in
              guard let self else { return }
              completion.remaining -= 1
              completion.failed = completion.failed || error != nil
              if completion.remaining == 0, let session = self.session {
                _ = fz_completion_complete(session, completion.id, completion.failed ? -1 : 0)
                self.pump()
              }
            })
          }
        }
      } catch {
        _ = fz_completion_complete(session, operation.id, -1)
      }
    case 2:
      let packets = (0..<operation.packets).compactMap { owner.packet($0) }
      let families = packets.map { data -> NSNumber in
        NSNumber(value: data.first.map { $0 >> 4 } == 6 ? AF_INET6 : AF_INET)
      }
      let accepted = packets.count == operation.packets && flow.writePackets(packets, withProtocols: families)
      _ = fz_completion_complete(session, operation.id, accepted ? 0 : -1)
    case 3:
      generation = operation.generation
      cancelConnections()
      do { try bindListeners(); _ = fz_completion_complete(session, operation.id, 0) }
      catch { _ = fz_completion_complete(session, operation.id, -1); fail(error) }
    default:
      _ = fz_completion_complete(session, operation.id, -1)
    }
  }

  private func bindListeners() throws {
    for host in ["0.0.0.0", "::"] {
      let parameters = NWParameters.udp
      parameters.allowLocalEndpointReuse = true
      parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: 52625)
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        self.install(connection, key: "incoming:\(connection.endpoint)")
      }
      listener.stateUpdateHandler = { [weak self] state in
        if case .failed(let error) = state { self?.fail(error) }
      }
      listeners.append(listener)
      listener.start(queue: queue)
    }
  }

  private func connection(for operation: FzPacketOperation) throws -> NWConnection {
    let remote = try endpoint(operation.remote)
    let local = operation.local.family == 0
      ? NWEndpoint.hostPort(host: NWEndpoint.Host(operation.remote.family == 4 ? "0.0.0.0" : "::"), port: 52625)
      : try endpoint(operation.local)
    let key = "\(local)>\(remote)"
    if let connection = connections[key] { return connection }
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = local
    let connection = NWConnection(to: remote, using: parameters)
    install(connection, key: key)
    return connection
  }

  private func install(_ connection: NWConnection, key: String) {
    connections[key] = connection
    let currentGeneration = generation
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, self.generation == currentGeneration else { return }
      switch state {
      case .ready: self.receive(connection, generation: currentGeneration)
      case .failed: connection.cancel(); self.connections.removeValue(forKey: key)
      default: break
      }
    }
    connection.start(queue: queue)
  }

  private func receive(_ connection: NWConnection, generation: UInt64) {
    connection.receiveMessage { [weak self, weak connection] data, context, _, error in
      guard let self, let connection, self.running, generation == self.generation,
        let session = self.session else { return }
      if let data, !data.isEmpty,
        let local = connection.currentPath?.localEndpoint,
        let localAddress = self.address(local),
        let remoteAddress = self.address(connection.endpoint)
      {
        let owner = InputBuffer(data)
        let retained = Unmanaged.passRetained(owner).toOpaque()
        let ecn = (context?.protocolMetadata(definition: NWProtocolIP.definition) as? NWProtocolIP.Metadata).map { self.ecnBits($0.ecn) } ?? 0
        _ = fz_completion_receive_network(session, generation, owner.data.bytes.assumingMemoryBound(to: UInt8.self), owner.data.length,
          localAddress, remoteAddress, ecn, retained, releaseInputBuffer)
        self.pump()
      }
      if error == nil { self.receive(connection, generation: generation) }
      else { connection.cancel() }
    }
  }

  private func readTun() {
    guard running, !stopping else { return }
    flow.readPackets { [weak self] packets, _ in
      guard let self else { return }
      self.queue.async {
        guard self.running, !self.stopping, let session = self.session else { return }
        // PacketTunnelFlow owns receive storage and does not accept supplied
        // buffers. Rust copies each plaintext packet once into its mutable pool.
        #if os(iOS)
          let capacity = 32
        #else
          let capacity = 96
        #endif
        for offset in stride(from: 0, to: packets.count, by: capacity) {
          let owners = packets[offset..<min(offset + capacity, packets.count)].map { $0 as NSData }
          let slices = owners.map { FzByteSlice(data: $0.bytes.assumingMemoryBound(to: UInt8.self), len: $0.length) }
          slices.withUnsafeBufferPointer { _ = fz_completion_receive_tun(session, self.generation, $0.baseAddress, $0.count) }
          withExtendedLifetime(owners) {}
        }
        self.pump()
        self.readTun()
      }
    }
  }

  private func handleEvent(_ data: Data) throws {
    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = event["kind"] as? String else { return }
    switch kind {
    case "tun_config":
      func routes(_ key: String) -> [NetworkSettings.Cidr] {
        (event[key] as? [[String: Any]] ?? []).compactMap { route in
          guard let address = route["address"] as? String, let prefix = route["prefix"] as? Int else { return nil }
          return NetworkSettings.Cidr(address: address, prefix: prefix)
        }
      }
      guard let payload = settings.updateTunInterface(ipv4: event["ipv4"] as? String,
        ipv6: event["ipv6"] as? String, dnsServers: event["dns"] as? [String] ?? [],
        searchDomain: event["search_domain"] as? String, routes4: routes("ipv4_routes"), routes6: routes("ipv6_routes")) else { return }
      provider.setTunnelNetworkSettings(payload.build()) { [weak self] error in
        guard let self else { return }
        self.queue.async {
          let callback = self.onStarted
          self.onStarted = nil
          callback?(error)
          if let error { self.fail(error) }
        }
      }
    case "disconnected": fail(CompletionError(event["error"] as? String ?? "Rust driver disconnected"))
    default: break
    }
  }

  private func endpoint(_ value: FzEndpoint) throws -> NWEndpoint {
    var value = value
    let family = value.family == 4 ? AF_INET : AF_INET6
    let address = withUnsafeBytes(of: &value.address) { bytes -> String? in
      var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      return inet_ntop(family, bytes.baseAddress, &text, socklen_t(text.count)).map { String(cString: $0) }
    }
    guard var address, let port = NWEndpoint.Port(rawValue: value.port) else { throw CompletionError("Invalid endpoint") }
    if value.scope_id != 0 { address += "%\(value.scope_id)" }
    return .hostPort(host: NWEndpoint.Host(address), port: port)
  }

  private func address(_ endpoint: NWEndpoint) -> FzEndpoint? {
    guard case .hostPort(let host, let port) = endpoint else { return nil }
    var address = FzEndpoint()
    guard "\(host)".withCString({ fz_completion_endpoint_parse($0, port.rawValue, &address) }) == 0 else { return nil }
    return address
  }

  private func ipMetadata(_ bits: UInt8) -> NWProtocolIP.Metadata {
    let metadata = NWProtocolIP.Metadata()
    switch bits { case 1: metadata.ecn = .ect1; case 2: metadata.ecn = .ect0; case 3: metadata.ecn = .ce; default: metadata.ecn = .nonECT }
    return metadata
  }
  private func ecnBits(_ ecn: NWProtocolIP.ECN) -> UInt8 {
    switch ecn { case .ect1: return 1; case .ect0: return 2; case .ce: return 3; default: return 0 }
  }
  private func driverError() -> Error {
    guard let session, let message = fz_completion_error(session) else { return CompletionError("Rust driver failed") }
    return CompletionError(String(cString: message))
  }
  private func fail(_ error: Error) {
    let callback = onStarted
    onStarted = nil
    callback?(error)
    destroy()
    provider.cancelTunnelWithError(error)
  }
  private func cancelConnections() {
    listeners.forEach { $0.cancel() }; listeners.removeAll()
    connections.values.forEach { $0.cancel() }; connections.removeAll()
  }
  private func destroy() {
    running = false
    timer?.cancel(); timer = nil
    pathMonitor.cancel()
    cancelConnections()
    if let session { fz_completion_free(session) }
    session = nil
    let callback = onStopped
    onStopped = nil
    callback?()
  }
}

private struct CompletionError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
private final class InputBuffer {
  let data: NSData
  init(_ data: Data) { self.data = data as NSData }
}
private func releaseInputBuffer(_ context: UnsafeMutableRawPointer?) {
  guard let context else { return }
  Unmanaged<InputBuffer>.fromOpaque(context).release()
}
private final class OutputBuffer: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { fz_completion_buffer_free(pointer) }
  func packet(_ index: Int) -> Data? {
    var bytes = FzByteSlice()
    guard fz_completion_packet(pointer, index, &bytes) == 0, let data = bytes.data else { return nil }
    return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: data), count: bytes.len,
      deallocator: .custom { [self] _, _ in withExtendedLifetime(self) {} })
  }
}
private final class SendCompletion: @unchecked Sendable {
  let id: UInt64
  var remaining: Int
  var failed = false
  init(id: UInt64, remaining: Int) { self.id = id; self.remaining = remaining }
}

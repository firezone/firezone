// (c) 2026 Firezone, Inc.
// LICENSE: Apache-2.0

import FirezoneKit
import Foundation
import Network
import NetworkExtension

/// All state and I/O submissions are serialized on `queue`.
final class NetworkFrameworkIo: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.firezone.completion", qos: .userInteractive)
  private let flow: NEPacketTunnelFlow
  private let onError: @Sendable (Error) -> Void
  private var session: OpaquePointer?
  private var started = false
  private var timer: DispatchSourceTimer?
  private var listeners: [NWListener] = []
  private var connections: [String: NetworkConnection] = [:]
  private var generation: UInt64 = 0
  private var running = false
  private var receivedNetwork: [NetworkInput?] = []
  private var networkOffset = 0
  private var pumpScheduled = false
  private var receivedTun: [Data] = []
  private var tunOffset = 0
  private var tunReadPending = false

  init(flow: NEPacketTunnelFlow, onError: @escaping @Sendable (Error) -> Void) {
    self.flow = flow
    self.onError = onError
  }

  func start(driver: PacketDriver) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        guard !self.started else {
          continuation.resume(throwing: CompletionError("Packet I/O already started"))
          return
        }
        self.started = true
        self.session = OpaquePointer(bitPattern: UInt(driver))
        self.running = true
        do { try self.bindListeners() } catch {
          self.destroy()
          continuation.resume(throwing: error)
          return
        }
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        // Packet callbacks schedule a pump; this timer services Rust portal and DNS timers.
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.requestPump() }
        self.timer = timer
        timer.resume()
        self.readTun()
        continuation.resume()
      }
    }
  }

  func stop() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async {
        self.destroy()
        continuation.resume()
      }
    }
  }

  private func requestPump() {
    guard running, !pumpScheduled else { return }
    pumpScheduled = true
    queue.async { [weak self] in
      guard let self else { return }
      self.pumpScheduled = false
      self.pump()
    }
  }

  private func pump() {
    guard running, let session else { return }
    drainInputs(session)
    guard self.session == session else { return }
    let status = fz_completion_poll(session)
    if status < 0 {
      fail(driverError())
      return
    }
    var operation = FzPacketOperation()
    while fz_completion_next_operation(session, &operation) == 0 {
      submit(operation)
      guard self.session == session else { return }
    }
    if status == 2 {
      destroy()
      return
    }
    // Rust may have freed input capacity during this poll. Yield between batches,
    // and wait for completions when its queues remain full.
    if networkOffset < receivedNetwork.count, fz_completion_receive_ready(session, true) == 0 {
      requestPump()
    } else if tunOffset < receivedTun.count, fz_completion_receive_ready(session, false) == 0 {
      requestPump()
    }
  }

  private func drainInputs(_ session: OpaquePointer) {
    var refill: [ObjectIdentifier: NetworkConnection] = [:]
    while networkOffset < receivedNetwork.count, fz_completion_receive_ready(session, true) == 0 {
      let input = receivedNetwork[networkOffset]
      receivedNetwork[networkOffset] = nil
      networkOffset += 1
      guard let input else { continue }
      input.connection.receives -= 1
      refill[ObjectIdentifier(input.connection)] = input.connection
      let owner = InputBuffer(input.packet.data)
      let retained = Unmanaged.passRetained(owner).toOpaque()
      let status = fz_completion_receive_network(
        session, generation,
        owner.data.bytes.assumingMemoryBound(to: UInt8.self), owner.data.length,
        input.packet.local, input.packet.remote, input.packet.ecn, retained, releaseInputBuffer)
      if status < 0 {
        fail(driverError())
        return
      }
    }
    if networkOffset == receivedNetwork.count {
      receivedNetwork.removeAll(keepingCapacity: true)
      networkOffset = 0
    } else if networkOffset >= 256, networkOffset >= receivedNetwork.count / 2 {
      receivedNetwork.removeFirst(networkOffset)
      networkOffset = 0
    }
    for connection in refill.values { receive(connection) }
    #if os(iOS)
      let capacity = 32
    #else
      let capacity = 96
    #endif
    while tunOffset < receivedTun.count, fz_completion_receive_ready(session, false) == 0 {
      let end = min(tunOffset + capacity, receivedTun.count)
      // swiftlint:disable:next legacy_objc_type - NSData keeps packet pointers stable through the FFI call.
      let owners = receivedTun[tunOffset..<end].map { $0 as NSData }
      let slices = owners.map {
        FzByteSlice(data: $0.bytes.assumingMemoryBound(to: UInt8.self), len: $0.length)
      }
      let status = slices.withUnsafeBufferPointer {
        fz_completion_receive_tun(session, generation, $0.baseAddress, $0.count)
      }
      withExtendedLifetime(owners) {}
      if status < 0 {
        fail(driverError())
        return
      }
      tunOffset = end
    }
    if tunOffset == receivedTun.count {
      receivedTun.removeAll(keepingCapacity: true)
      tunOffset = 0
      readTun()
    }
  }

  private func submit(_ operation: FzPacketOperation) {
    guard let session, let buffer = operation.buffer else { return }
    let owner = OutputBuffer(buffer)
    let driver = UInt(bitPattern: session)
    switch operation.kind {
    case 1:
      do {
        let connection = try connection(for: operation)
        let completion = SendCompletion(id: operation.id, remaining: operation.packets)
        connection.batch {
          for index in 0..<operation.packets {
            guard let data = owner.packet(index) else {
              fail(CompletionError("Invalid packet lease"))
              return
            }
            let context = NWConnection.ContentContext(
              identifier: "firezone", metadata: [ipMetadata(operation.ecn)])
            connection.send(
              content: data, contentContext: context,
              completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                completion.remaining -= 1
                completion.failed = completion.failed || error != nil
                if completion.remaining == 0, self.running, let current = self.session,
                  UInt(bitPattern: current) == driver
                {
                  _ = fz_completion_complete(current, completion.id, completion.failed ? -1 : 0)
                  self.requestPump()
                }
              })
          }
        }
      } catch {
        _ = fz_completion_complete(session, operation.id, -1)
        requestPump()
      }
    case 2:
      let packets = (0..<operation.packets).compactMap { owner.packet($0) }
      let families = packets.map { data in
        // swiftlint:disable:next legacy_objc_type - NEPacketTunnelFlow requires NSNumber protocol families.
        NSNumber(value: data.first.map { $0 >> 4 } == 6 ? AF_INET6 : AF_INET)
      }
      let accepted =
        packets.count == operation.packets && flow.writePackets(packets, withProtocols: families)
      _ = fz_completion_complete(session, operation.id, accepted ? 0 : -1)
      requestPump()
    case 3:
      generation = operation.generation
      receivedNetwork.removeAll()
      networkOffset = 0
      receivedTun.removeAll()
      tunOffset = 0
      cancelConnections()
      do {
        try bindListeners()
        _ = fz_completion_complete(session, operation.id, 0)
      } catch {
        _ = fz_completion_complete(session, operation.id, -1)
        fail(error)
      }
    default:
      _ = fz_completion_complete(session, operation.id, -1)
    }
  }

  private func bindListeners() throws {
    let listenerGeneration = generation
    for host in ["0.0.0.0", "::"] {
      let parameters = NWParameters.udp
      (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version =
        host == "::" ? .v6 : .v4
      parameters.allowLocalEndpointReuse = true
      parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: 52625)
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in
        guard let self, self.running, self.generation == listenerGeneration else {
          connection.cancel()
          return
        }
        guard self.connections.count < 256 else {
          connection.cancel()
          return
        }
        self.install(connection, key: "incoming:\(connection.endpoint)")
      }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self, self.running, self.generation == listenerGeneration else { return }
        if case .failed(let error) = state { self.fail(error) }
      }
      listeners.append(listener)
      listener.start(queue: queue)
    }
  }

  private func connection(for operation: FzPacketOperation) throws -> NWConnection {
    let remote = try endpoint(operation.remote)
    let local =
      operation.local.family == 0
      ? NWEndpoint.hostPort(
        host: NWEndpoint.Host(operation.remote.family == 4 ? "0.0.0.0" : "::"), port: 52625)
      : try endpoint(operation.local)
    let key = "\(local)>\(remote)"
    if let connection = connections[key] { return connection.connection }
    guard connections.count < 256 else { throw CompletionError("UDP connection capacity exceeded") }
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = local
    let connection = NWConnection(to: remote, using: parameters)
    install(connection, key: key)
    return connection
  }

  private func install(_ connection: NWConnection, key: String) {
    let state = NetworkConnection(
      connection: connection, key: key, generation: generation, remote: address(connection.endpoint)
    )
    connections[key] = state
    connection.pathUpdateHandler = { [weak self, weak state] path in
      guard let self, let state, self.running, self.generation == state.generation,
        !state.cancelled
      else { return }
      self.updatePath(path, for: state)
      self.receive(state)
    }
    connection.stateUpdateHandler = { [weak self, weak state] update in
      guard let self, let state, self.running, self.generation == state.generation,
        !state.cancelled
      else { return }
      switch update {
      case .ready:
        self.updatePath(state.connection.currentPath, for: state)
        state.ready = true
        self.receive(state)
      case .failed, .cancelled:
        self.cancel(state)
      case .waiting, .preparing:
        state.ready = false
      default: break
      }
    }
    connection.start(queue: queue)
  }

  private func updatePath(_ path: NWPath?, for state: NetworkConnection) {
    let local = path?.localEndpoint
    state.local = local.flatMap { address($0) }
    guard state.incoming, let local else { return }
    let canonical = "\(local)>\(state.connection.endpoint)"
    if let existing = connections[canonical], existing !== state {
      cancel(state)
      return
    }
    connections.removeValue(forKey: state.key)
    state.key = canonical
    connections[canonical] = state
  }

  private func cancel(_ state: NetworkConnection) {
    state.cancelled = true
    state.connection.cancel()
    if connections[state.key] === state { connections.removeValue(forKey: state.key) }
  }

  private func receive(_ state: NetworkConnection) {
    guard running, state.ready, !state.cancelled, generation == state.generation,
      state.local != nil, state.remote != nil, state.receives < NetworkConnection.receiveDepth
    else { return }
    // Credits cover outstanding callbacks and completed packets until Rust owns
    // their storage, keeping the receive window bounded under backpressure.
    state.connection.batch {
      while state.receives < NetworkConnection.receiveDepth {
        let sequence = state.nextReceive
        state.nextReceive &+= 1
        state.receives += 1
        state.connection.receiveMessage { [weak self, state] data, context, _, error in
          guard let self, self.running, self.generation == state.generation, self.session != nil
          else { return }
          var packet: NetworkPacket?
          if let data, !data.isEmpty, let local = state.local, let remote = state.remote {
            let ecn =
              (context?.protocolMetadata(definition: NWProtocolIP.definition)
              as? NWProtocolIP.Metadata)
              .map { self.ecnBits($0.ecn) } ?? 0
            packet = NetworkPacket(data: data, local: local, remote: remote, ecn: ecn)
          }
          if error != nil { self.cancel(state) }
          state.completed[sequence] = NetworkReceive(packet: packet)
          while let completed = state.completed.removeValue(forKey: state.nextDelivery) {
            state.nextDelivery &+= 1
            if let packet = completed.packet {
              self.receivedNetwork.append(NetworkInput(packet: packet, connection: state))
            } else {
              state.receives -= 1
            }
          }
          self.receive(state)
          self.requestPump()
        }
      }
    }
  }

  private func readTun() {
    guard running, !tunReadPending, receivedTun.isEmpty else { return }
    tunReadPending = true
    let readGeneration = generation
    flow.readPackets { [weak self] packets, _ in
      guard let self else { return }
      self.queue.async {
        self.tunReadPending = false
        guard self.running, self.session != nil else { return }
        guard self.generation == readGeneration else {
          self.readTun()
          return
        }
        // PacketTunnelFlow owns receive storage and does not accept supplied
        // buffers. Rust copies each plaintext packet once into its mutable pool.
        self.receivedTun = packets
        self.requestPump()
      }
    }
  }

  private func endpoint(_ value: FzEndpoint) throws -> NWEndpoint {
    var value = value
    let family = value.family == 4 ? AF_INET : AF_INET6
    let address = withUnsafeBytes(of: &value.address) { bytes -> String? in
      var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      return inet_ntop(family, bytes.baseAddress, &text, socklen_t(text.count)).map {
        String(cString: $0)
      }
    }
    guard var address, let port = NWEndpoint.Port(rawValue: value.port) else {
      throw CompletionError("Invalid endpoint")
    }
    if value.scope_id != 0 { address += "%\(value.scope_id)" }
    return .hostPort(host: NWEndpoint.Host(address), port: port)
  }

  private func address(_ endpoint: NWEndpoint) -> FzEndpoint? {
    guard case .hostPort(let host, let port) = endpoint else { return nil }
    var address = FzEndpoint()
    guard "\(host)".withCString({ fz_completion_endpoint_parse($0, port.rawValue, &address) }) == 0
    else { return nil }
    return address
  }

  private func ipMetadata(_ bits: UInt8) -> NWProtocolIP.Metadata {
    let metadata = NWProtocolIP.Metadata()
    switch bits {
    case 1: metadata.ecn = .ect1
    case 2: metadata.ecn = .ect0
    case 3: metadata.ecn = .ce
    default: metadata.ecn = .nonECT
    }
    return metadata
  }
  private func ecnBits(_ ecn: NWProtocolIP.ECN) -> UInt8 {
    switch ecn {
    case .ect1: return 1
    case .ect0: return 2
    case .ce: return 3
    default: return 0
    }
  }
  private func driverError() -> Error {
    guard let session, let message = fz_completion_error(session) else {
      return CompletionError("Rust driver failed")
    }
    return CompletionError(String(cString: message))
  }
  private func fail(_ error: Error) {
    destroy()
    onError(error)
  }
  private func cancelConnections() {
    for listener in listeners {
      listener.cancel()
    }
    listeners.removeAll()
    for state in connections.values {
      state.cancelled = true
      state.completed.removeAll()
      state.connection.cancel()
    }
    connections.removeAll()
  }
  private func destroy() {
    running = false
    timer?.cancel()
    timer = nil
    cancelConnections()
    receivedNetwork.removeAll()
    networkOffset = 0
    receivedTun.removeAll()
    if let session { fz_completion_free(session) }
    session = nil
  }
}

/// Mutated only on the packet I/O queue, including Network.framework callbacks.
private final class NetworkConnection: @unchecked Sendable {
  static let receiveDepth = 16
  let connection: NWConnection
  let generation: UInt64
  let incoming: Bool
  let remote: FzEndpoint?
  var key: String
  var local: FzEndpoint?
  var ready = false
  var cancelled = false
  var receives = 0
  var nextReceive: UInt64 = 0
  var nextDelivery: UInt64 = 0
  var completed: [UInt64: NetworkReceive] = [:]

  init(connection: NWConnection, key: String, generation: UInt64, remote: FzEndpoint?) {
    self.connection = connection
    self.key = key
    self.incoming = key.hasPrefix("incoming:")
    self.generation = generation
    self.remote = remote
  }
}

private struct NetworkReceive {
  let packet: NetworkPacket?
}

private struct NetworkInput {
  let packet: NetworkPacket
  let connection: NetworkConnection
}

private struct NetworkPacket {
  let data: Data
  let local: FzEndpoint
  let remote: FzEndpoint
  let ecn: UInt8
}

private struct CompletionError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
private final class InputBuffer {
  // swiftlint:disable:next legacy_objc_type - NSData retains the bytes borrowed by Rust until the lease is released.
  let data: NSData
  // swiftlint:disable:next legacy_objc_type - NSData retains the bytes borrowed by Rust until the lease is released.
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
    guard fz_completion_packet(pointer, index, &bytes) == 0, let data = bytes.data else {
      return nil
    }
    return Data(
      bytesNoCopy: UnsafeMutableRawPointer(mutating: data), count: bytes.len,
      deallocator: .custom { [self] _, _ in withExtendedLifetime(self) {} })
  }
}
private final class SendCompletion: @unchecked Sendable {
  let id: UInt64
  var remaining: Int
  var failed = false
  init(id: UInt64, remaining: Int) {
    self.id = id
    self.remaining = remaining
  }
}

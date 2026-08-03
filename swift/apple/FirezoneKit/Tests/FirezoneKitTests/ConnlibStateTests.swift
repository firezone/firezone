//
//  ConnlibStateTests.swift
//  © 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("ConnlibState Tests")
struct ConnlibStateTests {
  @Test("State round-trips through a property list")
  func stateRoundTrip() throws {
    let state = ConnlibState(
      resources: [makeTestResource(id: "resource-1", name: "Resource A")],
      connectedDevices: [makeTestConnectedDevice(id: "device-1")],
      isLogStreamingActive: true
    )

    let decoded = try roundTrip(state)

    #expect(decoded.resources?.first?.id == "resource-1")
    #expect(decoded.connectedDevices.first?.id == "device-1")
    #expect(decoded.isLogStreamingActive)
  }

  @Test("State round-trips nil resources")
  func nilResourcesRoundTrip() throws {
    let state = ConnlibState(
      resources: nil,
      connectedDevices: [],
      isLogStreamingActive: false
    )

    let decoded = try roundTrip(state)

    #expect(decoded.resources == nil)
  }

  @Test("Connected-device fields round-trip")
  func connectedDeviceFieldsRoundTrip() throws {
    let state = ConnlibState(
      resources: nil,
      connectedDevices: [makeTestConnectedDevice(id: "device-1")],
      isLogStreamingActive: false
    )

    let device = try #require(roundTrip(state).connectedDevices.first)

    #expect(device.id == "device-1")
    #expect(device.name == "Device device-1")
    #expect(device.tunIPv4 == "100.64.0.1")
    #expect(device.tunIPv6 == "fd00:2021:1111::1")
    #expect(device.pools == ["pool-a"])
  }

  @Test("Identical state has an identical content hash")
  func identicalStateHash() throws {
    let first = ConnlibState(
      resources: [makeTestResource(id: "resource-1", name: "Resource A")],
      connectedDevices: [],
      isLogStreamingActive: false
    )
    let second = ConnlibState(
      resources: [makeTestResource(id: "resource-1", name: "Resource A")],
      connectedDevices: [],
      isLogStreamingActive: false
    )

    #expect(try first.contentHash() == second.contentHash())
    #expect(try first.contentHash().count == 32)
  }

  @Test("Resource changes alter the content hash")
  func resourceChangeAltersHash() throws {
    let first = ConnlibState(
      resources: [makeTestResource(id: "resource-1", name: "Resource A")],
      connectedDevices: [],
      isLogStreamingActive: false
    )
    let second = ConnlibState(
      resources: [makeTestResource(id: "resource-2", name: "Resource B")],
      connectedDevices: [],
      isLogStreamingActive: false
    )

    #expect(try first.contentHash() != second.contentHash())
  }

  @Test("Connected-device changes alter the content hash")
  func connectedDeviceChangeAltersHash() throws {
    let first = ConnlibState(
      resources: nil,
      connectedDevices: [],
      isLogStreamingActive: false
    )
    let second = ConnlibState(
      resources: nil,
      connectedDevices: [makeTestConnectedDevice(id: "device-1")],
      isLogStreamingActive: false
    )

    #expect(try first.contentHash() != second.contentHash())
  }

  @Test("Log-streaming changes alter the content hash")
  func logStreamingChangeAltersHash() throws {
    let first = ConnlibState(
      resources: nil,
      connectedDevices: [],
      isLogStreamingActive: false
    )
    let second = ConnlibState(
      resources: nil,
      connectedDevices: [],
      isLogStreamingActive: true
    )

    #expect(try first.contentHash() != second.contentHash())
  }

  @Test("Poll response round-trips state and notifications independently")
  func pollResponseRoundTrip() throws {
    let state = ConnlibState(
      resources: [makeTestResource(id: "resource-1", name: "Resource A")],
      connectedDevices: [],
      isLogStreamingActive: false
    )
    let hash = try state.contentHash()
    let response = StatePollResponse(
      state: state,
      stateHash: hash,
      notifications: [UnreachableResource(resourceId: "resource-1", reason: .offline)]
    )

    let decoded = try roundTrip(response)

    #expect(decoded.state?.resources?.first?.id == "resource-1")
    #expect(decoded.stateHash == hash)
    #expect(
      decoded.notifications == [
        UnreachableResource(resourceId: "resource-1", reason: .offline)
      ])
  }

  @Test("Poll response can contain notifications without a state change")
  func pollResponseWithoutState() throws {
    let response = StatePollResponse(
      state: nil,
      stateHash: nil,
      notifications: [
        UnreachableResource(resourceId: "resource-1", reason: .versionMismatch)
      ]
    )

    let decoded = try roundTrip(response)

    #expect(decoded.state == nil)
    #expect(decoded.stateHash == nil)
    #expect(decoded.notifications.count == 1)
  }

  private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try PropertyListEncoder().encode(value)
    return try PropertyListDecoder().decode(T.self, from: data)
  }

  private func makeTestResource(id: String, name: String) -> FirezoneKit.Resource {
    let site = Site(id: "site-1", name: "Test Site")
    return FirezoneKit.Resource(
      id: id,
      name: name,
      address: "10.0.0.1",
      addressDescription: "Test Address",
      status: .online,
      sites: [site],
      type: .dns
    )
  }

  private func makeTestConnectedDevice(id: String) -> FirezoneKit.ConnectedDevice {
    FirezoneKit.ConnectedDevice(
      id: id,
      name: "Device \(id)",
      tunIPv4: "100.64.0.1",
      tunIPv6: "fd00:2021:1111::1",
      pools: ["pool-a"]
    )
  }
}

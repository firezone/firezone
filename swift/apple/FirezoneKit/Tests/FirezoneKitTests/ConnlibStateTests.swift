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

  // MARK: - decode() Tests

  @Test("decode() returns state and hash")
  func decodeReturnsStateAndHash() throws {
    let resource = makeTestResource(id: "1", name: "Resource A")
    let unreachable = UnreachableResource(resourceId: "2", reason: .offline)

    // Use encodeIfChanged with empty hash to get initial data
    let data = try ConnlibState.encodeIfChanged(
      resources: [resource],
      unreachableResources: [unreachable],
      comparedTo: Data()
    )

    let (decodedState, hash) = try ConnlibState.decode(from: data!)

    #expect(hash.count == 32)  // SHA256 hash size
    #expect(decodedState.resources?.count == 1)
    #expect(decodedState.resources?[0].id == "1")
    #expect(decodedState.unreachableResources.count == 1)
  }

  @Test("decode() produces same hash for identical content")
  func decodeSameHashForIdenticalContent() throws {
    let resource = makeTestResource(id: "1", name: "Resource A")

    let data1 = try ConnlibState.encodeIfChanged(
      resources: [resource],
      unreachableResources: [],
      comparedTo: Data()
    )

    let data2 = try ConnlibState.encodeIfChanged(
      resources: [resource],
      unreachableResources: [],
      comparedTo: Data()
    )

    let (_, hash1) = try ConnlibState.decode(from: data1!)
    let (_, hash2) = try ConnlibState.decode(from: data2!)

    #expect(hash1 == hash2)
  }

  @Test("decode() produces different hash for different content")
  func decodeDifferentHashForDifferentContent() throws {
    let resource1 = makeTestResource(id: "1", name: "Resource A")
    let resource2 = makeTestResource(id: "2", name: "Resource B")

    let data1 = try ConnlibState.encodeIfChanged(
      resources: [resource1],
      unreachableResources: [],
      comparedTo: Data()
    )

    let data2 = try ConnlibState.encodeIfChanged(
      resources: [resource2],
      unreachableResources: [],
      comparedTo: Data()
    )

    let (_, hash1) = try ConnlibState.decode(from: data1!)
    let (_, hash2) = try ConnlibState.decode(from: data2!)

    #expect(hash1 != hash2)
  }

  // MARK: - encodeIfChanged() Tests

  @Test("encodeIfChanged() returns nil when hash matches")
  func encodeIfChangedReturnsNilWhenHashMatches() throws {
    let resource = makeTestResource(id: "1", name: "Resource A")
    let unreachable = UnreachableResource(resourceId: "2", reason: .offline)

    // First encode to get the hash
    let data = try ConnlibState.encodeIfChanged(
      resources: [resource],
      unreachableResources: [unreachable],
      comparedTo: Data()
    )

    let (_, hash) = try ConnlibState.decode(from: data!)

    // Now try to encode again with the same hash
    let result = try ConnlibState.encodeIfChanged(
      resources: [resource],
      unreachableResources: [unreachable],
      comparedTo: hash
    )

    #expect(result == nil)
  }

  @Test("encodeIfChanged() returns data when hash differs")
  func encodeIfChangedReturnsDataWhenHashDiffers() throws {
    let resource1 = makeTestResource(id: "1", name: "Resource A")
    let resource2 = makeTestResource(id: "2", name: "Resource B")

    // Get hash for first state
    let data1 = try ConnlibState.encodeIfChanged(
      resources: [resource1],
      unreachableResources: [],
      comparedTo: Data()
    )

    let (_, hash1) = try ConnlibState.decode(from: data1!)

    // Try to encode different state with first hash
    let result = try ConnlibState.encodeIfChanged(
      resources: [resource2],
      unreachableResources: [],
      comparedTo: hash1
    )

    #expect(result != nil)

    let (decoded, _) = try ConnlibState.decode(from: result!)
    #expect(decoded.resources?.count == 1)
    #expect(decoded.resources?[0].id == "2")
  }

  @Test("encodeIfChanged() handles nil resources")
  func encodeIfChangedHandlesNilResources() throws {
    let result = try ConnlibState.encodeIfChanged(
      resources: nil,
      unreachableResources: [],
      comparedTo: Data()
    )

    #expect(result != nil)

    let (decoded, _) = try ConnlibState.decode(from: result!)
    #expect(decoded.resources == nil)
    #expect(decoded.unreachableResources.isEmpty)
  }

  // MARK: - Set Ordering Tests

  @Test("Unreachable resources set order doesn't affect hash")
  func unreachableResourcesOrderIndependent() throws {
    let unreachable1 = UnreachableResource(resourceId: "1", reason: .offline)
    let unreachable2 = UnreachableResource(resourceId: "2", reason: .versionMismatch)
    let unreachable3 = UnreachableResource(resourceId: "3", reason: .offline)

    // Create sets with elements inserted in different orders
    let set1: Set<UnreachableResource> = [unreachable1, unreachable2, unreachable3]
    let set2: Set<UnreachableResource> = [unreachable3, unreachable1, unreachable2]

    let data1 = try ConnlibState.encodeIfChanged(
      resources: [],
      unreachableResources: set1,
      comparedTo: Data()
    )

    let data2 = try ConnlibState.encodeIfChanged(
      resources: [],
      unreachableResources: set2,
      comparedTo: Data()
    )

    let (_, hash1) = try ConnlibState.decode(from: data1!)
    let (_, hash2) = try ConnlibState.decode(from: data2!)

    #expect(hash1 == hash2)
  }

  // MARK: - Helper Functions

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
}

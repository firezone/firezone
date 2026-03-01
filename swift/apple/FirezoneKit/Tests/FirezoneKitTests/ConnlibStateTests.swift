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
      isLogStreamingActive: false,
      comparedTo: Data()
    )

    let unwrappedData = try #require(data)
    let decoded = try ConnlibState.decode(from: unwrappedData)

    #expect(decoded.hash.count == 32)  // SHA256 hash size
    #expect(decoded.resources?.count == 1)
    #expect(decoded.resources?[0].id == "1")
    #expect(decoded.unreachableResources.count == 1)
  }

  @Test("decode() produces same hash for identical content")
  func decodeSameHashForIdenticalContent() throws {
    let resource = makeTestResource(id: "1", name: "Resource A")

    let data1 = try ConnlibState.encodeIfChanged(
      resources: [resource],
      unreachableResources: [],
      isLogStreamingActive: false,
      comparedTo: Data()
    )

    let data2 = try ConnlibState.encodeIfChanged(
      resources: [resource],
      unreachableResources: [],
      isLogStreamingActive: false,
      comparedTo: Data()
    )

    let unwrappedData1 = try #require(data1)
    let unwrappedData2 = try #require(data2)
    let decoded1 = try ConnlibState.decode(from: unwrappedData1)
    let decoded2 = try ConnlibState.decode(from: unwrappedData2)

    #expect(decoded1.hash == decoded2.hash)
  }

  @Test("decode() produces different hash for different content")
  func decodeDifferentHashForDifferentContent() throws {
    let resource1 = makeTestResource(id: "1", name: "Resource A")
    let resource2 = makeTestResource(id: "2", name: "Resource B")

    let data1 = try ConnlibState.encodeIfChanged(
      resources: [resource1],
      unreachableResources: [],
      isLogStreamingActive: false,
      comparedTo: Data()
    )

    let data2 = try ConnlibState.encodeIfChanged(
      resources: [resource2],
      unreachableResources: [],
      isLogStreamingActive: false,
      comparedTo: Data()
    )

    let unwrappedData1 = try #require(data1)
    let unwrappedData2 = try #require(data2)
    let decoded1 = try ConnlibState.decode(from: unwrappedData1)
    let decoded2 = try ConnlibState.decode(from: unwrappedData2)

    #expect(decoded1.hash != decoded2.hash)
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
      isLogStreamingActive: false,
      comparedTo: Data()
    )

    let unwrappedData = try #require(data)
    let decoded = try ConnlibState.decode(from: unwrappedData)

    // Now try to encode again with the same hash
    let result = try ConnlibState.encodeIfChanged(
      resources: [resource],
      unreachableResources: [unreachable],
      isLogStreamingActive: false,
      comparedTo: decoded.hash
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
      isLogStreamingActive: false,
      comparedTo: Data()
    )

    let unwrappedData1 = try #require(data1)
    let decoded1 = try ConnlibState.decode(from: unwrappedData1)

    // Try to encode different state with first hash
    let result = try ConnlibState.encodeIfChanged(
      resources: [resource2],
      unreachableResources: [],
      isLogStreamingActive: false,
      comparedTo: decoded1.hash
    )

    #expect(result != nil)

    let unwrappedResult = try #require(result)
    let decoded = try ConnlibState.decode(from: unwrappedResult)
    #expect(decoded.resources?.count == 1)
    #expect(decoded.resources?[0].id == "2")
  }

  @Test("encodeIfChanged() handles nil resources")
  func encodeIfChangedHandlesNilResources() throws {
    let result = try ConnlibState.encodeIfChanged(
      resources: nil,
      unreachableResources: [],
      isLogStreamingActive: false,
      comparedTo: Data()
    )

    #expect(result != nil)

    let unwrappedResult = try #require(result)
    let decoded = try ConnlibState.decode(from: unwrappedResult)
    #expect(decoded.resources == nil)
    #expect(decoded.unreachableResources.isEmpty)
  }

  // MARK: - isLogStreamingActive Tests

  @Test("decode() round-trips isLogStreamingActive = true")
  func decodeRoundTripsLogStreamingActive() throws {
    let data = try ConnlibState.encodeIfChanged(
      resources: nil,
      unreachableResources: [],
      isLogStreamingActive: true,
      comparedTo: Data()
    )

    let unwrapped = try #require(data)
    let decoded = try ConnlibState.decode(from: unwrapped)

    #expect(decoded.isLogStreamingActive == true)
  }

  @Test("encodeIfChanged() detects isLogStreamingActive change")
  func encodeIfChangedDetectsLogStreamingChange() throws {
    let data = try ConnlibState.encodeIfChanged(
      resources: nil,
      unreachableResources: [],
      isLogStreamingActive: false,
      comparedTo: Data()
    )

    let unwrapped = try #require(data)
    let decoded = try ConnlibState.decode(from: unwrapped)

    // Same resources, different streaming flag — should return data
    let result = try ConnlibState.encodeIfChanged(
      resources: nil,
      unreachableResources: [],
      isLogStreamingActive: true,
      comparedTo: decoded.hash
    )

    #expect(result != nil)
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

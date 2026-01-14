//
//  StoreResourceFetchTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("Store Resource Fetch Tests")
struct StoreResourceFetchTests {

  // MARK: - Basic Fetch Tests

  @Test("Immediate success populates resources")
  @MainActor
  func immediateSuccessPopulatesResources() async throws {
    let resources = [makeResource(id: "res-1", name: "My Resource")]
    let fixture = makeMockStore { controller, _ in
      controller.fetchResourcesResponse = try! encodeResources(resources)
    }

    try await fixture.store.fetchResources()

    #expect(fixture.controller.fetchResourcesCallCount == 1)

    if case .loaded(let loadedResources) = fixture.store.resourceList {
      #expect(loadedResources.count == 1)
      #expect(loadedResources[0].id == "res-1")
      #expect(loadedResources[0].name == "My Resource")
    } else {
      Issue.record("Expected state to be .loaded after successful fetch")
    }
  }

  // MARK: - Hash-Based Optimization Tests

  @Test("First fetch populates resources from loading to loaded")
  @MainActor
  func firstFetchPopulatesResources() async throws {
    let resources = [
      makeResource(id: "1", name: "Resource One", address: "one.example.com"),
      makeResource(id: "2", name: "Resource Two", address: "two.example.com"),
    ]
    let fixture = makeMockStore { controller, _ in
      controller.fetchResourcesResponse = try! encodeResources(resources)
    }

    if case .loading = fixture.store.resourceList {
      // Expected
    } else {
      Issue.record("Expected resourceList to be .loading initially")
    }

    try await fixture.store.fetchResources()

    if case .loaded(let loadedResources) = fixture.store.resourceList {
      #expect(loadedResources.count == 2)
      #expect(loadedResources[0].id == "1")
      #expect(loadedResources[0].name == "Resource One")
      #expect(loadedResources[1].id == "2")
      #expect(loadedResources[1].name == "Resource Two")
    } else {
      Issue.record("Expected resourceList to be .loaded after fetch")
    }
  }

  @Test("Unchanged resources return nil via hash comparison")
  @MainActor
  func unchangedResourcesReturnNil() async throws {
    let resources = [makeResource(id: "1", name: "Original Resource")]
    let fixture = makeMockStore { controller, _ in
      controller.simulateHashBehavior = true
      controller.fetchResourcesResponse = try! encodeResources(resources)
    }

    try await fixture.store.fetchResources()
    #expect(fixture.controller.fetchResourcesCallCount == 1)

    if case .loaded(let loaded) = fixture.store.resourceList {
      #expect(loaded.count == 1)
      #expect(loaded[0].name == "Original Resource")
    } else {
      Issue.record("Expected .loaded after first fetch")
    }

    // Second fetch: hash matches, returns nil
    try await fixture.store.fetchResources()
    #expect(fixture.controller.fetchResourcesCallCount == 2)

    if case .loaded(let loaded) = fixture.store.resourceList {
      #expect(loaded.count == 1)
      #expect(loaded[0].name == "Original Resource")
    } else {
      Issue.record("Expected resourceList to remain .loaded")
    }
  }

  @Test("Changed resources detected via hash comparison")
  @MainActor
  func changedResourcesDetectedViaHash() async throws {
    let initialResources = [makeResource(id: "1", name: "Initial Resource")]
    let fixture = makeMockStore { controller, _ in
      controller.simulateHashBehavior = true
      controller.fetchResourcesResponse = try! encodeResources(initialResources)
    }

    try await fixture.store.fetchResources()

    if case .loaded(let loaded) = fixture.store.resourceList {
      #expect(loaded.count == 1)
      #expect(loaded[0].name == "Initial Resource")
    } else {
      Issue.record("Expected .loaded after first fetch")
    }

    // Change the server-side data
    let updatedResources = [
      makeResource(id: "1", name: "Updated Resource"),
      makeResource(id: "2", name: "New Resource"),
    ]
    fixture.controller.fetchResourcesResponse = try encodeResources(updatedResources)

    try await fixture.store.fetchResources()

    #expect(fixture.controller.fetchResourcesCallCount == 2)

    if case .loaded(let loaded) = fixture.store.resourceList {
      #expect(loaded.count == 2)
      #expect(loaded[0].name == "Updated Resource")
      #expect(loaded[1].name == "New Resource")
    } else {
      Issue.record("Expected resourceList to be updated")
    }
  }

  @Test("Resources reset on VPN disconnect")
  @MainActor
  func resourcesResetOnDisconnect() async throws {
    let resources = [makeResource(id: "1", name: "Test Resource")]
    let fixture = makeMockStore { controller, _ in
      controller.fetchResourcesResponse = try! encodeResources(resources)
    }

    try await fixture.store.fetchResources()

    if case .loaded(let loaded) = fixture.store.resourceList {
      #expect(loaded.count == 1)
    } else {
      Issue.record("Expected .loaded after fetch")
    }

    let fetchCountBeforeDisconnect = fixture.controller.fetchResourcesCallCount

    try await fixture.controller.simulateStatusChange(.disconnected)

    if case .loading = fixture.store.resourceList {
      // Expected
    } else {
      Issue.record("Expected resourceList to be .loading after disconnect")
    }

    fixture.controller.fetchResourcesResponse = try encodeResources(resources)

    try await fixture.controller.simulateStatusChange(.connected)
    try await fixture.store.fetchResources()

    if case .loaded(let loaded) = fixture.store.resourceList {
      #expect(loaded.count == 1)
    } else {
      Issue.record("Expected .loaded after reconnect and fetch")
    }

    #expect(fixture.controller.fetchResourcesCallCount > fetchCountBeforeDisconnect)
  }
}

//
//  StoreResourceTimerTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("Store Resource Timer Lifecycle Tests")
struct StoreResourceTimerTests {

  @Test("Timer starts on connected status - resource fetching begins")
  @MainActor
  func timerStartsOnConnected() async throws {
    let resources = [makeResource(id: "1", name: "Test Resource")]
    let fixture = makeMockStore { controller, _ in
      controller.fetchResourcesResponse = try! encodeResources(resources)
    }

    #expect(fixture.controller.fetchResourcesCallCount == 0)

    try await fixture.controller.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(fixture.controller.fetchResourcesCallCount >= 1)

    let initialCount = fixture.controller.fetchResourcesCallCount
    try await Task.sleep(nanoseconds: 1_100_000_000)

    #expect(fixture.controller.fetchResourcesCallCount > initialCount)

    withExtendedLifetime(fixture.store) {}
  }

  @Test("Timer stops on disconnected status - resource fetching stops")
  @MainActor
  func timerStopsOnDisconnected() async throws {
    let resources = [makeResource(id: "1", name: "Test Resource")]
    let fixture = makeMockStore { controller, _ in
      controller.fetchResourcesResponse = try! encodeResources(resources)
    }

    try await fixture.controller.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)

    let countAfterConnect = fixture.controller.fetchResourcesCallCount
    #expect(countAfterConnect >= 1)

    try await fixture.controller.simulateStatusChange(.disconnected)
    let countAfterDisconnect = fixture.controller.fetchResourcesCallCount

    try await Task.sleep(nanoseconds: 1_500_000_000)

    #expect(fixture.controller.fetchResourcesCallCount == countAfterDisconnect)

    withExtendedLifetime(fixture.store) {}
  }

  @Test("Timer stops on connecting status - resource fetching stops during reconnection")
  @MainActor
  func timerStopsOnConnecting() async throws {
    let resources = [makeResource(id: "1", name: "Test Resource")]
    let fixture = makeMockStore { controller, _ in
      controller.fetchResourcesResponse = try! encodeResources(resources)
    }

    try await fixture.controller.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)

    let countAfterConnect = fixture.controller.fetchResourcesCallCount
    #expect(countAfterConnect >= 1)

    try await fixture.controller.simulateStatusChange(.connecting)
    let countAfterConnecting = fixture.controller.fetchResourcesCallCount

    try await Task.sleep(nanoseconds: 1_500_000_000)

    #expect(fixture.controller.fetchResourcesCallCount == countAfterConnecting)

    withExtendedLifetime(fixture.store) {}
  }

  @Test("No duplicate timers when connected status sent twice")
  @MainActor
  func noDuplicateTimersOnDoubleConnected() async throws {
    let resources = [makeResource(id: "1", name: "Test Resource")]
    let fixture = makeMockStore { controller, _ in
      controller.fetchResourcesResponse = try! encodeResources(resources)
    }

    try await fixture.controller.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 50_000_000)
    try await fixture.controller.simulateStatusChange(.connected)

    try await Task.sleep(nanoseconds: 100_000_000)

    let countAfterDoubleConnect = fixture.controller.fetchResourcesCallCount
    #expect(countAfterDoubleConnect == 1)

    try await Task.sleep(nanoseconds: 1_100_000_000)

    let countAfterOneSecond = fixture.controller.fetchResourcesCallCount
    let callsInInterval = countAfterOneSecond - countAfterDoubleConnect

    #expect(callsInInterval >= 1)
    #expect(callsInInterval <= 2)

    withExtendedLifetime(fixture.store) {}
  }

  @Test("Timer restarts after disconnect then reconnect")
  @MainActor
  func timerRestartsAfterReconnect() async throws {
    let resources = [makeResource(id: "1", name: "Test Resource")]
    let fixture = makeMockStore { controller, _ in
      controller.fetchResourcesResponse = try! encodeResources(resources)
    }

    try await fixture.controller.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)

    let countAfterFirstConnect = fixture.controller.fetchResourcesCallCount
    #expect(countAfterFirstConnect >= 1)

    try await fixture.controller.simulateStatusChange(.disconnected)
    let countAfterDisconnect = fixture.controller.fetchResourcesCallCount

    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(fixture.controller.fetchResourcesCallCount == countAfterDisconnect)

    try await fixture.controller.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(fixture.controller.fetchResourcesCallCount > countAfterDisconnect)

    let countAfterReconnect = fixture.controller.fetchResourcesCallCount
    try await Task.sleep(nanoseconds: 1_100_000_000)
    #expect(fixture.controller.fetchResourcesCallCount > countAfterReconnect)

    withExtendedLifetime(fixture.store) {}
  }
}

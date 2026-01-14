//
//  TestHelpers.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

@testable import FirezoneKit

/// Creates an isolated UserDefaults suite for test isolation.
///
/// Each call returns a unique suite that won't interfere with other tests.
func makeTestDefaults() -> UserDefaults {
  let suiteName = "dev.firezone.firezone.tests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.removePersistentDomain(forName: suiteName)
  return defaults
}

/// Creates a test Resource with default values for non-essential fields.
func makeResource(
  id: String = UUID().uuidString,
  name: String = "Test Resource",
  address: String? = "test.example.com",
  type: ResourceType = .dns
) -> Resource {
  Resource(
    id: id,
    name: name,
    address: address,
    addressDescription: nil,
    status: .online,
    sites: [],
    type: type
  )
}

/// Encodes resources to PropertyList data.
func encodeResources(_ resources: [Resource]) throws -> Data {
  try PropertyListEncoder().encode(resources)
}

// MARK: - Mock Store Fixture

/// Contains all components needed for Store tests.
///
/// Use `makeMockStore()` to create this fixture with sensible defaults.
/// Access individual components to configure mocks or verify interactions.
struct MockStoreFixture {
  let store: Store
  let controller: MockTunnelController
  let config: Configuration
  let defaults: UserDefaults
  let notification: MockSessionNotification

  #if os(macOS)
    let systemExtension: MockSystemExtensionManager
  #endif
}

/// Creates a fully mocked Store with all dependencies.
///
/// - Parameter configureController: Optional closure to configure the mock controller before Store init.
/// - Returns: A fixture containing the Store and all its mock dependencies.
@MainActor
func makeMockStore(
  configure: ((MockTunnelController, Configuration) -> Void)? = nil
) -> MockStoreFixture {
  let defaults = makeTestDefaults()
  let config = Configuration(userDefaults: defaults)
  let controller = MockTunnelController()
  let notification = MockSessionNotification()

  configure?(controller, config)

  #if os(macOS)
    let systemExtension = MockSystemExtensionManager()
    let store = Store(
      configuration: config,
      tunnelController: controller,
      sessionNotification: notification,
      systemExtensionManager: systemExtension,
      userDefaults: defaults
    )
    return MockStoreFixture(
      store: store,
      controller: controller,
      config: config,
      defaults: defaults,
      notification: notification,
      systemExtension: systemExtension
    )
  #else
    let store = Store(
      configuration: config,
      tunnelController: controller,
      sessionNotification: notification,
      userDefaults: defaults
    )
    return MockStoreFixture(
      store: store,
      controller: controller,
      config: config,
      defaults: defaults,
      notification: notification
    )
  #endif
}

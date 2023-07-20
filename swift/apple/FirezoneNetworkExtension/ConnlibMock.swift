//
//  ConnlibMock.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0

// A mock for connlib

import Foundation

protocol ConnlibMockAdapterDelegate: AnyObject {
  func onConnected(interfaceAddresses: ConnlibMock.InterfaceAddresses)
  func onUpdateResources(resources: [ConnlibMock.Resource])
  func onDisconnect()
}

class ConnlibMock {
  public struct InterfaceAddresses {
    let ipv4: String
    let ipv6: String
  }

  public struct Resource {
    enum ResourceLocation {
      case dns(domain: String, ipv4: String, ipv6: String)
      case cidr(addressRange: String)
    }

    let name: String
    let resourceLocation: ResourceLocation
  }

  enum AdapterError : Error {
  }

  class Adapter {
    private let queue = DispatchQueue(label: "ConnlibMock.Adapter")
    private var packetTunnelProvider: PacketTunnelProvider?

    var delegate: ConnlibMockAdapterDelegate?
    var resourceIndex = 0
    var isResourceUpdatesEnabled = false

    init(with packetTunnelProvider: PacketTunnelProvider) {
      self.packetTunnelProvider = packetTunnelProvider
    }

    func start(portalURL: String, token: String) {
      isResourceUpdatesEnabled = true
      queue.asyncAfter(deadline: DispatchTime.now() + .milliseconds(500)) { [weak self] in
        self?.delegate?.onConnected(interfaceAddresses: MockData.mockInterfaceAddress)
        self?.queue.asyncAfter(deadline: DispatchTime.now() + .seconds(2)) { [weak self] in
          self?.updateResources()
        }
      }
    }

    func stop() {
      isResourceUpdatesEnabled = false
    }

    private func nextMockResourceData() -> ([Resource], DispatchTimeInterval) {
      let resourceSet = MockData.mockResourceSets[resourceIndex]
      resourceIndex = (resourceIndex + 1) % MockData.mockResourceSets.count
      return resourceSet
    }

    private func updateResources() {
      guard isResourceUpdatesEnabled else { return }
      let (resources, timeInterval) = self.nextMockResourceData()
      delegate?.onUpdateResources(resources: resources)
      queue.asyncAfter(deadline: DispatchTime.now() + timeInterval) { [weak self] in
        self?.updateResources()
      }
    }
  }
}

extension ConnlibMock {
  struct MockData {
    static let mockInterfaceAddress = InterfaceAddresses(ipv4: "100.100.111.2", ipv6: "fd00:0222:2021:1111::2")
    static let mockResourceSets: [([Resource], DispatchTimeInterval)] = [
      // The set of resources avaiable, and for how long does the set last (after which the next set becomes live)
      ([Resource(name: "PostHog", resourceLocation: .dns(domain: "app.posthog.com", ipv4: "100.64.1.1/32", ipv6: "fd00:0222:2021:1111::1")),
        Resource(name: "AWS", resourceLocation: .cidr(addressRange: "100.64.2.0/24")),
       ], .seconds(10)),
      ([Resource(name: "PostHog", resourceLocation: .dns(domain: "app.posthog.com", ipv4: "100.64.1.1/32", ipv6: "fd00:0222:2021:1111::1")),
        Resource(name: "AWS", resourceLocation: .cidr(addressRange: "100.64.2.0/24")),
        Resource(name: "ZenDesk", resourceLocation: .cidr(addressRange: "100.64.2.0/24")),
       ], .seconds(15)),
      ([Resource(name: "AWS", resourceLocation: .cidr(addressRange: "100.64.2.0/24")),
        Resource(name: "ZenDesk", resourceLocation: .cidr(addressRange: "100.64.2.0/24")),
       ], .seconds(5)),
      ([Resource(name: "PostHog", resourceLocation: .dns(domain: "app.posthog.com", ipv4: "100.64.1.1/32", ipv6: "fd00:0222:2021:1111::1")),
        Resource(name: "AWS", resourceLocation: .cidr(addressRange: "100.64.2.0/24")),
        Resource(name: "Imaginary", resourceLocation: .cidr(addressRange: "fd00:0222:2021:2222::0/64")),
       ], .seconds(10)),
    ]
  }
}

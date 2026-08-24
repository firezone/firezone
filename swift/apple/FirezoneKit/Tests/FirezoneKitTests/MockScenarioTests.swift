//
//  MockScenarioTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Pins that every scenario fixture the package ships still decodes. Loading one
// ends the process when it will not, so this is where a bad fixture should be
// caught rather than halfway through a screenshot run.

import Foundation
import Testing

@testable import FirezoneKit

struct MockScenarioTests {
  @Test("every shipped scenario loads", arguments: ["connected", "welcome", "grant-vpn"])
  func scenarioLoads(name: String) {
    let scenario = MockScenario.named(name)

    #expect(scenario.providerLogFolderSize > 0)
  }

  @Test("the connected scenario carries the demo state")
  func connectedCarriesTheDemoState() {
    let scenario = MockScenario.connected

    #expect(scenario.hasVPNConfiguration)
    #expect(scenario.vpnStatus == .connected)
    #expect(scenario.notifications == .authorized)
    #expect(scenario.resources.count == 5)
    #expect(scenario.connectedDevices.count == 22)
  }

  @Test("the grant-vpn scenario has neither extension nor configuration")
  func grantVPNHasNeitherExtensionNorConfiguration() {
    let scenario = MockScenario.named("grant-vpn")

    #expect(!scenario.hasVPNConfiguration)
    #expect(scenario.systemExtension == .needsInstall)
    #expect(scenario.resources.isEmpty)
  }
}

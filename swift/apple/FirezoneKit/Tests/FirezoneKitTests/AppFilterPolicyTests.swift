//
//  AppFilterPolicyTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import XCTest

@testable import FirezoneKit

final class AppFilterPolicyTests: XCTestCase {
  private let policy = AppFilterPolicy(
    allowedApplications: "com.example.approved",
    protectedRoutes: ["100.96.0.0/11", "10.0.0.0/8", "fd00:2021:1111:8000::/107"],
    exemptAddresses: ["100.100.111.1", "fd00:2021:1111:8000:100:100:111:1"]
  )

  func testOffPolicyAllowsEverything() {
    XCTAssertEqual(AppFilterPolicy.off.decide(app: nil, destination: "100.96.0.1"), .allow)
  }

  func testValueWithoutEntriesTurnsFilterOff() {
    XCTAssertFalse(
      AppFilterPolicy(allowedApplications: " , ", protectedRoutes: ["0.0.0.0/0"], exemptAddresses: [])
        .isEnforcing)
  }

  func testValueIsTrimmedAndSplit() {
    XCTAssertEqual(AppFilterPolicy.parseAllowedApps(" com.a , com.b,,"), ["com.a", "com.b"])
  }

  func testListedAppMayReachProtectedDestination() {
    XCTAssertEqual(policy.decide(app: "com.example.approved", destination: "100.96.0.1"), .allow)
    XCTAssertEqual(
      policy.decide(app: "com.example.approved", destination: "fd00:2021:1111:8000::1"), .allow)
  }

  func testUnlistedAppIsDeniedOnProtectedDestination() {
    XCTAssertEqual(policy.decide(app: "com.example.other", destination: "10.1.2.3"), .deny)
  }

  func testUnknownIdentityIsDenied() {
    XCTAssertEqual(policy.decide(app: nil, destination: "10.1.2.3"), .deny)
  }

  func testUnlistedAppKeepsOrdinaryInternetAccess() {
    XCTAssertEqual(policy.decide(app: "com.example.other", destination: "1.1.1.1"), .allow)
    XCTAssertEqual(policy.decide(app: "com.example.other", destination: "2606:4700::1"), .allow)
  }

  func testTunnelDnsServersAreExempt() {
    XCTAssertEqual(policy.decide(app: nil, destination: "100.100.111.1"), .allow)
    XCTAssertEqual(policy.decide(app: nil, destination: "fd00:2021:1111:8000:100:100:111:1"), .allow)
  }

  func testIPv4MappedAddressesMatchIPv4Routes() {
    XCTAssertEqual(policy.decide(app: nil, destination: "::ffff:10.1.2.3"), .deny)
  }

  func testFullTunnelProtectsInternetDestinations() {
    let fullTunnel = AppFilterPolicy(
      allowedApplications: "com.example.approved", protectedRoutes: ["0.0.0.0/0", "::/0"],
      exemptAddresses: [])

    XCTAssertEqual(fullTunnel.decide(app: "com.example.other", destination: "1.1.1.1"), .deny)
  }

  func testRoundTripsThroughSharedStorage() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "app-filter-policy-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    try policy.save(to: url)

    XCTAssertEqual(AppFilterPolicy.load(from: url), policy)
  }
}

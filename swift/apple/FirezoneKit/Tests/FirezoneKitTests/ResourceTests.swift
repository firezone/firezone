//
//  ResourceTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("Resource Tests")
struct ResourceTests {
  @Test(
    "A description that is a web URL is a link",
    arguments: ["https://gitlab.example.com", "HTTP://wiki.example.com/start"])
  func webDescriptionIsLink(description: String) {
    #expect(resource(description: description).descriptionURL == URL(string: description))
  }

  @Test(
    "A description that is not a web URL, or none at all, is not a link",
    arguments: ["Wiki", "ssh://git.example.com", "file:///etc/hosts", "", nil] as [String?])
  func otherDescriptionIsNotLink(description: String?) {
    #expect(resource(description: description).descriptionURL == nil)
  }

  private func resource(description: String?) -> Resource {
    Resource(
      id: "git",
      name: "GitLab",
      address: "gitlab.example.com",
      addressDescription: description,
      status: .online,
      sites: [],
      type: .dns
    )
  }
}

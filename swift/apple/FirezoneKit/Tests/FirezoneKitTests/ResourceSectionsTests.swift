//
//  ResourceSectionsTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("Resource Sections Tests")
struct ResourceSectionsTests {

  // MARK: - Sections

  @Test("Splits into the Internet Resource, favorites and others, in the order received")
  func splitsInOrderReceived() {
    let favorites = Favorites(userDefaults: UserDefaults.makeTestDefaults())
    favorites.add("git")
    favorites.add("wiki")

    let sections = ResourceSections(
      [
        resource("vpc"),
        resource("wiki"),
        resource("internet", type: .internet),
        resource("lab"),
        resource("git"),
      ],
      favorites: favorites
    )

    #expect(sections.internet?.id == "internet")
    #expect(sections.favorites.map(\.id) == ["wiki", "git"])
    #expect(sections.others.map(\.id) == ["vpc", "lab"])
    #expect(!sections.isEmpty)
  }

  @Test("The Internet Resource is never one of the favorites")
  func internetResourceIsNotAFavorite() {
    let favorites = Favorites(userDefaults: UserDefaults.makeTestDefaults())
    favorites.add("internet")

    let sections = ResourceSections([resource("internet", type: .internet)], favorites: favorites)

    #expect(sections.internet?.id == "internet")
    #expect(sections.favorites.isEmpty)
  }

  @Test("No Resources make no sections")
  func noResourcesAreEmpty() {
    let favorites = Favorites(userDefaults: UserDefaults.makeTestDefaults())
    let sections = ResourceSections([], favorites: favorites)

    #expect(sections.isEmpty)
  }

  // MARK: - Search

  @Test(
    "Search finds a Resource by name, address, description or Site name, ignoring case",
    arguments: ["gitlab", "CODE.example", "merge requests", "production", "  Cloud "])
  func searchMatches(query: String) {
    #expect(gitLab.matches(search: query))
  }

  @Test("Search leaves out a Resource that carries the query nowhere")
  func searchDoesNotMatch() {
    #expect(!gitLab.matches(search: "wiki"))
  }

  @Test("A blank search matches every Resource", arguments: ["", "   "])
  func blankSearchMatches(query: String) {
    #expect(gitLab.matches(search: query))
  }

  // MARK: - Fixtures

  private var gitLab: Resource {
    Resource(
      id: "git",
      name: "GitLab",
      address: "code.example.com",
      addressDescription: "Merge requests",
      status: .online,
      sites: [Site(id: "site", name: "Production Cloud")],
      type: .dns
    )
  }

  private func resource(_ id: String, type: ResourceType = .dns) -> Resource {
    Resource(
      id: id,
      name: id,
      address: nil,
      addressDescription: nil,
      status: .unknown,
      sites: [],
      type: type
    )
  }
}

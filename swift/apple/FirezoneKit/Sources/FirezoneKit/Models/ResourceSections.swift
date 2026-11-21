//
//  ResourceSections.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// The Resources in the groups the UI lists them in, each in the order received.
struct ResourceSections {
  /// Leads every list and is never one of the favorites.
  private(set) var internet: Resource?
  private(set) var favorites: [Resource] = []
  private(set) var others: [Resource] = []

  var isEmpty: Bool { internet == nil && favorites.isEmpty && others.isEmpty }

  init(_ resources: [Resource], favorites: Favorites) {
    for resource in resources {
      if resource.isInternetResource() {
        internet = resource
      } else if favorites.contains(resource.id) {
        self.favorites.append(resource)
      } else {
        others.append(resource)
      }
    }
  }
}

extension Resource {
  /// Whether `query` occurs in the name, address, description or a Site's name, ignoring case.
  /// A blank query matches every Resource.
  func matches(search query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespaces)

    guard !query.isEmpty else { return true }

    let fields = [name, address, addressDescription].compactMap { $0 } + sites.map(\.name)

    return fields.contains { $0.localizedCaseInsensitiveContains(query) }
  }
}

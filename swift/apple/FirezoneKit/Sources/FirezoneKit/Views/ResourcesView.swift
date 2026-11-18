//
//  ResourcesView.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import NetworkExtension
  import SwiftUI

  /// Content of the Resources window: every Resource in a sidebar, the selected one beside it.
  public struct ResourcesView: View {
    public static let windowID = "firezone-resources"

    @EnvironmentObject var store: Store
    @State private var selection: Resource.ID?
    @State private var search = ""

    public init() {}

    public var body: some View {
      content
        .frame(minWidth: 640, minHeight: 400)
    }

    @ViewBuilder
    private var content: some View {
      switch store.vpnStatus {
      case .connected where store.configuration.publishedHideResourceList:
        Placeholder(
          title: "Resources Unavailable",
          message: "Your organization has hidden the Resource list.")

      case .connected:
        switch store.resourceList {
        case .loading:
          ProgressView("Loading Resources…")

        case .loaded(let resources) where resources.isEmpty:
          Placeholder(title: "No Resources", message: "Contact your admin to be granted access.")

        case .loaded(let resources):
          browser(resources)
        }

      case .connecting:
        ProgressView("Connecting…")

      case .reasserting:
        ProgressView("Reconnecting…")

      default:
        VStack(spacing: 8) {
          Placeholder(title: "Not Signed In", message: "Sign in to browse your Resources.")
          SignInSection()
        }
      }
    }

    private func browser(_ resources: [Resource]) -> some View {
      let sections = ResourceSections(
        resources.filter { $0.matches(search: search) }, favorites: store.favorites)

      return NavigationSplitView {
        List(selection: $selection) {
          if let internet = sections.internet {
            row(internet)
          }

          if sections.favorites.isEmpty {
            ForEach(sections.others) { row($0) }
          } else {
            Section("Favorites") {
              ForEach(sections.favorites) { row($0, isFavorite: true) }
            }

            if !sections.others.isEmpty {
              Section("Other Resources") {
                ForEach(sections.others) { row($0) }
              }
            }
          }
        }
        .overlay {
          if sections.isEmpty {
            Text("No Results")
              .foregroundStyle(.secondary)
          }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
      } detail: {
        // Looked up in everything received, so a search does not empty the pane.
        if let resource = resources.first(where: { $0.id == selection }) {
          ResourceDetailView(resource: resource)
            // Otherwise the next Resource opens scrolled to where this one was left.
            .id(resource.id)
        } else {
          Placeholder(title: "No Resource Selected")
        }
      }
      .searchable(text: $search, placement: .sidebar)
    }

    private func row(_ resource: Resource, isFavorite: Bool = false) -> some View {
      ResourceRow(resource: resource, isFavorite: isFavorite)
        .tag(resource.id)
    }
  }

  private struct ResourceRow: View {
    let resource: Resource
    let isFavorite: Bool

    var body: some View {
      HStack(spacing: 8) {
        if resource.isDevicePool() {
          // Device pools have no status. As wide as the status dot, so that the names line up.
          Image(systemName: "desktopcomputer")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .accessibilityHidden(true)
        } else {
          ResourceStatusIcon(status: resource.status)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(resource.name)

          if let subtitle {
            Text(subtitle)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .lineLimit(1)

        Spacer()

        if isFavorite {
          Image(systemName: "star.fill")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Favorite")
        }
      }
      .padding(.vertical, 2)
    }

    private var subtitle: String? {
      switch resource.type {
      case .dns, .cidr, .ip:
        return resource.address

      case .internet:
        return "All network traffic"

      case .devicePool:
        switch resource.devices.count {
        case 0: return "No connected devices"
        case 1: return "1 connected device"
        case let count: return "\(count) connected devices"
        }
      }
    }
  }

  /// AppKit's status dot for a `ResourceStatus`.
  struct ResourceStatusIcon: View {
    let status: ResourceStatus

    var body: some View {
      if let icon = status.statusIcon {
        Image(nsImage: icon)
          .accessibilityLabel(status.label)
      }
    }
  }

  /// Stands in for `ContentUnavailableView`, which needs macOS 14.
  private struct Placeholder: View {
    let title: String
    var message: String?

    var body: some View {
      VStack(spacing: 4) {
        Text(title)
          .font(.title2.weight(.semibold))

        if let message {
          Text(message)
        }
      }
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding()
    }
  }
#endif

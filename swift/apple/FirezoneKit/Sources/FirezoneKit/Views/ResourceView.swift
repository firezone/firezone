//
//  ResourceView.swift
//
//
//  Created by Jamil Bou Kheir on 5/25/24.
//

import SwiftUI

#if os(iOS)
private func copyToClipboard(_ value: String) {
  let pasteboard = UIPasteboard.general
  pasteboard.string = value
}

struct ResourceView: View {
  @ObservedObject var model: SessionViewModel
  var resource: Resource
  @Environment(\.openURL) var openURL

  var body: some View {
    List {
      if resource.isInternetResource() {
        InternetResourceHeader(model: model, resource: resource)
      } else {
        NonInternetResourceHeader(model: model, resource: resource)
      }

      if let site = resource.sites.first {
        Section(header: Text("Site")) {
          HStack {
            Text("NAME")
              .bold()
              .font(.system(size: 14))
              .foregroundColor(.secondary)
              .frame(width: 80, alignment: .leading)
            Text(site.name)
          }
          .contextMenu {
            Button(
              action: {
                copyToClipboard(site.name)
              },
              label: {
                Text("Copy name")
                Image(systemName: "doc.on.doc")
              }
            )
          }

          HStack {
            Text("STATUS")
              .bold()
              .font(.system(size: 14))
              .foregroundColor(.secondary)
              .frame(width: 80, alignment: .leading)
            statusIndicator(for: resource.status)
            Text(resource.status.toSiteStatus())
              .padding(.leading, 5)
          }
          .contextMenu {
            Button(
              action: {
                copyToClipboard(resource.status.toSiteStatus())
              },
              label: {
                Text("Copy status")
                Image(systemName: "doc.on.doc")
              }
            )
          }
        }
      }
    }
    .listStyle(GroupedListStyle())
    .navigationBarTitle("Details", displayMode: .inline)
  }

  @ViewBuilder
  private func statusIndicator(for status: ResourceStatus) -> some View {
    HStack {
      Circle()
        .fill(color(for: status))
        .frame(width: 10, height: 10)
    }
  }

  private func color(for status: ResourceStatus) -> Color {
    switch status {
    case .online:
      return .green
    case .offline:
      return .red
    case .unknown:
      return .gray
    }
  }
}

struct NonInternetResourceHeader: View {
  @ObservedObject var model: SessionViewModel
  var resource: Resource
  @Environment(\.openURL) var openURL

  var body: some View {
    Section(header: Text("Resource")) {
      HStack {
        Text("NAME")
          .bold()
          .font(.system(size: 14))
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .leading)
        Text(resource.name)
      }
      .contextMenu {
        Button(
          action: {
            copyToClipboard(resource.name)
          },
          label: {
            Text("Copy name")
            Image(systemName: "doc.on.doc")
          }
        )
      }

      HStack {
        Text("ADDRESS")
          .bold()
          .font(.system(size: 14))
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .leading)
        if let url = URL(string: resource.addressDescription ?? resource.address!),
           url.host != nil {
          Button(
            action: {
              openURL(url)
            },
            label: {
              Text(resource.addressDescription ?? resource.address!)
                .foregroundColor(.blue)
                .underline()
                .font(.system(size: 16))
                .contextMenu {
                  Button(
                    action: {
                      copyToClipboard(resource.addressDescription ?? resource.address!)
                    },
                    label: {
                      Text("Copy address")
                      Image(systemName: "doc.on.doc")
                    }
                  )
                }
            }
          )
        } else {
          Text(resource.addressDescription ?? resource.address!)
            .contextMenu {
              Button(
                action: {
                  copyToClipboard(resource.addressDescription ?? resource.address!)
                },
                label: {
                  Text("Copy address")
                  Image(systemName: "doc.on.doc")
                }
              )
            }
        }
      }

      if model.favorites.ids.contains(resource.id) {
        Button(
          action: {
            Task { await model.favorites.remove(resource.id) }
          },
          label: {
            HStack {
              Image(systemName: "star")
              Text("Remove from favorites")
              Spacer()
            }
          }
        )
      } else {
        Button(
          action: {
            Task { await model.favorites.add(resource.id) }
          }, label: {
            HStack {
              Image(systemName: "star.fill")
              Text("Add to favorites")
              Spacer()
            }
          }
        )
      }
    }
  }
}

struct InternetResourceHeader: View {
  @ObservedObject var model: SessionViewModel
  var resource: Resource

  var body: some View {
    Section(header: Text("Resource")) {
      HStack {
        Text("NAME")
          .bold()
          .font(.system(size: 14))
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .leading)
        Text(resource.name)
      }

      HStack {
        Text("DESCRIPTION")
          .bold()
          .font(.system(size: 14))
          .foregroundColor(.secondary)
          .frame(alignment: .leading)

        Text("All network traffic")
      }

      ToggleInternetResourceButton(resource: resource, model: model)
    }
  }
}

struct ToggleInternetResourceButton: View {
  var resource: Resource
  @ObservedObject var model: SessionViewModel

  private func toggleResourceEnabledText() -> String {
    if model.isInternetResourceEnabled() {
      "Disable this resource"
    } else {
      "Enable this resource"
    }
  }

  var body: some View {
    Button(
      action: {
        model.store.toggleInternetResource(enabled: !model.isInternetResourceEnabled())
      },
      label: {
        HStack {
          Text(toggleResourceEnabledText())
          Spacer()
        }
      }
    )
  }
}

#endif

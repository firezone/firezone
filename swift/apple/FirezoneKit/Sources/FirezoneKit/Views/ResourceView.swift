//
//  ResourceView.swift
//
//
//  Created by Jamil Bou Kheir on 5/25/24.
//

import SwiftUI

#if os(iOS)
struct ResourceView: View {
  var resource: Resource
  @Environment(\.openURL) var openURL

  var body: some View {
    List {
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
          Button(action: {
            copyToClipboard(resource.name)
          }) {
            Text("Copy name")
            Image(systemName: "doc.on.doc")
          }
        }

        HStack {
          Text("ADDRESS")
            .bold()
            .font(.system(size: 14))
            .foregroundColor(.secondary)
            .frame(width: 80, alignment: .leading)
          if let url = URL(string: resource.addressDescription ?? resource.address),
             let _ = url.host {
            Button(action: {
              openURL(url)
            }) {
              Text(resource.addressDescription ?? resource.address)
                .foregroundColor(.blue)
                .underline()
                .font(.system(size: 16))
                .contextMenu {
                  Button(action: {
                    copyToClipboard(resource.addressDescription ?? resource.address)
                  }) {
                    Text("Copy address")
                    Image(systemName: "doc.on.doc")
                  }
                }
            }
          } else {
            Text(resource.addressDescription ?? resource.address)
              .contextMenu {
                Button(action: {
                  copyToClipboard(resource.addressDescription ?? resource.address)
                }) {
                  Text("Copy address")
                  Image(systemName: "doc.on.doc")
                }
              }
          }
        }
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
            Button(action: {
              copyToClipboard(site.name)
            }) {
              Text("Copy name")
              Image(systemName: "doc.on.doc")
            }
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
            Button(action: {
              copyToClipboard(resource.status.toSiteStatus())
            }) {
              Text("Copy status")
              Image(systemName: "doc.on.doc")
            }
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

  private func copyToClipboard(_ value: String) {
    let pasteboard = UIPasteboard.general
    pasteboard.string = value
  }
}
#endif

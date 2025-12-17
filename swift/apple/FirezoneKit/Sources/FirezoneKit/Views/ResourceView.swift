//
//  ResourceView.swift
//
//
//  Created by Jamil Bou Kheir on 5/25/24.
//

import Combine
import SwiftUI

#if os(iOS)
  private func copyToClipboard(_ value: String) {
    let pasteboard = UIPasteboard.general
    pasteboard.string = value
  }

  struct ResourceView: View {
    @EnvironmentObject var store: Store
    var resource: Resource
    @Environment(\.openURL) var openURL

    var body: some View {
      List {
        if resource.isInternetResource() {
          InternetResourceHeader(resource: resource)
        } else {
          NonInternetResourceHeader(resource: resource)
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
    @EnvironmentObject var store: Store
    var resource: Resource
    @Environment(\.openURL) var openURL

    private var displayAddress: String {
      resource.addressDescription ?? resource.address ?? "(no address)"
    }

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
          if let url = URL(string: displayAddress), url.host != nil {
            Button(
              action: {
                openURL(url)
              },
              label: {
                Text(displayAddress)
                  .foregroundColor(.blue)
                  .underline()
                  .font(.system(size: 16))
                  .contextMenu {
                    Button(
                      action: {
                        copyToClipboard(displayAddress)
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
            Text(displayAddress)
              .contextMenu {
                Button(
                  action: {
                    copyToClipboard(displayAddress)
                  },
                  label: {
                    Text("Copy address")
                    Image(systemName: "doc.on.doc")
                  }
                )
              }
          }
        }

        if store.favorites.contains(resource.id) {
          Button(
            action: {
              store.favorites.remove(resource.id)
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
              store.favorites.add(resource.id)
            },
            label: {
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
    @EnvironmentObject var store: Store
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

        ToggleInternetResourceButton(resource: resource)
      }
    }
  }

  @MainActor
  class ToggleInternetResourceButtonModel: ObservableObject {
    private var cancellables: Set<AnyCancellable> = []
    private let configuration = Configuration.shared

    @Published private(set) var enabled: Bool

    init() {
      self.enabled = configuration.internetResourceEnabled

      configuration.$publishedInternetResourceEnabled
        .receive(on: RunLoop.main)
        .sink(receiveValue: { [self] enabled in
          self.enabled = enabled
        })
        .store(in: &cancellables)
    }

    func toggleInternetResource() {
      configuration.internetResourceEnabled.toggle()
    }

    func toggleResourceEnabledText() -> String {
      return enabled ? "Disable this resource" : "Enable this resource"
    }
  }

  struct ToggleInternetResourceButton: View {
    var resource: Resource
    @EnvironmentObject var store: Store
    @StateObject var viewModel: ToggleInternetResourceButtonModel = .init()

    var body: some View {
      Button(
        action: {
          viewModel.toggleInternetResource()
        },
        label: {
          HStack {
            Text(viewModel.toggleResourceEnabledText())
            Spacer()
          }
        }
      )
    }
  }

#endif

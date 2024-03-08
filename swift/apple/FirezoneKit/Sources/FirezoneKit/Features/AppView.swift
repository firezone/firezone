//
//  AppView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import SwiftUI
import SwiftUINavigation
import SwiftUINavigationCore

#if os(iOS)
  @MainActor
  public final class AppViewModel: ObservableObject {
    @Published var welcomeViewModel: WelcomeViewModel?

    public init(appStore: AppStore) {
      Task {
        self.welcomeViewModel = WelcomeViewModel(appStore: appStore)
      }
    }
  }

  public struct AppView: View {
    @ObservedObject var model: AppViewModel

    public init(model: AppViewModel) {
      self.model = model
    }

    @ViewBuilder
    public var body: some View {
      if let model = model.welcomeViewModel {
        WelcomeView(model: model)
      } else {
        ProgressView()
      }
    }
  }
#endif

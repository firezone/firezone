//
//  WelcomeView.swift
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
  final class WelcomeViewModel: ObservableObject {
    @Dependency(\.mainQueue) private var mainQueue

    private var cancellables = Set<AnyCancellable>()

    enum State {
      case uninitialized
      case needsPermission(AskPermissionViewModel)
      case unauthenticated(AuthViewModel)
      case authenticated(MainViewModel)

      var shouldDisableSettings: Bool {
        switch self {
        case .uninitialized: return true
        case .needsPermission: return true
        case .unauthenticated: return false
        case .authenticated: return false
        }
      }
    }

    @Published var state: State? {
      didSet {
        bindState()
      }
    }

    private let appStore: AppStore
    private let sessionNotificationHelper: SessionNotificationHelper

    let settingsViewModel: SettingsViewModel
    @Published var isSettingsSheetPresented = false

    init(appStore: AppStore) {
      self.appStore = appStore
      self.settingsViewModel = appStore.settingsViewModel

      let sessionNotificationHelper =
        SessionNotificationHelper(logger: appStore.logger, tunnelStore: appStore.tunnelStore)
      self.sessionNotificationHelper = sessionNotificationHelper

      appStore.objectWillChange
        .receive(on: mainQueue)
        .sink { [weak self] in self?.objectWillChange.send() }
        .store(in: &cancellables)

      Publishers.CombineLatest(
        appStore.tunnelStore.$status,
        sessionNotificationHelper.$notificationDecision
      )
      .receive(on: mainQueue)
      .sink(receiveValue: { [weak self] status, notificationDecision in
        guard let self = self else { return }
        switch (status, notificationDecision) {
        case (.invalid, _), (_, .notDetermined):
          self.state = .needsPermission(
            AskPermissionViewModel(
              tunnelStore: self.appStore.tunnelStore,
              sessionNotificationHelper: sessionNotificationHelper
            )
          )
        case (.disconnected, .determined):
          self.state = .unauthenticated(AuthViewModel(tunnelStore: appStore.tunnelStore))
        case (_, .determined):
          self.state = .authenticated(MainViewModel(tunnelStore: appStore.tunnelStore, logger: appStore.logger))
        case (_, .uninitialized):
          self.state = .uninitialized

        }
      })
      .store(in: &cancellables)
    }

    func settingsButtonTapped() {
      isSettingsSheetPresented = true
    }

    private func bindState() {
      switch state {
      case .unauthenticated(let model):
        model.settingsUndefined = { [weak self] in
          self?.isSettingsSheetPresented = true
        }

      case .authenticated, .uninitialized, .needsPermission, .none:
        break
      }
    }
  }

  struct WelcomeView: View {
    @ObservedObject var model: WelcomeViewModel

    var body: some View {
      NavigationView {
        Group {
          switch model.state {
          case .uninitialized:
            Image("LogoText")
              .resizable()
              .scaledToFit()
              .frame(maxWidth: 600)
              .padding(.horizontal, 10)
          case .needsPermission(let model):
            AskPermissionView(model: model)
          case .unauthenticated(let model):
            AuthView(model: model)
          case .authenticated(let model):
            MainView(model: model)
          case .none:
            ProgressView()
          }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button {
              model.settingsButtonTapped()
            } label: {
              Label("Settings", systemImage: "gear")
            }
            .disabled(model.state?.shouldDisableSettings ?? true)
          }
        }
      }
      .sheet(isPresented: $model.isSettingsSheetPresented) {
        SettingsView(model: model.settingsViewModel)
      }
      .navigationViewStyle(StackNavigationViewStyle())
    }
  }
#endif

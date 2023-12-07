//
//  WelcomeView.swift
//  (c) 2023 Firezone, Inc.
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

    enum Destination {
      case settings(SettingsViewModel)
      case undefinedSettingsAlert(AlertState<UndefinedSettingsAlertAction>)
    }

    enum UndefinedSettingsAlertAction {
      case confirmDefineSettingsButtonTapped
    }

    enum State {
      case unauthenticated(AuthViewModel)
      case authenticated(MainViewModel)
    }

    @Published var destination: Destination? {
      didSet {
        bindDestination()
      }
    }

    @Published var state: State? {
      didSet {
        bindState()
      }
    }

    private let appStore: AppStore

    init(appStore: AppStore) {
      self.appStore = appStore

      appStore.objectWillChange
        .receive(on: mainQueue)
        .sink { [weak self] in self?.objectWillChange.send() }
        .store(in: &cancellables)

      defer { bindDestination() }

      appStore.auth.$loginStatus
        .receive(on: mainQueue)
        .sink(receiveValue: { [weak self] loginStatus in
          guard let self else {
            return
          }

          switch loginStatus {
          case .signedIn:
            self.state = .authenticated(MainViewModel(appStore: self.appStore))
          default:
            self.state = .unauthenticated(AuthViewModel())
          }
        })
        .store(in: &cancellables)
    }

    func settingsButtonTapped() {
      destination = .settings(SettingsViewModel())
    }

    func handleUndefinedSettingsAlertAction(_ action: UndefinedSettingsAlertAction) {
      switch action {
      case .confirmDefineSettingsButtonTapped:
        destination = .settings(SettingsViewModel())
      }
    }

    private func bindDestination() {
      switch destination {
      case .settings(let model):
        model.onSettingsSaved = { [weak self] in
          self?.destination = nil
          self?.state = .unauthenticated(AuthViewModel())
        }

      case .undefinedSettingsAlert, .none:
        break
      }
    }

    private func bindState() {
      switch state {
      case .unauthenticated(let model):
        model.settingsUndefined = { [weak self] in
          self?.destination = .undefinedSettingsAlert(.undefinedSettings)
        }

      case .authenticated, .none:
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
          }
        }
      }
      .sheet(unwrapping: $model.destination, case: /WelcomeViewModel.Destination.settings) {
        $model in
        SettingsView(model: model)
      }
      .alert(
        unwrapping: $model.destination,
        case: /WelcomeViewModel.Destination.undefinedSettingsAlert,
        action: model.handleUndefinedSettingsAlertAction
      )
    }
  }

  struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
      WelcomeView(
        model: WelcomeViewModel(appStore: AppStore(tunnelStore: TunnelStore.shared))
      )
    }
  }
#endif

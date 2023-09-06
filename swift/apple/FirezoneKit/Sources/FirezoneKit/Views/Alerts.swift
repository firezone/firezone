//
//  Alerts.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import _SwiftUINavigationState

#if os(iOS)
extension AlertState where Action == WelcomeViewModel.UndefinedSettingsAlertAction {
  static let undefinedSettings = AlertState(
    title: TextState("No settings found."),
    message: TextState("To sign in, you first need to configure portal settings."),
    dismissButton: .default(
      TextState("Define settings"),
      action: .send(.confirmDefineSettingsButtonTapped)
    )
  )
}
#endif

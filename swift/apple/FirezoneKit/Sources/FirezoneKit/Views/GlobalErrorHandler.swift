//
//  GlobalErrorHandler.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// A utility class for responding to errors raised in the view hierarchy.

import SwiftUI

public class ErrorAlert: Identifiable {
  var title: String
  var error: Error
  var message: String?

  public init(title: String = "An error occurred", error: Error, message: String? = nil) {
    self.title = title
    self.error = error
    self.message = message
  }
}

public class GlobalErrorHandler: ObservableObject {
  @Published var currentAlert: ErrorAlert?

  public init() {}

  public func handle(_ errorAlert: ErrorAlert) {
    currentAlert = errorAlert
  }

  public func clear() {
    currentAlert = nil
  }
}

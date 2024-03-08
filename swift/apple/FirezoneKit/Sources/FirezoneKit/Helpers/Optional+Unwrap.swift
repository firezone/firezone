//
//  Optional+Unwrap.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

extension Optional {
  /// Unwraps `self` or throws error if `none`.
  /// - Parameter error: Error to thrown in case of nil value.
  /// - Returns: The wrapped optional value.
  func unwrap(throwing error: @autoclosure () -> Error) throws -> Wrapped {
    guard let self else {
      throw error()
    }
    return self
  }
}

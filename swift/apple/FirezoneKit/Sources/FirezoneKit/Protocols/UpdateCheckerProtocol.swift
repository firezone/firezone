//
//  UpdateCheckerProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Combine

  /// Abstracts update checking to support dependency injection.
  @MainActor
  public protocol UpdateCheckerProtocol: AnyObject, ObservableObject {
    var updateAvailable: Bool { get }
  }
#endif

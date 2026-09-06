//
//  MockRun.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import SwiftUI

/// Whether this process presents mocked state rather than a real tunnel.
public enum MockRun {
  #if DEBUG
    public static let isActive = CommandLine.arguments.contains("--mock-tunnel")
  #else
    public static let isActive = false
  #endif
}

#if os(iOS)
  extension View {
    /// Bars over a flat colour instead of glass in a mocked run. Glass samples
    /// whatever lies behind it and does not come out the same twice.
    @ViewBuilder
    public func mockFlatBars() -> some View {
      if MockRun.isActive, #available(iOS 18, *) {
        toolbarBackgroundVisibility(.visible, for: .navigationBar, .tabBar)
          .toolbarBackground(Color(.systemBackground), for: .navigationBar, .tabBar)
      } else {
        self
      }
    }
  }
#endif

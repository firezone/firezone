//
//  MockRun.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Whether this process presents mocked state rather than a real tunnel.
public enum MockRun {
  #if DEBUG
    public static let isActive = CommandLine.arguments.contains("--mock-tunnel")
  #else
    public static let isActive = false
  #endif
}

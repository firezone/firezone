//
//  LogFilter.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

// Android and desktop validate a filter with connlib's own `logging::try_filter`. The Apple app
// links libconnlib but does not compile its generated Swift bindings, so it checks a strict
// subset of tracing's `EnvFilter` syntax instead: anything accepted here parses there too.
// Unifying the FFI entrypoints would let this use connlib: https://github.com/firezone/firezone/issues/16014.
enum LogFilter {
  private static let levels: Set<String> = ["trace", "debug", "info", "warn", "error", "off"]
  private static let targetCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:-"
  )

  /// Whether `filter` is empty or a comma-separated list of `level` or `target=level` directives.
  ///
  /// Whitespace is rejected rather than trimmed: `EnvFilter` reads " hyper=off" as a broken
  /// directive, and "info " as a target named "info ".
  static func isValid(_ filter: String) -> Bool {
    filter.split(separator: ",", omittingEmptySubsequences: true).allSatisfy(isValidDirective)
  }

  private static func isValidDirective(_ directive: Substring) -> Bool {
    let parts = directive.split(separator: "=", omittingEmptySubsequences: false)

    switch parts.count {
    case 1:
      return isLevel(parts[0])
    case 2:
      return isTarget(parts[0]) && isLevel(parts[1])
    default:
      return false
    }
  }

  private static func isLevel(_ level: Substring) -> Bool {
    levels.contains(level.lowercased())
  }

  private static func isTarget(_ target: Substring) -> Bool {
    !target.isEmpty && target.unicodeScalars.allSatisfy(targetCharacters.contains)
  }
}

//
//  Logger.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import Foundation
import OSLog

public extension Logger {
    static func make(for type: (some Any).Type) -> Logger {
        make(category: String(describing: type))
    }

    static func make(category: String) -> Logger {
        Logger(subsystem: "dev.firezone.firezone", category: category)
    }
}

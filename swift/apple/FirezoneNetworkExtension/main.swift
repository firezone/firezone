//
//  main.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import FirezoneKit
import NetworkExtension

//  Entrypoint for the macOS app
autoreleasepool {
  NEProvider.startSystemExtensionMode()
  IPCConnection.shared.startListener()
}

dispatchMain()

//
//  main.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneShared
import Foundation
import NetworkExtension

//  Entrypoint for the macOS app
autoreleasepool {
  NEProvider.startSystemExtensionMode()
}

dispatchMain()

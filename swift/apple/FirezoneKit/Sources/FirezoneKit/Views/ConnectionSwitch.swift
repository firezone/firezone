//
//  ConnectionSwitch.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import SwiftUI

struct ConnectionSwitch: View {
  let status: NEVPNStatus
  var connect: () async -> Void
  var disconnect: () async -> Void

  @State private var isInFlight = false

  var body: some View {
    HStack {
      ZStack {
        Toggle(
          "",
          isOn: .init(
            get: { status == .connected },
            set: { isOn in
              Task {
                isInFlight = true
                defer { isInFlight = false }

                if isOn {
                  await connect()
                } else {
                  await disconnect()
                }
              }
            }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .opacity(isInFlight ? 0 : 1)

        if isInFlight {
          ProgressView()
        }
      }

      Text(status.description).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct ConnectionSwitch_Previews: PreviewProvider {
  static var previews: some View {
    ConnectionSwitch(status: .connected, connect: {}, disconnect: {})
  }
}

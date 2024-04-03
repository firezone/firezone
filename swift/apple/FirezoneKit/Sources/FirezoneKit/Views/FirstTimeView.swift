//
//  FirstTimeView.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//

import SwiftUI

#if os(macOS)
struct FirstTimeView: View {
  var body: some View {
    VStack {
      Text(
        "You can sign in to Firezone by clicking on the Firezone icon in the macOS menu bar.\nYou may now close this window."
      )
      .font(.body)
      .multilineTextAlignment(.center)

      Spacer()
      Button("Close this Window") {
        AppViewModel.WindowDefinition.main.window()?.close()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      Spacer()
        .frame(maxHeight: 20)
      Text(
        "Firezone will continue running after this window is closed.\nIt will be available from the macOS menu bar."
      )
      .font(.caption)
      .multilineTextAlignment(.center)
    }
  }
}
#endif

//
//  FirstTimeView.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//

import SwiftUI

#if os(macOS)
struct FirstTimeView: View {
  var menuBar: MenuBar?

  var body: some View {
    VStack(
      alignment: .center,
      content: {
        Spacer()
        Image("LogoText")
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 320)
          .padding(.horizontal, 10)
        Spacer()
        Text(
          "You can sign in to Firezone by clicking on the Firezone icon in the macOS menu bar or clicking 'Open menu' below.\nYou may now close this window."
        )
        .font(.body)
        .multilineTextAlignment(.center)

        Spacer()
        HStack {
          Button("Close this window") {
            AppViewModel.WindowDefinition.main.window()?.close()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          Button("Open menu") {
            DispatchQueue.main.async {
              menuBar?.showMenu()
            }
            AppViewModel.WindowDefinition.main.window()?.close()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        }
        Spacer()
          .frame(maxHeight: 20)
        Text(
          "Firezone will continue running after this window is closed.\nIt will be available from the macOS menu bar."
        )
        .font(.caption)
        .multilineTextAlignment(.center)
        Spacer()
    })
  }
}
#endif

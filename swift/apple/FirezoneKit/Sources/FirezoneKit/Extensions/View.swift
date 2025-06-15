//
//  View.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//

import SwiftUI

extension View {
  func actionVerbage() -> String {
    #if os(macOS)
      return "clicking"
    #else
      return "tapping"
    #endif
  }
}

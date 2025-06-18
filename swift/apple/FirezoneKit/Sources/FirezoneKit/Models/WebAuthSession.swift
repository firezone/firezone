//
//  WebAuthSession.swift
//
//
//  Created by Jamil Bou Kheir on 4/1/24.
//

import AuthenticationServices
import Foundation

/// Provides presentation anchor utility for ASWebAuthenticationSession
@MainActor
public struct WebAuthSession {
  public static let anchor = PresentationAnchor()
}

// Required shim to use as "presentationAnchor" for the Webview. Why Apple?
public final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
  @MainActor
  public func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    ASPresentationAnchor()
  }
}

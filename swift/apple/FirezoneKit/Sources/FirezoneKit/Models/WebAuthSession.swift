//
//  WebAuthSession.swift
//
//
//  Created by Jamil Bou Kheir on 4/1/24.
//

import Foundation
import AuthenticationServices


/// Wraps the ASWebAuthenticationSession ordeal so it can be called from either
/// the AuthView (iOS) or the MenuBar (macOS)
@MainActor
struct WebAuthSession {
  private static let scheme = "firezone-fd0020211111"

  static func signIn(store: Store) {
    guard let authURL = store.authURL(),
          let authClient = try? AuthClient(authURL: authURL),
          let url = try? authClient.build()
    else { fatalError("authURL must be valid!") }

    let anchor = PresentationAnchor()

    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { returnedURL, error in
      guard error == nil,
            let authResponse = try? authClient.response(url: returnedURL)
      else {
        // Can happen if the user closes the opened Webview without signing in
        dump(error)
        return
      }

      Task {
        do {
          try await store.signIn(authResponse: authResponse)
        } catch {
          Log.error(error)
        }
      }
    }

    // Apple weirdness, doesn't seem to be actually used in macOS
    session.presentationContextProvider = anchor

    // load cookies
    session.prefersEphemeralWebBrowserSession = false

    // Start auth
    session.start()
  }
}

// Required shim to use as "presentationAnchor" for the Webview. Why Apple?
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
  @MainActor
  func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    ASPresentationAnchor()
  }
}

//
//  WebAuthSession.swift
//
//
//  Created by Jamil Bou Kheir on 4/1/24.
//

import AuthenticationServices
import Foundation

/// Wraps the ASWebAuthenticationSession ordeal so it can be called from either
/// the AuthView (iOS) or the MenuBar (macOS)
@MainActor
struct WebAuthSession {
  private static let scheme = "firezone-fd0020211111"

  static func signIn(store: Store, configuration: Configuration? = nil) async throws {
    let configuration = configuration ?? Configuration.shared
    let signInSettings = configuration.signInSettings

    guard let authURL = URL(string: signInSettings.authURL),
      let authClient = try? AuthClient(
        authURL: authURL.appendingPathComponent(signInSettings.accountSlug)),
      let url = try? authClient.build()
    else {
      // Should never get here because we perform URL validation on input, but handle this just in case
      throw AuthClientError.invalidAuthURL
    }

    // Create anchor on MainActor, then pass to concurrent function
    let anchor = PresentationAnchor()

    // Call @concurrent function to avoid MainActor inference on callback closure
    let callbackURL = try await performAuthentication(
      url: url,
      callbackScheme: scheme,
      httpsCallbackHost: authClient.httpsCallbackHost,
      anchor: anchor
    )

    if let callbackURL {
      let signIn = try authClient.completeSignIn(
        from: callbackURL, configuration: configuration, signInSettings: signInSettings)
      try await store.signIn(token: signIn.token, signInSettings: signIn.signInSettings)
    }
  }

  // @concurrent runs on global executor, preventing closure from inheriting MainActor isolation
  @concurrent private static func performAuthentication(
    url: URL,
    callbackScheme: String,
    httpsCallbackHost: String?,
    anchor: PresentationAnchor
  ) async throws -> URL? {
    // Anchor passed as parameter, keeping strong reference

    return try await withCheckedThrowingContinuation { continuation in
      let completionHandler: ASWebAuthenticationSession.CompletionHandler = {
        returnedURL, error in
        do {
          if let error = error as? ASWebAuthenticationSessionError,
            error.code == .canceledLogin
          {
            // User canceled sign in
            continuation.resume(returning: nil)
            return
          } else if let error = error {
            throw error
          }

          guard let returnedURL else { throw AuthClientError.invalidCallbackURL }
          continuation.resume(returning: returnedURL)
        } catch {
          continuation.resume(throwing: error)
        }
      }

      let session: ASWebAuthenticationSession
      if let httpsCallbackHost, #available(iOS 17.4, macOS 14.4, *) {
        session = ASWebAuthenticationSession(
          url: url,
          callback: .https(host: httpsCallbackHost, path: AuthClient.httpsCallbackPath),
          completionHandler: completionHandler
        )
      } else {
        session = ASWebAuthenticationSession(
          url: url,
          callbackURLScheme: callbackScheme,
          completionHandler: completionHandler
        )
      }

      // Apple weirdness, doesn't seem to be actually used in macOS
      session.presentationContextProvider = anchor

      // load cookies
      session.prefersEphemeralWebBrowserSession = false

      // Start auth - must be called on MainActor
      // Use Task to asynchronously hop to MainActor from concurrent context
      // (cannot use await MainActor.run - withCheckedThrowingContinuation requires sync closure)
      Task { @MainActor in
        session.start()
      }
    }
  }
}

// Required shim to use as "presentationAnchor" for the Webview. Why Apple?
final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding,
  Sendable
{
  @MainActor
  func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    ASPresentationAnchor()
  }
}

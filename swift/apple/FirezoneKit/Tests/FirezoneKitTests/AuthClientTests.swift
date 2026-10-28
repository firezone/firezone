//
//  AuthClientTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@MainActor
@Suite("Browser sign-in region")
struct AuthClientTests {
  @Test(
    "a validated region updates saved and active endpoints",
    arguments: [
      ("us", ControlPlane.cloudUs), ("eu", ControlPlane.cloudEu),
    ])
  func regionSelectsControlPlane(region: String, controlPlane: ControlPlane) throws {
    let configuration = makeConfiguration()
    let captured = configuration.signInSettings
    configuration.accountSlug = "edited-account"
    let authURL = try #require(URL(string: captured.authURL))
    let client = try #require(try AuthClient(authURL: authURL))

    let signIn = try client.completeSignIn(
      from: callback(for: client, region: region), configuration: configuration,
      signInSettings: captured)

    let urls = try #require(controlPlane.urls)
    #expect(configuration.authURL == urls.authURL)
    #expect(configuration.apiURL == urls.apiURL)
    #expect(signIn.signInSettings.authURL == urls.authURL)
    #expect(signIn.signInSettings.apiURL == urls.apiURL)
    #expect(signIn.signInSettings.accountSlug == captured.accountSlug)
    #expect(configuration.accountSlug == "edited-account")
    #expect(configuration.logFilter == "trace")
    #expect(configuration.lastCustomURLs?.authURL == captured.authURL)
    #expect(configuration.lastCustomURLs?.apiURL == captured.apiURL)
    let signInURL = try client.build()
    let nonce = try #require(
      URLComponents(url: signInURL, resolvingAgainstBaseURL: false)?.sanitizedQueryParam("nonce"))
    #expect(signIn.token == nonce + "token-fragment")
  }

  @Test(
    "an absent or unknown region preserves captured and saved settings",
    arguments: [nil, "other"] as [String?])
  func unrecognizedRegionDoesNotChangeSettings(region: String?) throws {
    let configuration = makeConfiguration()
    let captured = configuration.signInSettings
    configuration.apiURL = "wss://next.example.com"
    let saved = configuration.toProviderConfiguration()
    let authURL = try #require(URL(string: captured.authURL))
    let client = try #require(try AuthClient(authURL: authURL))

    let signIn = try client.completeSignIn(
      from: callback(for: client, region: region), configuration: configuration,
      signInSettings: captured)

    #expect(signIn.signInSettings == captured)
    #expect(configuration.toProviderConfiguration() == saved)
  }

  @Test("an invalid callback state cannot change settings")
  func invalidStateDoesNotChangeSettings() throws {
    let configuration = makeConfiguration()
    let captured = configuration.signInSettings
    let saved = configuration.toProviderConfiguration()
    let authURL = try #require(URL(string: captured.authURL))
    let client = try #require(try AuthClient(authURL: authURL))
    let callbackURL = try callback(for: client, region: "eu")
    var components = try #require(
      URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
    components.queryItems?.removeAll { $0.name == "state" }
    components.queryItems?.append(URLQueryItem(name: "state", value: "invalid"))

    #expect(throws: AuthClientError.self) {
      try client.completeSignIn(
        from: components.url, configuration: configuration, signInSettings: captured)
    }
    #expect(configuration.toProviderConfiguration() == saved)
  }

  @Test(
    "forced URL fields remain effective in the active snapshot",
    arguments: [
      Configuration.Keys.authURL, Configuration.Keys.apiURL,
    ])
  func preservesForcedURL(key: String) throws {
    let value =
      key == Configuration.Keys.authURL
      ? "https://managed.example.com" : "wss://managed.example.com"
    let defaults = try #require(
      ForcedUserDefaults(forcedKeys: [key], forcedValues: [key: value]))
    let configuration = makeConfiguration(defaults: defaults)
    let captured = configuration.signInSettings
    let authURL = try #require(URL(string: captured.authURL))
    let client = try #require(try AuthClient(authURL: authURL))

    let signIn = try client.completeSignIn(
      from: callback(for: client, region: "eu"), configuration: configuration,
      signInSettings: captured)

    #expect(signIn.signInSettings.authURL == configuration.authURL)
    #expect(signIn.signInSettings.apiURL == configuration.apiURL)
    if key == Configuration.Keys.authURL {
      #expect(configuration.authURL == captured.authURL)
      #expect(configuration.apiURL == ControlPlane.cloudEu.urls?.apiURL)
    } else {
      #expect(configuration.authURL == ControlPlane.cloudEu.urls?.authURL)
      #expect(configuration.apiURL == captured.apiURL)
    }
  }

  private func makeConfiguration(defaults: UserDefaults = .makeTestDefaults()) -> Configuration {
    let configuration = Configuration(userDefaults: defaults)
    configuration.authURL = "https://custom.example.com"
    configuration.apiURL = "wss://custom.example.com"
    configuration.accountSlug = "original-account"
    configuration.logFilter = "trace"
    configuration.lastCustomURLs = (configuration.authURL, configuration.apiURL)
    return configuration
  }

  private func callback(for client: AuthClient, region: String?) throws -> URL {
    let signInURL = try client.build()
    let auth = try #require(URLComponents(url: signInURL, resolvingAgainstBaseURL: false))
    var callback = URLComponents()
    callback.scheme = "firezone-fd0020211111"
    callback.host = "handle_client_sign_in_callback"
    callback.queryItems = [
      URLQueryItem(name: "state", value: auth.sanitizedQueryParam("state")),
      URLQueryItem(name: "fragment", value: "token-fragment"),
    ]
    if let region { callback.queryItems?.append(URLQueryItem(name: "region", value: region)) }
    return try #require(callback.url)
  }
}

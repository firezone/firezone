//
//  AuthResponse.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public struct AuthResponse {
  // The user associated with this authResponse.
  public let actorName: String

  // The account slug of the account the user signed in to.
  public let accountSlug: String

  // The opaque auth token
  public let token: String
  
  public init(actorName: String, accountSlug: String, token: String) {
    self.actorName = actorName
    self.accountSlug = accountSlug
    self.token = token
  }
}

//
//  AuthResponse.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct AuthResponse {
  // The user associated with this authResponse.
  let actorName: String

  // The account slug of the account the user signed in to.
  let accountSlug: String

  // The opaque auth token
  let token: String
}

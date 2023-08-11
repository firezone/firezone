//
//  AuthResponse.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct AuthResponse {
  // The user associated with this authResponse.
  let actorName: String?

  // The portal URL
  let portalURL: URL

  // The opaque auth token
  let token: String

  init(portalURL: URL, token: String, actorName: String?) throws {
    self.portalURL = portalURL
    self.actorName = actorName
    self.token = token
  }
}

#if DEBUG
  extension AuthResponse {
    static let invalid =
      try! AuthResponse(
        portalURL: URL(string: "http://localhost:4568")!,
        token: "",
        actorName: nil
      )

    static let valid =
      try! AuthResponse(
        portalURL: URL(string: "http://localhost:4568")!,
        token: "b1zwwwAdf=",
        actorName: "foobar"
      )
  }
#endif

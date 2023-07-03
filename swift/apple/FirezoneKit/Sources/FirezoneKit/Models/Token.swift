//
//  Token.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import JWTDecode

struct Token {
  // The user associated with this token parsed from the jwt sub claim.
  var user: String? { jwt["sub"].string }

  // The VPN session duration parsed from the jwt exp claim.
  var expiresAt: Date? { jwt["exp"].date }

  // A convenience property to check if the token has expired.
  var expired: Bool { jwt.expired }

  // The base64 encoded jwt string.
  var string: String { jwt.string }

  // The portal URL
  let portalURL: URL

  // The decoded jwt.
  private let jwt: JWT

  init(portalURL: URL, tokenString: String) throws {
    self.portalURL = portalURL
    self.jwt = try decode(jwt: tokenString)
  }
}

extension Token: Hashable {
  static func == (lhs: Token, rhs: Token) -> Bool {
    lhs.string == rhs.string
  }

  func hash(into hasher: inout Hasher) {
    string.hash(into: &hasher)
  }
}

#if DEBUG
  extension Token {
    static let expired =
      try! Token(
        portalURL: URL(string: "http://localhost:4568")!,
        tokenString: "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0QGZpcmV6b25lLmRldiIsImV4cCI6MTY2NzE0MDU1NX0.YLLQyfX6AlHQb90AMRrBTbvBuRxBzVYe0YwohfcD0r7KdBmR5Y-AcP0eYVC2DK-MSSJVjzs2j7SMPCvwJRc1z0LX_U4PkHjL5HPUIb3_rE1MIP8Hn8Ng5mk6SaTj6EJm3qTmm44bPiy21kntcqp-b9CSFqwc1IQHVHXnbcqcv4sVit2sTXJSNvNRRtO8ZTsC007T9skYBGVfCI-kSFyxQe9CoPQxYzFF8KKtCqmmT-t5g0et78IcwToOYeCxc0zOe14OQFadDZabmvJ_xfvC4iRKPfbOyQfNQqIQ_xh3iaGry2iSD4yMALKvgA7Ij4Ixz0GEnyqEfvOeCRA1UoFcLg"
      )

    static let valid =
      try! Token(
        portalURL: URL(string: "http://localhost:4568")!,
        tokenString: "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0QGZpcmV6b25lLmRldiIsImV4cCI6MTY2OTk0MDU1NX0.cLkLdIUBF5FH9e32yBPcfOXun11iYhtbxsVdqlZt3U5J-CYfBNikg5jbG6N7h2BYCBjScnmpu7G249la-lahO7IZWM3qil4NNyhKMZxzA_3cgC3362MBX-7xmlpxjR61b_yE1wOfGjjm_xOKIUTfkkfyTGxvQkXecdbOgpZ7WV4PkG7QD-JHgaQvIQCMbQuC5-d225z6rC43itiRxkq5mRet1d6N5VPxq1tdOD4N7mMs9I1NjJpFGcmJw8r8tlik8r7oxlJpmZN6aw4wcHV3gMd_Dmm-ZYW8M6aVvOpNIabi4hvB0Snqx-w4SqHy1stjfm-vHiGfusucX4G4igk4Qw"
      )
  }
#endif

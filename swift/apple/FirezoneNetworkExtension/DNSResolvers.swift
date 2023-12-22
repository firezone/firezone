//
//  DNSResolvers.swift
//  Firezone
//
//  Created by Jamil Bou Kheir on 12/12/23.
//
//  Returns the system's DNS Resolvers on macOS

import Foundation

public class DNSResolvers {
  // FIXME: We need to find a method of finding the system's default resolvers that
  // works on both macOS and iOS. See https://github.com/firezone/firezone/issues/2939
  private static let resolvers = ["1.1.1.1", "1.0.0.1"]

  public static func getDNSResolvers() -> [String] {
    return resolvers
  }
}

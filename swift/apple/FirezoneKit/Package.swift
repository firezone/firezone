// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "FirezoneKit",
  platforms: [.iOS(.v15), .macOS(.v13)],
  products: [
    // Products define the executables and libraries a package produces, and make them visible to
    // other packages.
    .library(name: "FirezoneKit", targets: ["FirezoneKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-system", exact: "1.6.4"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.4.0"),
  ],
  targets: [
    .target(
      name: "FirezoneKit",
      dependencies: [
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "Sentry", package: "sentry-cocoa"),
      ]
    ),
    .testTarget(
      name: "FirezoneKitTests",
      dependencies: ["FirezoneKit"]
    ),
  ]
)

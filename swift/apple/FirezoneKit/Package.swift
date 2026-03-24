// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "FirezoneKit",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "FirezoneShared", targets: ["FirezoneShared"]),
    .library(name: "FirezoneApp", targets: ["FirezoneApp"]),
    .library(name: "FirezoneNE", targets: ["FirezoneNE"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-system", exact: "1.6.4"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.5.0"),
  ],
  targets: [
    .target(
      name: "FirezoneShared",
      dependencies: [
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "Sentry", package: "sentry-cocoa"),
      ]
    ),
    .target(name: "FirezoneApp", dependencies: ["FirezoneShared"]),
    .target(name: "FirezoneNE", dependencies: ["FirezoneShared"]),
    .testTarget(name: "FirezoneSharedTests", dependencies: ["FirezoneShared"]),
    .testTarget(name: "FirezoneAppTests", dependencies: ["FirezoneApp"]),
    .testTarget(name: "FirezoneNETests", dependencies: ["FirezoneNE"]),
  ]
)

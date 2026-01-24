// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "FirezoneCLI",
  platforms: [.macOS(.v13)],
  products: [
    .executable(
      name: "firezone-cli",
      targets: ["FirezoneCLI"]
    )
  ],
  dependencies: [
    .package(name: "FirezoneKit", path: "../FirezoneKit")
  ],
  targets: [
    .executableTarget(
      name: "FirezoneCLI",
      dependencies: [
        .product(name: "FirezoneKit", package: "FirezoneKit")
      ],
      path: "Sources"
    )
  ]
)

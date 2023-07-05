// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "FirezoneKit",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    // Products define the executables and libraries a package produces, and make them visible to
    // other packages.
    .library(name: "FirezoneKit", targets: ["FirezoneKit", "Connlib"]),
  ],
  dependencies: [
    // Dependencies declare other packages that this package depends on.
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "0.1.3"),
    .package(url: "https://github.com/pointfreeco/swiftui-navigation", from: "0.5.0"),
    .package(url: "https://github.com/auth0/JWTDecode.swift", from: "3.0.0"),
  ],
  targets: [
    .binaryTarget(
      name: "Connlib",
      path: "../../../rust/connlib/clients/apple/Connlib.xcframework"
    ),
    .target(
      name: "FirezoneKit",
      dependencies: [
        .product(name: "SwiftUINavigation", package: "swiftui-navigation"),
        .product(name: "_SwiftUINavigationState", package: "swiftui-navigation"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "JWTDecode", package: "JWTDecode.swift"),
      ]
    ),
    .testTarget(
      name: "FirezoneKitTests",
      dependencies: ["FirezoneKit"]
    ),
  ]
)

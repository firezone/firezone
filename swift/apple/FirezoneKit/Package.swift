// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "FirezoneKit",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    // Products define the executables and libraries a package produces, and make them visible to
    // other packages.
    .library(name: "FirezoneKit", targets: ["FirezoneKit"])
  ],
  dependencies: [
    // Dependencies declare other packages that this package depends on.
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swiftui-navigation", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "FirezoneKit",
      dependencies: [
        .product(name: "SwiftUINavigation", package: "swiftui-navigation"),
        .product(name: "SwiftUINavigationCore", package: "swiftui-navigation"),
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "FirezoneKitTests",
      dependencies: ["FirezoneKit"]
    ),
  ]
)

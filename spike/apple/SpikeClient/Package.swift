// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SpikeClient",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "SpikeClient", targets: ["SpikeClient"])],
  dependencies: [
    .package(url: "https://github.com/connectrpc/connect-swift", exact: "1.2.3"),
    .package(url: "https://github.com/apple/swift-protobuf", from: "1.41.0"),
  ],
  targets: [
    .target(
      name: "SpikeClient",
      dependencies: [
        .product(name: "Connect", package: "connect-swift"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ]
    ),
    .testTarget(name: "SpikeClientTests", dependencies: ["SpikeClient"]),
  ]
)

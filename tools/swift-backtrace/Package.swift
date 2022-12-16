// swift-tools-version:5.2

import PackageDescription

let package = Package(
  name: "swift-backtrace",
  dependencies: [
  ],
  targets: [
    .target(
      name: "swift-backtrace",
      dependencies: [
      ],
      swiftSettings: [
        .unsafeFlags([
                       "-parse-as-library",
                     ]),
      ]),
  ]
)

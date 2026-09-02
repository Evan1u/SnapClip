// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SnapClip",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "SnapClip", targets: ["SnapClip"])
  ],
  targets: [
    .executableTarget(
      name: "SnapClip",
      path: "SnapClip",
      exclude: ["Info.plist", "Assets.xcassets"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("Carbon"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("ServiceManagement"),
        .linkedFramework("Vision"),
        .linkedFramework("VisionKit"),
      ]
    )
  ]
)

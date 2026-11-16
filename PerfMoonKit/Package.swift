// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "PerfMoonKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PerfMoonKit", targets: ["PerfMoonKit"]),
        .executable(name: "PerfMoonProbe", targets: ["PerfMoonProbe"]),
    ],
    targets: [
        .target(
            name: "PerfMoonNative",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedLibrary("IOReport")]
        ),
        .target(name: "PerfMoonKit", dependencies: ["PerfMoonNative"]),
        .executableTarget(name: "PerfMoonProbe", dependencies: ["PerfMoonKit"]),
        .testTarget(name: "PerfMoonKitTests", dependencies: ["PerfMoonKit"]),
    ]
)

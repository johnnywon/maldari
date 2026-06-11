// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Translator",
    platforms: [
        // 14.4+ required by the Core Audio process tap (CATapDescription /
        // AudioHardwareCreateProcessTap).
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "Translator",
            path: "Translator",
            exclude: ["Info.plist", "Translator.entitlements"],
            resources: [
                .copy("Resources/AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "TranslatorTests",
            dependencies: ["Translator"],
            path: "Tests/TranslatorTests"
        ),
    ]
)

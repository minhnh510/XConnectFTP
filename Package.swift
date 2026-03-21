// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XConnectFTPValidation",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "XConnectFTPCore",
            targets: ["XConnectFTPCore"]
        )
    ],
    targets: [
        .target(
            name: "XConnectFTPCore",
            path: "XConnectFTP",
            exclude: [
                "Assets.xcassets",
                "AppleSync.swift",
                "AppSupportViews.swift",
                "BrowserInteraction.swift",
                "ContentView.swift",
                "FTPStreamClient.swift",
                "SessionViewModel.swift",
                "SiteEditorView.swift",
                "Stores.swift",
                "TransferCoordinator.swift",
                "TransferProgressModel.swift",
                "XConnectFTPApp.swift"
            ],
            sources: [
                "Localization.swift",
                "Models.swift",
                "FTPParsing.swift",
                "PerformanceServices.swift"
            ]
        ),
        .testTarget(
            name: "XConnectFTPCoreTests",
            dependencies: ["XConnectFTPCore"],
            path: "XConnectFTPTests"
        )
    ]
)

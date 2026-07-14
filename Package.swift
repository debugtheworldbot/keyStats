// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeyStatsCoreTests",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KeyStatsCore", targets: ["KeyStatsCore"])
    ],
    targets: [
        .target(
            name: "KeyStatsCore",
            path: "KeyStats",
            exclude: [
                "Assets.xcassets",
                "Main.storyboard",
                "Info.plist",
                "en.lproj",
                "zh-Hans.lproj",
                "zh-Hant.lproj",
                "AppStatsViewController.swift",
                "KeyStats.entitlements",
                "NotificationManager.swift",
                "StatsManager.swift",
                "HoverIconButton.swift",
                "MouseDistanceCalibrationViewController.swift",
                "ActivityHeatmapView.swift",
                "AllTimeStatsWindowController.swift",
                "MouseDistanceCalibrationWindowController.swift",
                "SettingsViewController.swift",
                "AppActivityTracker.swift",
                "AppStatsWindowController.swift",
                "AppDelegate.swift",
                "MenuBarController.swift",
                "AllTimeStatsViewController.swift",
                "MainWindowController.swift",
                "HelperMigrationPresenter.swift",
                "HelperSupervisor.swift",
                "HelperXPCClient.swift",
                "KeyboardHeatmapViewController.swift",
                "KPSDetailView.swift",
                "LaunchAtLoginManager.swift",
                "RemoteEventProcessor.swift",
                "Sync/SyncCoordinator.swift",
                "Sync/SyncSettingsWindowController.swift",
                "UpdateManager.swift",
                "KeyboardHeatmapWindowController.swift",
                "StatsPopoverViewController.swift",
                "SettingsWindowController.swift",
                "MainWindowViewController.swift"
            ],
            sources: [
                "AppStats.swift",
                "StatsModels.swift",
                "UpdateCheckCoordinator.swift",
                "Sync/SyncModels.swift",
                "Sync/SyncCrypto.swift",
                "Sync/SyncStorage.swift",
                "Sync/SyncTransport.swift",
                "Sync/DisplayStatsAggregator.swift"
            ]
        ),
        .testTarget(
            name: "KeyStatsCoreTests",
            dependencies: ["KeyStatsCore"],
            path: "KeyStatsTests",
            sources: ["AppStatsTests.swift", "StatsModelsTests.swift", "UpdateCheckCoordinatorTests.swift", "SyncCoreTests.swift"]
        )
    ]
)

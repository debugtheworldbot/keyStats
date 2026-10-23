import XCTest
@testable import KeyStatsCore

final class AppActivityTrackerTests: XCTestCase {
    func testBackgroundBundleMetadataIsExcluded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        for (name, key, expected) in [
            ("Agent", "LSUIElement", true),
            ("Daemon", "LSBackgroundOnly", true),
            ("Regular", "", false)
        ] {
            let app = root.appendingPathComponent("\(name).app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "com.test.\(name)", "CFBundlePackageType": "APPL"]
            if !key.isEmpty { info[key] = true }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            XCTAssertEqual(AppActivityTracker.isBackgroundOnlyBundle(at: app), expected)
        }
    }
}

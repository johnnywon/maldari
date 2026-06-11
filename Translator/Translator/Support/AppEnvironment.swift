import Foundation

/// Runtime environment facts the app branches on.
enum AppEnvironment {
    /// True when running under XCTest (`swift test`). Load-bearing: the
    /// diagnostic log, session recorder, and cloud sync all use real paths
    /// and the live upload token, so without this gate `swift test` would
    /// write into the user's ~/Library and upload test transcripts to the
    /// production Maldari worker. SwiftPM's XCTest runner sets
    /// XCTestConfigurationFilePath before any app code runs; the class check
    /// is a belt-and-suspenders fallback.
    static let isTesting: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}

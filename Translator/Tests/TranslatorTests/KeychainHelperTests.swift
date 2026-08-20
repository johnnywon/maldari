import XCTest
@testable import Translator

/// Regression: the app launched with no windows at all.
///
/// `Credentials.has*` is read from SwiftUI view bodies (TranscriptView's
/// missing-keys hint), which are evaluated on the main thread — including while
/// `AppDelegate.applySettings()` is constructing the transcript and Presentation
/// windows. Those checks were implemented with `KeychainHelper.load`, which requests
/// the item's DATA. A data-returning read from a binary the item's ACL does not
/// trust makes macOS present a modal "enter the login keychain password" dialog and
/// block the calling thread until it is answered — so the main thread stalled inside
/// window creation and nothing was ever shown. Ad-hoc signing gives every
/// `make-app.sh` build a different code identity, so any rebuild could trip it.
///
/// Found by /qa on 2026-08-01.
/// Report: .gstack/qa-reports/qa-report-maldari-2026-08-01.md
final class KeychainHelperTests: XCTestCase {

    /// Namespaced so a test can never collide with, or delete, a real credential.
    private let service = "com.translator.app.tests.keychain"
    private let account = "qa-existence-probe"

    override func tearDown() {
        KeychainHelper.delete(service: service, account: account)
        super.tearDown()
    }

    func test_exists_isFalseWhenAbsent() {
        KeychainHelper.delete(service: service, account: account)
        XCTAssertFalse(KeychainHelper.exists(service: service, account: account))
    }

    func test_exists_isTrueAfterSave_andFalseAfterDelete() {
        XCTAssertTrue(KeychainHelper.save("sk-test-value", service: service, account: account))
        XCTAssertTrue(KeychainHelper.exists(service: service, account: account))

        KeychainHelper.delete(service: service, account: account)
        XCTAssertFalse(KeychainHelper.exists(service: service, account: account))
    }

    /// `exists` must agree with `load` about presence, so swapping the presence
    /// checks over to it cannot change any behaviour that depended on them.
    func test_exists_agreesWithLoadAboutPresence() {
        KeychainHelper.delete(service: service, account: account)
        XCTAssertEqual(
            KeychainHelper.exists(service: service, account: account),
            KeychainHelper.load(service: service, account: account) != nil)

        KeychainHelper.save("value", service: service, account: account)
        XCTAssertEqual(
            KeychainHelper.exists(service: service, account: account),
            KeychainHelper.load(service: service, account: account) != nil)
    }

    /// The property that actually prevents the hang: presence checks must not ask
    /// for the secret. Asserted on the source, because the ACL prompt it avoids
    /// cannot be provoked from a unit test — it needs a signed bundle whose identity
    /// the keychain item does not trust.
    ///
    /// If this ever fails, someone reintroduced a decrypting read on the launch path
    /// and the app can start with no windows on the next re-sign.
    func test_presenceChecksDoNotRequestSecretData() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TranslatorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let credentials = try String(contentsOf: root
            .appendingPathComponent("Translator/Support/Credentials.swift"), encoding: .utf8)

        // Isolate the presence accessors and assert none of them route through get().
        for accessor in ["hasRTZR", "hasAnthropic", "hasOpenAI", "hasOpenRouter"] {
            let line = credentials
                .split(separator: "\n")
                .first { $0.contains("var \(accessor)") }
            let declaration = try XCTUnwrap(line, "\(accessor) not found")
            XCTAssertFalse(
                declaration.contains("get("),
                "\(accessor) decrypts the item; use Self.has() so launch cannot block "
                + "behind the keychain ACL dialog")
        }

        let helper = try String(contentsOf: root
            .appendingPathComponent("Translator/Support/KeychainHelper.swift"), encoding: .utf8)
        let existsStart = try XCTUnwrap(helper.range(of: "static func exists"))
        let tail = helper[existsStart.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    }"))
        // Comments stripped first: the body carries a deliberate "NOT kSecReturnData"
        // note explaining the whole point, and matching that would make this test
        // pass only while the explanation is absent.
        let code = tail[..<end.lowerBound]
            .split(separator: "\n")
            .map { $0.contains("//") ? $0[..<$0.range(of: "//")!.lowerBound] : $0 }
            .joined(separator: "\n")
        XCTAssertFalse(
            code.contains("kSecReturnData"),
            "exists() must not request kSecReturnData — that is the ACL-gated path")
    }
}

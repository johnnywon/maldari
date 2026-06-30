import XCTest
import AppKit
@testable import Translator

final class MaldariIconTests: XCTestCase {
    func test_malGlyphPath_isNonEmpty() {
        XCTAssertFalse(MaldariIcon.malGlyphPath(in: 100, weight: .heavy).isEmpty)
    }
    func test_menuBar_defaultAndError_areTemplateImages() {
        XCTAssertTrue(MaldariIcon.menuBar(.default).isTemplate)
        XCTAssertTrue(MaldariIcon.menuBar(.error).isTemplate)
    }
    func test_menuBar_live_isColoredNotTemplate() {
        XCTAssertFalse(MaldariIcon.menuBar(.live).isTemplate)
    }
    func test_appIcon_hasRequestedSize() {
        XCTAssertEqual(MaldariIcon.appIcon(size: 256).size, NSSize(width: 256, height: 256))
    }
}

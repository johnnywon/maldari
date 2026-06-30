import XCTest
@testable import Translator

final class DisplayChoiceTests: XCTestCase {

    /// macOS screen frames are bottom-left origin; `maxY` is the top edge.
    private func screen(_ name: String, x: CGFloat, y: CGFloat,
                        w: CGFloat = 1000, h: CGFloat = 1000) -> DisplayChoice.Screen {
        DisplayChoice.Screen(name: name, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func test_nameMatch_winsOverTopmost() {
        let screens = [
            screen("Built-in", x: 0, y: 0),        // top edge 1000
            screen("DELL", x: 1000, y: 500),       // top edge 1500 (topmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "Built-in", in: screens), 0)
    }

    func test_missingName_fallsBackToTopmost() {
        let screens = [
            screen("Built-in", x: 0, y: 0),        // 1000
            screen("DELL", x: 1000, y: 500),       // 1500 (topmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "Unplugged", in: screens), 1)
    }

    func test_emptyName_usesTopmost() {
        let screens = [
            screen("Built-in", x: 0, y: 0),        // 1000
            screen("DELL", x: 1000, y: 500),       // 1500 (topmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "", in: screens), 1)
    }

    func test_topEdgeTie_prefersLeftmost() {
        let screens = [
            screen("Right", x: 1000, y: 0),        // top 1000, minX 1000
            screen("Left", x: 0, y: 0),            // top 1000, minX 0 (leftmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "", in: screens), 1)
    }

    func test_duplicateNames_firstMatchWins() {
        let screens = [
            screen("DUP", x: 0, y: 0),             // 1000 (first match)
            screen("DUP", x: 0, y: 1000),          // 2000 (topmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "DUP", in: screens), 0)
    }

    func test_emptyScreenList_returnsNil() {
        XCTAssertNil(DisplayChoice.index(named: "", in: []))
    }
}

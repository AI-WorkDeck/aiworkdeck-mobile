import XCTest
@testable import Workdeck

final class SplitSidebarWidthTests: XCTestCase {
    func testBookFoldUsesTheLeadingUsableRegionIncludingReservedMargins() {
        // These frames are already expanded by reservedAreas(in:). The usable
        // area is asymmetric; neither half of the window nor a device constant
        // describes the leading region.
        let width = SplitSidebarWidth(size: CGSize(width: 951, height: 669),
                                      reserved: [CGRect(x: 451, y: -10, width: 48, height: 689)],
                                      minimum: 280, ideal: 320)
        XCTAssertEqual(width.minimum, 451)
        XCTAssertEqual(width.ideal, 451)
    }

    func testWindowResizeUsesTheNewFoldCoordinate() {
        let width = SplitSidebarWidth(size: CGSize(width: 760, height: 600),
                                      reserved: [CGRect(x: 310, y: 0, width: 30, height: 600)],
                                      minimum: 280, ideal: 340)
        XCTAssertEqual(width.minimum, 310)
        XCTAssertEqual(width.ideal, 310)
    }

    func testFlatCameraHorizontalFoldAndOutsideRegionsKeepTheUsualPreference() {
        let cases: [[CGRect]] = [
            [],
            [CGRect(x: 450, y: 0, width: 30, height: 30)],
            [CGRect(x: 0, y: 310, width: 951, height: 30)],
            [CGRect(x: -20, y: 0, width: 30, height: 669)],
            [CGRect(x: 960, y: 0, width: 30, height: 669)],
            [CGRect(x: 451, y: 700, width: 48, height: 669)]
        ]
        for reserved in cases {
            let width = SplitSidebarWidth(size: CGSize(width: 951, height: 669), reserved: reserved,
                                          minimum: 200, ideal: 240)
            XCTAssertEqual(width.minimum, 200)
            XCTAssertEqual(width.ideal, 240)
        }
    }
}

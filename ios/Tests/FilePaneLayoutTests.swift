import XCTest
@testable import Workdeck

final class FilePaneLayoutTests: XCTestCase {
    func testWideReaderHasFileListButNarrowReaderKeepsFullWidth() {
        let wide = FilePaneGeometry(size: CGSize(width: 900, height: 620), reserved: [], reading: true, showList: false, focus: false)
        XCTAssertTrue(wide.listVisible && wide.readerVisible)
        XCTAssertGreaterThan(wide.reader.width, wide.list.width)
        let narrow = FilePaneGeometry(size: CGSize(width: 400, height: 650), reserved: [], reading: true, showList: false, focus: false)
        XCTAssertFalse(narrow.listVisible)
        XCTAssertEqual(narrow.reader, CGRect(x: 0, y: 0, width: 400, height: 650))
    }

    func testBookFoldUsesActualDivisionRatherThanFixedProportion() {
        let fold = CGRect(x: 431, y: 0, width: 38, height: 620)
        let panes = FilePaneGeometry(size: CGSize(width: 900, height: 620), reserved: [fold], reading: true, showList: false, focus: false)
        XCTAssertEqual(panes.list.maxX, fold.minX)
        XCTAssertEqual(panes.reader.minX, fold.maxX)
        XCTAssertFalse(panes.list.intersects(fold))
        XCTAssertFalse(panes.reader.intersects(fold))
    }

    func testTabletopReadingAboveListAndFocusCanReturnToList() {
        let fold = CGRect(x: 0, y: 432, width: 620, height: 36)
        let panes = FilePaneGeometry(size: CGSize(width: 620, height: 900), reserved: [fold], reading: true, showList: false, focus: false)
        XCTAssertEqual(panes.reader.maxY, fold.minY)
        XCTAssertEqual(panes.list.minY, fold.maxY)
        let list = FilePaneGeometry(size: CGSize(width: 400, height: 650), reserved: [], reading: true, showList: true, focus: true)
        XCTAssertTrue(list.listVisible)
        XCTAssertFalse(list.readerVisible)
        XCTAssertEqual(list.reader.width, 400, "Hidden reader retains its viewport rather than being collapsed to zero")
    }
    func testFocusAndListOnlyStillAvoidTheActiveFold() {
        let fold = CGRect(x: 431, y: 0, width: 38, height: 620)
        let focused = FilePaneGeometry(size: CGSize(width: 900, height: 620), reserved: [fold], reading: true, showList: false, focus: true)
        XCTAssertFalse(focused.reader.intersects(fold))
        XCTAssertFalse(focused.listVisible)
        let listOnly = FilePaneGeometry(size: CGSize(width: 900, height: 620), reserved: [fold], reading: false, showList: false, focus: false)
        XCTAssertFalse(listOnly.list.intersects(fold))
    }

    func testSystemRailOutsideSafeAreaDoesNotBecomeAFold() {
        let panes = FilePaneGeometry(size: CGSize(width: 382, height: 616),
                                     reserved: [CGRect(x: 400, y: 1, width: 37, height: 37), CGRect(x: 382, y: -28, width: 84, height: 170)],
                                     reading: true, showList: false, focus: false)
        XCTAssertEqual(panes.reader, CGRect(x: 0, y: 0, width: 382, height: 616))
    }

    func testFocusUsesTheLargerSideOfAnAsymmetricWindow() {
        let panes = FilePaneGeometry(size: CGSize(width: 382, height: 616),
                                     reserved: [CGRect(x: 340, y: 0, width: 20, height: 616)],
                                     reading: true, showList: false, focus: true)
        XCTAssertEqual(panes.reader.width, 340)
    }

}

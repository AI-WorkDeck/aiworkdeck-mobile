import XCTest
@testable import Workdeck

final class LibraryGroupingTests: XCTestCase {
    let a = RelayProject(deviceId: "d", deviceName: nil, key: "1", name: "甲项目")
    let b = RelayProject(deviceId: "d", deviceName: nil, key: "2", name: "乙项目")

    func testCatalogAliasesKeepLegacyCapturesVisibleWithoutRerouting() throws {
        let data = Data(#"{"projectUid":"uid","name":"Unified","locations":[{"kind":"desktop","deviceId":"d","key":"1","online":false},{"kind":"desktop","deviceId":"new-device","key":"5","online":true},{"kind":"cloud","deviceId":"cloud","key":"9","online":true,"archiveOnly":true}]}"#.utf8)
        let current = try JSONDecoder().decode(RelayProject.self, from: data)
        let item = TestItems.make(.uploaded, project: a)
        XCTAssertEqual(current.deviceId, "new-device")
        XCTAssertEqual(LibraryGrouping.projects(in: [item], current: current).map(\.id), ["uid"])
        XCTAssertEqual(LibraryGrouping.items([item], in: "uid", project: current).count, 1)
        XCTAssertEqual(item.project?.deviceId, "d")
        let saved = try JSONDecoder().decode(RelayProject.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(saved, current)
    }

    func testProjectsCurrentFirstUnknownLast() {
        let items = [
            TestItems.make(.arrived, project: b),
            TestItems.make(.arrived, project: nil),
            TestItems.make(.arrived, project: a),
        ]
        let ps = LibraryGrouping.projects(in: items, current: a)
        XCTAssertEqual(ps.map(\.id), [a.id, b.id, LibraryProject.unknownID])
        XCTAssertEqual(ps.last?.name, tr("library.unknownProject"))
    }

    func testProjectsIncludesCurrentEvenWithoutItems() {
        let ps = LibraryGrouping.projects(in: [TestItems.make(.arrived, project: b)], current: a)
        XCTAssertEqual(ps.map(\.id), [a.id, b.id])
    }

    func testItemsInProject() {
        let items = [TestItems.make(.arrived, project: a), TestItems.make(.arrived, project: b),
                     TestItems.make(.arrived, project: nil)]
        XCTAssertEqual(LibraryGrouping.items(items, in: a.id).count, 1)
        XCTAssertEqual(LibraryGrouping.items(items, in: LibraryProject.unknownID).count, 1)
    }

    func testDaysNewestFirstAndTitle() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let d1 = cal.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 10))!
        let d2 = cal.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 9))!
        let d2b = cal.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 15))!
        let items = [TestItems.make(.arrived, at: d1), TestItems.make(.arrived, at: d2),
                     TestItems.make(.arrived, at: d2b)]
        let days = LibraryGrouping.days(items, calendar: cal)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].title, "9月2日 · 2 件")
        XCTAssertEqual(days[0].items.map(\.capturedAt), [d2b, d2])
        XCTAssertEqual(days[1].title, "9月1日 · 1 件")
    }

    func testDeleteWarningByWorstPhase() {
        let landed = [TestItems.make(.arrived), TestItems.make(.arrived)]
        XCTAssertEqual(LibraryGrouping.deleteWarning(for: landed), "删除 2 件本地原图？电脑上已有副本。")
        let staged = landed + [TestItems.make(.uploaded)]
        XCTAssertEqual(LibraryGrouping.deleteWarning(for: staged),
                       "其中 1 件电脑还没取回。中转区 30 天后清理，电脑若未及时接收，这些影像将无法找回。")
        let uploading = staged + [TestItems.make(.failed), TestItems.make(.waiting)]
        XCTAssertEqual(LibraryGrouping.deleteWarning(for: uploading),
                       "其中 2 件还没送出去。删了就没了，无法找回。")
    }
}

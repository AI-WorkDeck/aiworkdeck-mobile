import XCTest
@testable import Workdeck

final class ProjectFileDirectoryTests: XCTestCase {
    func testNestedFoldersKeepIdenticalNamesDistinctAndIncludeEmptyFolders() {
        let directory = ProjectFileDirectory(files: [
            RemoteProjectFile(id: "1", name: "same.pdf", path: "A/Deep/same.pdf", size: 3),
            RemoteProjectFile(id: "2", name: "same.pdf", path: "B/same.pdf", size: 3),
            RemoteProjectFile(id: "3", name: "root.pdf", path: "root.pdf", size: 3),
            RemoteProjectFile(id: "4", name: "Empty", path: "A/Empty", size: 0, isFolder: true),
            RemoteProjectFile(id: "5", name: "windows.pdf", path: "B\\windows.pdf", size: 3)
        ])
        XCTAssertEqual(directory.folders(in: "").map(\.path), ["A", "B"])
        XCTAssertEqual(directory.folders(in: "A").map(\.path), ["A/Deep", "A/Empty"])
        XCTAssertEqual(directory.files(in: "", matching: "").map(\.id), ["3"])
        XCTAssertEqual(directory.files(in: "A/Deep", matching: "").map(\.id), ["1"])
        XCTAssertEqual(directory.files(in: "B", matching: "").map(\.id), ["2", "5"])
        XCTAssertTrue(directory.files(in: "A/Empty", matching: "").isEmpty)
        XCTAssertEqual(Set(directory.files(in: "", matching: "same").map(\.id)), ["1", "2"])
    }

    func testPreviewWhitelistRejectsLegacyOfficeArchivesAndDoubleExtensions() {
        for name in ["photo.JPG", "scan.HEIC", "memo.docx", "slides.pptx", "sheet.xlsx", "scan.pdf", "audio.m4a", "video.mov"] {
            XCTAssertTrue(RemoteProjectFile(id: name, name: name, path: name, size: 3).supportsPreview, name)
        }
        for name in ["notes.txt", "script.js", "archive.zip", "old.doc", "old.ppt", "old.xls", "image.jpg.exe", "README", "vector.svg"] {
            XCTAssertFalse(RemoteProjectFile(id: name, name: name, path: name, size: 3).supportsPreview, name)
        }
        XCTAssertFalse(RemoteProjectFile(id: "folder", name: "folder.pdf", path: "folder.pdf", size: 0, isFolder: true).supportsPreview)
    }
}

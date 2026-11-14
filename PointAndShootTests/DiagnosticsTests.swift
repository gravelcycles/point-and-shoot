import XCTest
@testable import PointAndShoot

/// The development log the owner shares from Settings → Diagnostics.
final class DiagnosticsTests: XCTestCase {
    func testLinesAreKeptAndShareable() throws {
        let marker = "test-marker-\(UUID().uuidString.prefix(6))"
        Diag.log(.app, marker)
        Diag.error(.save, "failed thing", NSError(domain: "PHPhotosErrorDomain", code: 3300))
        Diag.flush()

        let got = expectation(description: "text")
        var text = ""
        Diag.text { text = $0; got.fulfill() }
        wait(for: [got], timeout: 5)
        XCTAssertTrue(text.contains(marker))
        XCTAssertTrue(text.contains("[save] ⚠︎ failed thing"), "errors are flagged")
        XCTAssertTrue(text.contains("PHPhotosErrorDomain 3300"), "errors carry domain and code")
        XCTAssertTrue(text.contains("build:"), "the header names the build")
        XCTAssertTrue(text.contains("access: camera"), "the header lists permissions")

        let exported = expectation(description: "file")
        var url: URL?
        Diag.exportFile { url = $0; exported.fulfill() }
        wait(for: [exported], timeout: 5)
        let file = try XCTUnwrap(url)
        XCTAssertEqual(file.pathExtension, "txt")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(marker))
    }

    func testLogSurvivesToTheFileForTheNextLaunch() throws {
        let marker = "persist-\(UUID().uuidString.prefix(6))"
        Diag.log(.app, marker)
        Diag.flush()
        XCTAssertTrue(try String(contentsOf: Diag.fileURL, encoding: .utf8).contains(marker))
    }
}

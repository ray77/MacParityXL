import ParityKit
import XCTest
@testable import MacParityXL

@MainActor
final class ParSetModelTests: XCTestCase {
    func testAddingFilesFromDifferentFoldersIsRejected() {
        let model = ParSetModel(format: .par2)
        let a = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let b = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for folder in [a, b] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appending(path: "x.bin").path, contents: Data([1]))
        }
        XCTAssertNil(model.addFiles([a.appending(path: "x.bin")]))
        XCTAssertNotNil(model.addFiles([b.appending(path: "x.bin")]))
        XCTAssertEqual(model.files.map(\.name), ["x.bin"])
        XCTAssertEqual(model.suggestedParFileName, "x.par2")
    }
}

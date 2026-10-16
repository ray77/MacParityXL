import Foundation
import Testing
@testable import ParityKit

/// Fixtures are real par2cmdline-turbo 1.5.0 transcripts, including `\r` progress lines.
struct Par2OutputParserTests {
    private func events(forFixture name: String) throws -> (events: [Par2Event], parser: Par2OutputParser) {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        var splitter = LineSplitter()
        var parser = Par2OutputParser()
        let lines = splitter.append(try Data(contentsOf: url)) + splitter.finish()
        return (lines.flatMap { parser.parse(line: $0) }, parser)
    }

    private func targetStates(_ events: [Par2Event]) -> [String: TargetFileState] {
        var states: [String: TargetFileState] = [:]
        for case let .target(name, state) in events {
            states[name] = state
        }
        return states
    }

    @Test func verifyAllCorrect() throws {
        let (events, parser) = try events(forFixture: "par2-verify-ok")
        #expect(targetStates(events) == ["file 1.bin": .ok, "file 2.bin": .ok, "file 3.bin": .ok])
        #expect(events.last == .outcome(.allFilesCorrect))
        #expect(parser.statistics.recoverableFileCount == 3)
        #expect(parser.statistics.blockSize > 0)
        #expect(parser.statistics.totalDataBytes == 900_000)
    }

    @Test func verifyWithTooFewBlocks() throws {
        let (events, parser) = try events(forFixture: "par2-verify-insufficient")
        let states = targetStates(events)
        #expect(states["file 1.bin"] == .missing)
        #expect(states["file 3.bin"] == .missing)
        guard case .damaged(let found, let total) = states["file 2.bin"] else {
            Issue.record("file 2.bin should be damaged")
            return
        }
        #expect(found + 1 == total)

        let needed = try #require(parser.statistics.missingRecoveryBlocks)
        #expect(events.contains(.outcome(.repairNotPossible(neededBlocks: needed))))
        #expect(parser.statistics.missingBytes == Int64(needed) * Int64(parser.statistics.blockSize))
    }

    @Test func repairWithRenamedAndDamagedFile() throws {
        let (events, _) = try events(forFixture: "par2-repair-ok")
        #expect(events.contains(.renamedMatch(actual: "renamed.bin", target: "file 3.bin")))
        #expect(targetStates(events)["file 3.bin"] == .okAfterRenaming(from: "renamed.bin"))
        #expect(events.contains(.outcome(.repairPossible)))
        #expect(events.contains(.repairingStarted))
        #expect(targetStates(events)["file 2.bin"] == .repaired)
        #expect(events.last == .outcome(.repaired))
    }

    @Test func invalidParFile() throws {
        let (events, _) = try events(forFixture: "par2-invalid")
        #expect(events.last == .outcome(.invalidParFile))
    }

    @Test func progressLines() {
        var parser = Par2OutputParser()
        #expect(parser.parse(line: "Repairing: 42.5%") == [.progress(phase: "Repairing", percent: 42.5)])
    }

    @Test func createReadingLines() {
        var parser = Par2OutputParser()
        #expect(parser.parse(line: "Source file count: 301") == [.sourceFileCount(301), .other("Source file count: 301")])
        #expect(parser.parse(line: "Opening: sub dir/x.bin") == [.openingFile("sub dir/x.bin"), .other("Opening: sub dir/x.bin")])
        #expect(parser.parse(line: "Opening: \"f1.bin\"").first == .openingFile("f1.bin"))
        #expect(parser.parse(line: "Opening:  lead.bin").first == .openingFile(" lead.bin"))
    }

    @Test func fileListArguments() {
        let par = URL(fileURLWithPath: "/x/set.par2")
        let files = [URL(fileURLWithPath: "/x/a.bin"), URL(fileURLWithPath: "/x/new\nline.bin")]
        let command = Par2Command.create(parFile: par, sourceFiles: files, options: Par2CreateOptions())
        let list = URL(fileURLWithPath: "/tmp/list.txt")
        #expect(command.arguments(fileList: list).suffix(4) == ["--", "/x/set.par2", "@/tmp/list.txt", "/x/new\nline.bin"])
        #expect(command.fileListContents == "/x/a.bin\n")
        #expect(command.arguments.suffix(2) == ["/x/a.bin", "/x/new\nline.bin"])
    }

    /// More source paths than fit on a command line (ARG_MAX is 1 MiB) used to crash the app.
    @Test func createsSetWithHugeFileList() async throws {
        let par2 = URL(fileURLWithPath: #filePath).appending(path: "../../../../../Vendor/build/bin/par2").standardized
        guard FileManager.default.isExecutableFile(atPath: par2.path) else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "par2-many-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stem = String(repeating: "long name ", count: 22)
        let sources = try (0..<5000).map { index in
            let url = folder.appending(path: "\(stem)\(index).bin")
            try Data("file \(index)".utf8).write(to: url)
            return url
        }
        #expect(sources.map(\.path.utf8.count).reduce(0, +) > 1 << 20)

        let process = Par2Process(executable: par2, command: .create(parFile: folder.appending(path: "set.par2"), sourceFiles: sources, options: Par2CreateOptions()))
        var opened = 0
        var count = 0
        var exit: Int32 = -1
        var batches = 0
        for await batch in try process.run() {
            batches += 1
            for update in batch {
                switch update {
                case .event(.openingFile): opened += 1
                case .event(.sourceFileCount(let n)): count = n
                case .finished(let code, _): exit = code
                default: break
                }
            }
        }
        // Thousands of lines, delivered in a handful of batches.
        #expect(batches < 100)
        #expect(exit == 0)
        #expect(count == 5000)
        #expect(opened == 5000)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        #expect(!leftovers.contains { $0.hasPrefix("MacParityXL-files-") })
    }

    @Test func splitterHandlesCarriageReturnsAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("Scanning: 1.0%\rScan".utf8)) == ["Scanning: 1.0%"])
        #expect(splitter.append(Data("ning: 2.0%\r\nDone\n".utf8)) == ["Scanning: 2.0%", "Done"])
        #expect(splitter.finish() == [])
    }
}

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

    @Test func splitterHandlesCarriageReturnsAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("Scanning: 1.0%\rScan".utf8)) == ["Scanning: 1.0%"])
        #expect(splitter.append(Data("ning: 2.0%\r\nDone\n".utf8)) == ["Scanning: 2.0%", "Done"])
        #expect(splitter.finish() == [])
    }
}

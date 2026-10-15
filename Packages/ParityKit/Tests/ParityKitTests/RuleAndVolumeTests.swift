import Foundation
import Testing
@testable import ParityKit

struct PostProcessRuleTests {
    @Test func firstMatchingRuleWins() {
        let files = ["movie.part01.rar", "movie.part02.rar", "readme.zip"]
        let match = PostProcessRule.firstMatch(in: PostProcessRule.standardRules, fileNames: files)
        #expect(match?.rule.name == "Zip archive")
        #expect(match?.fileName == "readme.zip")
    }

    @Test func endsWithRespectsCase() {
        var rule = PostProcessRule(name: "x", relation: .endsWith, pattern: ".RAR", ignoresCase: false, action: .builtInUnrar)
        #expect(!rule.matches(fileName: "a.rar"))
        rule.ignoresCase = true
        #expect(rule.matches(fileName: "a.rar"))
        #expect(!rule.matches(fileName: "a.rar.txt"))
    }

    @Test func macroExpansion() {
        let rule = PostProcessRule(name: "x", relation: .endsWith, pattern: ".sit.1", action: .commandLine(""))
        let file = URL(fileURLWithPath: "/Volumes/Data/It's here/archive.sit.1")
        let command = Macro.expand("unstuff «F» -d «D» -n «A» «K»", file: file, rule: rule)
        #expect(command == #"unstuff '/Volumes/Data/It'\''s here/archive.sit.1' -d '/Volumes/Data/It'\''s here' -n 'archive' 'archive.sit'"#)
    }
}

struct RarVolumesTests {
    @Test(arguments: [
        ("a.rar", true), ("a.r00", false), ("a.part1.rar", true), ("a.part01.rar", true),
        ("a.part02.rar", false), ("a.part001.exe", true), ("a.part10.rar", false), ("a.001", true), ("a.002", false),
    ])
    func firstVolume(name: String, expected: Bool) {
        #expect(RarVolumes.isFirstVolume(name) == expected)
    }

    @Test func segmentsOfOldStyleArchive() {
        let files = ["a.rar", "a.r00", "a.r01", "b.rar", "a.nfo", "a.par2"]
        #expect(RarVolumes.segments(of: "a.rar", in: files) == ["a.rar", "a.r00", "a.r01"])
    }

    @Test func segmentsOfPartArchive() {
        let files = ["x.part01.rar", "x.part02.rar", "x.part03.rar", "x.nfo", "y.part01.rar"]
        #expect(RarVolumes.segments(of: "x.part01.rar", in: files) == ["x.part01.rar", "x.part02.rar", "x.part03.rar"])
    }

    @Test func finderSort() {
        #expect(["a.sit.10", "a.sit.2", "a.sit.1"].finderSorted() == ["a.sit.1", "a.sit.2", "a.sit.10"])
    }
}

struct Par2FileReaderTests {
    @Test func readsFileDescriptions() throws {
        let url = try #require(Bundle.module.url(forResource: "set", withExtension: "par2", subdirectory: "Fixtures"))
        let files = try Par2FileReader.fileDescriptions(in: url)
        #expect(files.map(\.name) == ["file 1.bin", "file 2.bin", "file 3.bin"])
        #expect(files.allSatisfy { $0.length == 300_000 })
    }

    @Test func shortFileDescPacketDoesNotCrash() {
        var packet = Data("PAR2\0PKT".utf8)
        packet.append(contentsOf: [64, 0, 0, 0, 0, 0, 0, 0])
        packet.append(Data(count: 32))
        packet.append(Data("PAR 2.0\0FileDesc".utf8))
        #expect(Par2FileReader.fileDescriptions(in: packet).isEmpty)
    }

    @Test func escapesTraversalNames() {
        #expect(Par2FileReader.displayName("../evil.bin") == "%2E%2E/evil.bin")
        #expect(Par2FileReader.displayName("/etc/x") == "etc/x")
        #expect(Par2FileReader.displayName("sub/file.bin") == "sub/file.bin")
    }

    @Test func ignoresNonParData() {
        #expect(Par2FileReader.fileDescriptions(in: Data(repeating: 0x41, count: 4096)).isEmpty)
    }
}

import Foundation
import Testing
@testable import ParityKit

/// Fixtures/par1 was created by the reference par-cmdline 1.1:
/// `par a -n3 set.par alpha.bin "beta file.bin" gamma.txt +i info.nfo`
/// (info.nfo is listed but does not contribute to the recovery volumes).
struct Par1Tests {
    /// A private copy of the fixture set, so tests can damage it.
    private func fixtureCopy() throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "par1", withExtension: nil, subdirectory: "Fixtures"))
        let copy = FileManager.default.temporaryDirectory.appending(path: "par1-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func contents(_ folder: URL, _ name: String) throws -> Data {
        try Data(contentsOf: folder.appending(path: name))
    }

    @Test func readsHeader() throws {
        let folder = try fixtureCopy()
        let header = try Par1Header.read(from: folder.appending(path: "set.par"))
        #expect(header.volumeNumber == 0)
        #expect(header.entries.map(\.name) == ["alpha.bin", "beta file.bin", "gamma.txt", "info.nfo"])
        #expect(header.entries.map(\.isProtected) == [true, true, true, false])
        #expect(header.setHash == Par1Header.setHash(for: header.entries))

        let volume = try Par1Header.read(from: folder.appending(path: "set.p02"))
        #expect(volume.volumeNumber == 2)
        #expect(volume.dataSize == 5000)
    }

    @Test func rejectsDamagedVolume() throws {
        let folder = try fixtureCopy()
        let url = folder.appending(path: "set.p01")
        var data = try Data(contentsOf: url)
        data[data.count - 10] ^= 0xFF
        try data.write(to: url)
        #expect(throws: Par1Header.ReadError.controlHashMismatch) { try Par1Header.read(from: url) }
    }

    @Test func intactSetNeedsNothing() throws {
        let folder = try fixtureCopy()
        let scan = try Par1Engine().scan(parFile: folder.appending(path: "set.par"))
        #expect(scan.files.allSatisfy { $0.state == .ok })
        #expect(scan.files.map(\.contributesToParity) == [true, true, true, false])
        #expect(scan.volumes.map(\.number) == [1, 2, 3])
        #expect(scan.filesToRestore.isEmpty)
    }

    @Test func repairsMissingDamagedAndMisnamedFiles() throws {
        let folder = try fixtureCopy()
        let alpha = try contents(folder, "alpha.bin")
        let beta = try contents(folder, "beta file.bin")
        let gamma = try contents(folder, "gamma.txt")

        try FileManager.default.removeItem(at: folder.appending(path: "alpha.bin"))
        var damaged = beta
        damaged[100] ^= 0x55
        try damaged.write(to: folder.appending(path: "beta file.bin"))
        try FileManager.default.moveItem(at: folder.appending(path: "gamma.txt"), to: folder.appending(path: "renamed"))
        // Leave only volumes 2 and 3 so a non-trivial matrix has to be inverted.
        try FileManager.default.removeItem(at: folder.appending(path: "set.p01"))

        let engine = Par1Engine()
        let scan = try engine.scan(parFile: folder.appending(path: "set.par"))
        #expect(scan.files[0].state == .recoverable(wasMissing: true))
        #expect(scan.files[1].state == .recoverable(wasMissing: false))
        #expect(scan.files[2].state == .okAfterRenaming(from: "renamed"))
        #expect(scan.filesToRestore == [0, 1])

        let result = try engine.repair(scan)
        #expect(result.files.prefix(3).map(\.state) == [.repaired, .repaired, .okAfterRenaming(from: "renamed")])
        #expect(try contents(folder, "alpha.bin") == alpha)
        #expect(try contents(folder, "beta file.bin") == beta)
        #expect(try contents(folder, "gamma.txt") == gamma)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "beta file.bin.bad").path))
    }

    @Test func reportsMissingVolumes() throws {
        let folder = try fixtureCopy()
        for name in ["alpha.bin", "beta file.bin", "set.p01", "set.p02"] {
            try FileManager.default.removeItem(at: folder.appending(path: name))
        }
        let engine = Par1Engine()
        let scan = try engine.scan(parFile: folder.appending(path: "set.par"))
        #expect(scan.missingVolumeCount == 1)
        #expect(scan.files[0].state == .unrecoverable(wasMissing: true))
        #expect(throws: Par1Engine.Par1Error.self) { try engine.repair(scan) }
    }

    @Test func unprotectedFileIsNotRestorable() throws {
        let folder = try fixtureCopy()
        try FileManager.default.removeItem(at: folder.appending(path: "info.nfo"))
        let scan = try Par1Engine().scan(parFile: folder.appending(path: "set.par"))
        #expect(scan.filesToRestore.isEmpty)
        #expect(scan.unprotectedProblems == 1)
        #expect(scan.files[3].state == .unrecoverable(wasMissing: true))
    }

    /// Our volumes must carry exactly the recovery data the reference produced.
    @Test func createdVolumesMatchReference() throws {
        let folder = try fixtureCopy()
        let output = folder.appending(path: "ours")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let names = ["alpha.bin", "beta file.bin", "gamma.txt"]
        for name in names {
            try FileManager.default.copyItem(at: folder.appending(path: name), to: output.appending(path: name))
        }
        try Par1Engine().create(parFile: output.appending(path: "set.par"), sources: names.map { output.appending(path: $0) }, recoveryCount: 3)

        for number in 1...3 {
            let ours = try Par1Header.read(from: output.appending(path: String(format: "set.p%02d", number)))
            let theirs = try Par1Header.read(from: folder.appending(path: String(format: "set.p%02d", number)))
            let ourData = try contents(output, String(format: "set.p%02d", number)).dropFirst(Int(ours.dataOffset))
            let theirData = try contents(folder, String(format: "set.p%02d", number)).dropFirst(Int(theirs.dataOffset))
            #expect(ourData == theirData)
        }
    }

    @Test func volumeNames() {
        let par = URL(fileURLWithPath: "/x/set.par")
        #expect(Par1Header.volumeURL(for: par, number: 1).lastPathComponent == "set.p01")
        #expect(Par1Header.volumeURL(for: par, number: 120).lastPathComponent == "set.p120")
    }

    @Test func gf256Inverse() throws {
        let matrix: [[UInt8]] = [[1, 1], [GF256.coefficient(rank: 1, volume: 2), GF256.coefficient(rank: 2, volume: 2)]]
        let inverse = try #require(GF256.invert(matrix))
        for i in 0..<2 {
            for j in 0..<2 {
                let product = (0..<2).reduce(UInt8(0)) { $0 ^ GF256.multiply(matrix[i][$1], inverse[$1][j]) }
                #expect(product == (i == j ? 1 : 0))
            }
        }
        #expect(GF256.invert([[1, 1], [1, 1]]) == nil)
    }
}

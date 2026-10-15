import Foundation

/// Verifies, repairs and creates PAR 1.0 sets (`.par` + `.p01`, `.p02`, …).
///
/// Recovery volume `j` holds Σ coefficient(rank, j) · file for every protected file,
/// byte by byte over GF(2^8), zero-padded to the largest protected file. Any `n`
/// independent volumes restore `n` missing or damaged protected files.
///
/// All methods run synchronously and may take long; call them off the main thread.
public final class Par1Engine: @unchecked Sendable {
    public struct Volume: Sendable {
        public var url: URL
        public var number: Int
        public var header: Par1Header
    }

    /// Result of checking a set against the files in its folder.
    public struct Scan: Sendable {
        public var parFile: URL
        public var entries: [Par1Entry]
        public var files: [TargetFile]
        /// Volumes with a valid control hash that belong to this set, by volume number.
        public var volumes: [Volume]
        /// PAR files of this set (by name) whose control hash is wrong.
        public var damagedVolumes: [URL]
        /// Where the correct data of an entry is, by entry index. Misnamed files point at the actual name.
        var goodData: [Int: URL]

        public var folder: URL { parFile.deletingLastPathComponent() }

        /// Protected entries that are missing or damaged.
        public var filesToRestore: [Int] {
            entries.indices.filter { entries[$0].isProtected && goodData[$0] == nil }
        }

        public var unprotectedProblems: Int {
            entries.indices.filter { !entries[$0].isProtected && goodData[$0] == nil }.count
        }

        public var needsRenaming: Bool {
            files.contains { if case .okAfterRenaming = $0.state { true } else { false } }
        }

        /// How many more recovery volumes a repair needs (0 if enough are present).
        public var missingVolumeCount: Int {
            max(0, filesToRestore.count - volumes.count)
        }
    }

    public enum Par1Error: LocalizedError {
        case notEnoughVolumes(needed: Int)
        case verificationFailed(String)
        case tooManyFiles
        case canceled

        public var errorDescription: String? {
            switch self {
            case .notEnoughVolumes(let needed): "Cannot restore; need \(needed) more recovery files."
            case .verificationFailed(let name): "Restored file “\(name)” failed the MD5 check."
            case .tooManyFiles: "A PAR1 set can hold at most 255 files."
            case .canceled: "Canceled"
            }
        }
    }

    /// Phase name and fraction done (0…1).
    public var progressHandler: (@Sendable (String, Double) -> Void)?
    /// Human-readable log lines, for the raw output view.
    public var logHandler: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var canceled = false
    private static let chunkSize = 1 << 20

    public init() {}

    public func cancel() {
        lock.withLock { canceled = true }
    }

    private func checkCanceled() throws {
        if lock.withLock({ canceled }) { throw Par1Error.canceled }
    }

    private func log(_ line: String) {
        logHandler?(line)
    }

    // MARK: - Scan

    public func scan(parFile: URL) throws -> Scan {
        let header = try Par1Header.read(from: parFile)
        let folder = parFile.deletingLastPathComponent()
        let folderFiles = Self.regularFiles(in: folder)
        log("Loaded \(header.entries.count) file entries from \(parFile.lastPathComponent).")

        var goodData: [Int: URL] = [:]
        var states: [TargetFileState] = []
        var claimed = Set<String>()
        let totalBytes = max(1, header.entries.reduce(0) { $0 + $1.size })
        var hashedBytes: UInt64 = 0

        // Files under their own name first.
        for entry in header.entries {
            try checkCanceled()
            let url = folder.appending(path: entry.name)
            guard let size = Self.fileSize(url) else {
                states.append(.missing)
                continue
            }
            if size == entry.size {
                let digest = try FileDigest.md5s(of: url, isCanceled: { self.lock.withLock { self.canceled } }) { done in
                    hashedBytes += done
                    self.progressHandler?("Verifying", Double(hashedBytes) / Double(totalBytes))
                }
                if digest.full == entry.md5 {
                    goodData[states.count] = url
                    claimed.insert(entry.name)
                    states.append(.ok)
                    log("Target: \"\(entry.name)\" - found.")
                    continue
                }
            }
            states.append(.damaged(foundBlocks: 0, totalBlocks: 0))
        }

        // Then look for misnamed copies among the other files.
        for index in header.entries.indices where goodData[index] == nil {
            try checkCanceled()
            let entry = header.entries[index]
            let candidates = folderFiles.filter { !claimed.contains($0.lastPathComponent) && Self.fileSize($0) == entry.size }
            for candidate in candidates {
                guard (try? FileDigest.md5First16K(of: candidate)) == entry.md5First16K,
                      (try? FileDigest.md5s(of: candidate).full) == entry.md5 else { continue }
                goodData[index] = candidate
                claimed.insert(candidate.lastPathComponent)
                states[index] = .okAfterRenaming(from: candidate.lastPathComponent)
                log("File: \"\(candidate.lastPathComponent)\" - is a match for \"\(entry.name)\".")
                break
            }
            if goodData[index] == nil {
                log("Target: \"\(entry.name)\" - \(states[index] == .missing ? "missing" : "damaged").")
            }
        }

        let (volumes, damaged) = try findVolumes(for: header, parFile: parFile, in: folderFiles)
        log("Found \(volumes.count) usable recovery volume(s)\(damaged.isEmpty ? "" : ", \(damaged.count) damaged").")

        var scan = Scan(
            parFile: parFile,
            entries: header.entries,
            files: zip(header.entries, states).map { TargetFile(name: $0.name, state: $1, contributesToParity: $0.isProtected) },
            volumes: volumes,
            damagedVolumes: damaged,
            goodData: goodData
        )
        let canRepair = scan.missingVolumeCount == 0
        for index in scan.files.indices where goodData[index] == nil {
            let wasMissing = scan.files[index].state == .missing
            let recoverable = scan.entries[index].isProtected && canRepair
            scan.files[index].state = recoverable ? .recoverable(wasMissing: wasMissing) : .unrecoverable(wasMissing: wasMissing)
        }
        return scan
    }

    /// Recovery volumes of the set: files named like the set, plus any PAR file with the same set hash.
    private func findVolumes(for header: Par1Header, parFile: URL, in files: [URL]) throws -> ([Volume], [URL]) {
        var volumes: [Int: Volume] = [:]
        var damaged: [URL] = []
        let base = parFile.deletingPathExtension().lastPathComponent.lowercased()

        for url in files {
            try checkCanceled()
            guard Self.hasParMagic(url) else { continue }
            do {
                let volumeHeader = try Par1Header.read(from: url)
                guard volumeHeader.setHash == header.setHash, volumeHeader.volumeNumber > 0,
                      volumes[volumeHeader.volumeNumber] == nil else { continue }
                volumes[volumeHeader.volumeNumber] = Volume(url: url, number: volumeHeader.volumeNumber, header: volumeHeader)
                log("Loading \"\(url.lastPathComponent)\" - volume \(volumeHeader.volumeNumber).")
            } catch Par1Header.ReadError.controlHashMismatch {
                if url.deletingPathExtension().lastPathComponent.lowercased() == base {
                    damaged.append(url)
                    log("Loading \"\(url.lastPathComponent)\" - damaged, ignored.")
                }
            } catch {
                continue
            }
        }
        return (volumes.values.sorted { $0.number < $1.number }, damaged)
    }

    // MARK: - Repair

    /// Renames misnamed files and rebuilds missing or damaged ones. Returns a fresh scan.
    @discardableResult
    public func repair(_ scan: Scan) throws -> Scan {
        let folder = scan.folder
        var goodData = scan.goodData
        var renamedFrom: [Int: String] = [:]

        // Misnamed files go back to their proper names; damaged copies are moved aside.
        for (index, url) in scan.goodData where url.lastPathComponent != scan.entries[index].name {
            let target = folder.appending(path: scan.entries[index].name)
            try moveAside(target)
            try FileManager.default.moveItem(at: url, to: target)
            goodData[index] = target
            renamedFrom[index] = url.lastPathComponent
            log("Renamed \"\(url.lastPathComponent)\" to \"\(target.lastPathComponent)\".")
        }

        let unknown = scan.filesToRestore
        guard !unknown.isEmpty else { return try rescan(scan, renamedFrom: renamedFrom, restored: []) }

        let known = scan.entries.indices.filter { scan.entries[$0].isProtected && goodData[$0] != nil }
        let coefficients = scan.volumes.map { coefficientRow(for: $0, entries: scan.entries) }

        // Pick volumes whose rows are independent for the unknown files.
        var chosen: [Int] = []
        var basis: [[UInt8]] = []
        for (volumeIndex, row) in coefficients.enumerated() where chosen.count < unknown.count {
            let reduced = unknown.map { row[$0] }
            if Self.addIfIndependent(reduced, to: &basis) {
                chosen.append(volumeIndex)
            }
        }
        guard chosen.count == unknown.count,
              let inverse = GF256.invert(chosen.map { v in unknown.map { coefficients[v][$0] } }) else {
            throw Par1Error.notEnoughVolumes(needed: max(1, unknown.count - chosen.count))
        }

        // Output m = Σ_j inv[m][j] · (V_j − Σ_k c(j,k) · F_k)
        var inputs: [(url: URL, offset: UInt64, length: UInt64, multipliers: [UInt8])] = []
        for (j, volumeIndex) in chosen.enumerated() {
            let volume = scan.volumes[volumeIndex]
            inputs.append((volume.url, volume.header.dataOffset, volume.header.dataSize, unknown.indices.map { inverse[$0][j] }))
        }
        for k in known {
            let multipliers = unknown.indices.map { m in
                chosen.indices.reduce(UInt8(0)) { $0 ^ GF256.multiply(inverse[m][$1], coefficients[chosen[$1]][k]) }
            }
            inputs.append((goodData[k]!, 0, scan.entries[k].size, multipliers))
        }

        let outputs = unknown.map { scan.entries[$0] }
        let temporaries = outputs.map { folder.appending(path: ".\($0.name).macparity-restore") }
        log("Restoring \(outputs.count) file(s) from \(chosen.count) recovery volume(s).")
        try combine(inputs: inputs, outputs: temporaries, outputSizes: outputs.map(\.size), phase: "Repairing")

        for (entry, temporary) in zip(outputs, temporaries) {
            guard try FileDigest.md5s(of: temporary).full == entry.md5 else {
                try? FileManager.default.removeItem(at: temporary)
                throw Par1Error.verificationFailed(entry.name)
            }
            let target = folder.appending(path: entry.name)
            try moveAside(target)
            try FileManager.default.moveItem(at: temporary, to: target)
            log("Target: \"\(entry.name)\" - recovered.")
        }

        return try rescan(scan, renamedFrom: renamedFrom, restored: unknown)
    }

    /// Checks again after a repair, keeping what the repair did visible in the file states.
    private func rescan(_ scan: Scan, renamedFrom: [Int: String], restored: [Int]) throws -> Scan {
        var result = try self.scan(parFile: scan.parFile)
        for index in result.files.indices where result.files[index].state == .ok {
            if restored.contains(index) {
                result.files[index].state = .repaired
            } else if let name = renamedFrom[index] {
                result.files[index].state = .okAfterRenaming(from: name)
            }
        }
        return result
    }

    /// Coefficient of each entry in a volume, by the entry's position in `entries`.
    /// A volume's own file list decides the ranks; entries are matched by size and MD5.
    private func coefficientRow(for volume: Volume, entries: [Par1Entry]) -> [UInt8] {
        var row = [UInt8](repeating: 0, count: entries.count)
        let protectedInVolume = volume.header.entries.filter(\.isProtected)
        for (offset, volumeEntry) in protectedInVolume.enumerated() {
            if let index = entries.firstIndex(where: { $0.size == volumeEntry.size && $0.md5 == volumeEntry.md5 }) {
                row[index] = GF256.coefficient(rank: offset + 1, volume: volume.number)
            }
        }
        return row
    }

    private static func addIfIndependent(_ row: [UInt8], to basis: inout [[UInt8]]) -> Bool {
        var row = row
        for vector in basis {
            guard let pivot = vector.firstIndex(where: { $0 != 0 }), row[pivot] != 0 else { continue }
            let factor = GF256.divide(row[pivot], vector[pivot])
            for i in row.indices {
                row[i] ^= GF256.multiply(vector[i], factor)
            }
        }
        guard row.contains(where: { $0 != 0 }) else { return false }
        // Keep the basis in a form where each vector's pivot is cleared from the others.
        let pivot = row.firstIndex(where: { $0 != 0 })!
        for b in basis.indices where basis[b][pivot] != 0 {
            let factor = GF256.divide(basis[b][pivot], row[pivot])
            for i in row.indices {
                basis[b][i] ^= GF256.multiply(row[i], factor)
            }
        }
        basis.append(row)
        return true
    }

    // MARK: - Create

    /// Writes `parFile` (volume 0) and `recoveryCount` recovery volumes for `sources`,
    /// which must be in the same folder as `parFile`.
    public func create(parFile: URL, sources: [URL], recoveryCount: Int) throws {
        // Ranks and volume numbers are GF(2^8) elements / exponents; beyond 255 they repeat.
        guard sources.count <= ParFormat.par1.maximumFileCount, recoveryCount <= 255 else { throw Par1Error.tooManyFiles }
        let totalBytes = max(1, sources.reduce(UInt64(0)) { $0 + (Self.fileSize($1) ?? 0) })
        var hashed: UInt64 = 0
        var entries: [Par1Entry] = []
        for source in sources {
            let digest = try FileDigest.md5s(of: source, isCanceled: { self.lock.withLock { self.canceled } }) { done in
                hashed += done
                self.progressHandler?("Hashing", Double(hashed) / Double(totalBytes))
            }
            entries.append(Par1Entry(name: source.lastPathComponent, size: digest.size, md5: digest.full, md5First16K: digest.first16K))
            log("Opening: \(source.lastPathComponent)")
        }

        try Par1Header.encode(volumeNumber: 0, entries: entries, dataSize: 0).write(to: parFile)
        try Par1Header.writeControlHash(to: parFile)
        log("Wrote \(parFile.lastPathComponent).")
        removeStrayVolumes(of: parFile, above: recoveryCount)
        guard recoveryCount > 0 else { return }

        let dataSize = entries.map(\.size).max() ?? 0
        let volumeURLs = (1...recoveryCount).map { Par1Header.volumeURL(for: parFile, number: $0) }
        for (number, url) in zip(1..., volumeURLs) {
            try Par1Header.encode(volumeNumber: number, entries: entries, dataSize: dataSize).write(to: url)
        }

        let inputs = zip(sources, entries).enumerated().map { rank, pair in
            (url: pair.0, offset: UInt64(0), length: pair.1.size,
             multipliers: (1...recoveryCount).map { GF256.coefficient(rank: rank + 1, volume: $0) })
        }
        try combine(inputs: inputs, outputs: volumeURLs, outputSizes: Array(repeating: dataSize, count: recoveryCount),
                    phase: "Creating", append: true)

        for url in volumeURLs {
            try Par1Header.writeControlHash(to: url)
            log("Wrote \(url.lastPathComponent).")
        }
    }

    /// Recovery volumes of an older, bigger set would be mistaken for this one's.
    private func removeStrayVolumes(of parFile: URL, above count: Int) {
        var number = count + 1
        while true {
            let url = Par1Header.volumeURL(for: parFile, number: number)
            guard Self.hasParMagic(url) else { return }
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            number += 1
        }
    }

    // MARK: - Streaming

    /// For every output m: output = Σ_inputs multiplier[m] · input, chunk by chunk.
    /// Inputs shorter than an output count as zero-padded.
    private func combine(
        inputs: [(url: URL, offset: UInt64, length: UInt64, multipliers: [UInt8])],
        outputs: [URL],
        outputSizes: [UInt64],
        phase: String,
        append: Bool = false
    ) throws {
        let total = outputSizes.max() ?? 0
        let chunk = outputs.count > 32 ? Self.chunkSize / 4 : Self.chunkSize

        let readers = try inputs.map { input -> FileHandle in
            let handle = try FileHandle(forReadingFrom: input.url)
            try handle.seek(toOffset: input.offset)
            return handle
        }
        defer { readers.forEach { try? $0.close() } }

        if !append {
            for url in outputs {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        let writers = try outputs.map { url -> FileHandle in
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        }
        defer { writers.forEach { try? $0.close() } }

        // Tables are built once per distinct (input, output) multiplier.
        let tables: [[[UInt8]?]] = inputs.map { input in
            input.multipliers.map { $0 > 1 ? GF256.multiplicationTable(for: $0) : nil }
        }

        var buffers = outputs.map { _ in [UInt8](repeating: 0, count: chunk) }
        var position: UInt64 = 0
        while position < total {
            try checkCanceled()
            let length = Int(min(UInt64(chunk), total - position))
            for o in buffers.indices {
                buffers[o].withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            }

            for (i, input) in inputs.enumerated() where position < input.length {
                let wanted = Int(min(UInt64(length), input.length - position))
                guard let data = try readers[i].read(upToCount: wanted), !data.isEmpty else { continue }
                data.withUnsafeBytes { source in
                    let bytes = source.bindMemory(to: UInt8.self)
                    for o in buffers.indices {
                        let multiplier = input.multipliers[o]
                        guard multiplier != 0 else { continue }
                        buffers[o].withUnsafeMutableBufferPointer { target in
                            if let table = tables[i][o] {
                                table.withUnsafeBufferPointer { lut in
                                    for b in 0..<bytes.count { target[b] ^= lut[Int(bytes[b])] }
                                }
                            } else {
                                for b in 0..<bytes.count { target[b] ^= bytes[b] }
                            }
                        }
                    }
                }
            }

            for (o, writer) in writers.enumerated() where position < outputSizes[o] {
                let count = Int(min(UInt64(length), outputSizes[o] - position))
                try writer.write(contentsOf: buffers[o].prefix(count))
            }
            position += UInt64(length)
            progressHandler?(phase, Double(position) / Double(max(1, total)))
        }
    }

    // MARK: - Files

    private func moveAside(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var aside = url.appendingPathExtension("bad")
        var counter = 2
        while FileManager.default.fileExists(atPath: aside.path) {
            aside = url.appendingPathExtension("bad\(counter)")
            counter += 1
        }
        try FileManager.default.moveItem(at: url, to: aside)
        log("Moved damaged \"\(url.lastPathComponent)\" to \"\(aside.lastPathComponent)\".")
    }

    static func regularFiles(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    static func fileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    static func hasParMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8)) == Par1Header.magic
    }
}

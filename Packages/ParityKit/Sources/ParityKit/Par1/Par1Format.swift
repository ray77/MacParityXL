import CryptoKit
import Foundation

/// One file listed in a PAR 1.0 set.
public struct Par1Entry: Equatable, Sendable {
    public var name: String
    public var size: UInt64
    public var md5: Data
    public var md5First16K: Data
    /// Bit 0 of the status field: the file contributes to the recovery volumes.
    public var isProtected: Bool

    public init(name: String, size: UInt64, md5: Data, md5First16K: Data, isProtected: Bool = true) {
        self.name = name
        self.size = size
        self.md5 = md5
        self.md5First16K = md5First16K
        self.isProtected = isProtected
    }
}

/// Header and file list of a `.par` / `.pNN` file (Parity Volume Set Specification 1.0).
///
/// All integers are little endian. Layout:
/// ```
/// 0x00  "PAR\0\0\0\0\0"            0x30  volume number (0 = .par)
/// 0x08  version 0x00010000         0x38  number of files
/// 0x0C  client id                  0x40  file list offset / 0x48 size
/// 0x10  control hash: MD5 of 0x20…EOF
/// 0x20  set hash: MD5 of the protected files' MD5s
///                                  0x50  data offset / 0x58 size
/// ```
/// File entry: size, status, file size (UInt64 each), MD5, MD5 of the first 16 KiB,
/// then the name in UTF-16LE without terminator.
public struct Par1Header: Equatable, Sendable {
    public var volumeNumber: Int
    public var setHash: Data
    public var entries: [Par1Entry]
    public var dataOffset: UInt64
    public var dataSize: UInt64

    static let magic = Data("PAR\0\0\0\0\0".utf8)
    static let fixedHeaderSize = 0x60
    static let entryFixedSize = 0x38
    static let version: UInt32 = 0x0001_0000
    /// Identifies MacParity as the creating client ("MP" 1.0).
    static let clientID: UInt32 = 0x4D50_0100

    public enum ReadError: Error, Equatable {
        case notAParFile
        case truncated
        case controlHashMismatch
    }

    /// Reads the header of a PAR1 file and, if `verifyControlHash`, checks the whole file.
    public static func read(from url: URL, verifyControlHash: Bool = true) throws -> Par1Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let fixed = try handle.read(upToCount: fixedHeaderSize), fixed.count == fixedHeaderSize else {
            throw ReadError.truncated
        }
        guard fixed.prefix(8) == magic else { throw ReadError.notAParFile }

        let storedControlHash = fixed[0x10..<0x20]
        let setHash = Data(fixed[0x20..<0x30])
        let volume = Int(fixed.uint64(at: 0x30))
        let fileCount = Int(fixed.uint64(at: 0x38))
        let listOffset = fixed.uint64(at: 0x40)
        let listSize = Int(fixed.uint64(at: 0x48))
        let dataOffset = fixed.uint64(at: 0x50)
        let dataSize = fixed.uint64(at: 0x58)

        try handle.seek(toOffset: listOffset)
        guard let list = try handle.read(upToCount: listSize), list.count == listSize else {
            throw ReadError.truncated
        }
        let entries = try parseEntries(list, expectedCount: fileCount)

        if verifyControlHash {
            try handle.seek(toOffset: 0x20)
            var md5 = Insecure.MD5()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                md5.update(data: chunk)
            }
            guard Data(md5.finalize()) == storedControlHash else { throw ReadError.controlHashMismatch }
        }

        return Par1Header(volumeNumber: volume, setHash: setHash, entries: entries, dataOffset: dataOffset, dataSize: dataSize)
    }

    private static func parseEntries(_ list: Data, expectedCount: Int) throws -> [Par1Entry] {
        var entries: [Par1Entry] = []
        var offset = list.startIndex
        while offset < list.endIndex {
            guard offset + entryFixedSize <= list.endIndex else { throw ReadError.truncated }
            let relative = offset - list.startIndex
            let entrySize = Int(list.uint64(at: relative))
            guard entrySize >= entryFixedSize, offset + entrySize <= list.endIndex else { throw ReadError.truncated }
            let status = list.uint64(at: relative + 0x08)
            let size = list.uint64(at: relative + 0x10)
            let md5 = Data(list[(offset + 0x18)..<(offset + 0x28)])
            let md5First16K = Data(list[(offset + 0x28)..<(offset + 0x38)])
            let nameBytes = list[(offset + entryFixedSize)..<(offset + entrySize)]
            let name = String(decoding: nameBytes.utf16LittleEndianUnits(), as: UTF16.self)
            entries.append(Par1Entry(name: name, size: size, md5: md5, md5First16K: md5First16K, isProtected: status & 1 != 0))
            offset += entrySize
        }
        guard entries.count == expectedCount else { throw ReadError.truncated }
        return entries
    }

    /// The set hash for a list of entries.
    static func setHash(for entries: [Par1Entry]) -> Data {
        var md5 = Insecure.MD5()
        for entry in entries where entry.isProtected {
            md5.update(data: entry.md5)
        }
        return Data(md5.finalize())
    }

    /// Serializes header and file list. The control hash is left zero; see `writeControlHash`.
    static func encode(volumeNumber: Int, entries: [Par1Entry], dataSize: UInt64) -> Data {
        var list = Data()
        for entry in entries {
            let name = entry.name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            list.appendUInt64(UInt64(entryFixedSize + name.count))
            list.appendUInt64(entry.isProtected ? 1 : 0)
            list.appendUInt64(entry.size)
            list.append(entry.md5)
            list.append(entry.md5First16K)
            list.append(contentsOf: name)
        }

        var header = Data()
        header.append(magic)
        header.appendUInt32(version)
        header.appendUInt32(clientID)
        header.append(Data(count: 16)) // control hash, filled in later
        header.append(setHash(for: entries))
        header.appendUInt64(UInt64(volumeNumber))
        header.appendUInt64(UInt64(entries.count))
        header.appendUInt64(UInt64(fixedHeaderSize))
        header.appendUInt64(UInt64(list.count))
        header.appendUInt64(UInt64(fixedHeaderSize + list.count))
        header.appendUInt64(dataSize)
        return header + list
    }

    /// Computes MD5 over 0x20…EOF and stores it at 0x10.
    static func writeControlHash(to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0x20)
        var md5 = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            md5.update(data: chunk)
        }
        try handle.seek(toOffset: 0x10)
        try handle.write(contentsOf: Data(md5.finalize()))
    }

    /// Name of recovery volume `number` for a `.par` file: `set.par` → `set.p01`, `set.p100`.
    public static func volumeURL(for parFile: URL, number: Int) -> URL {
        let base = parFile.deletingPathExtension()
        let digits = number < 100 ? String(format: "%02d", number) : String(number)
        return base.appendingPathExtension("p" + digits)
    }
}

/// MD5 of a whole file and of its first 16 KiB, as stored in PAR1 entries.
enum FileDigest {
    static func md5s(of url: URL, isCanceled: () -> Bool = { false }, progress: (UInt64) -> Void = { _ in }) throws -> (full: Data, first16K: Data, size: UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var full = Insecure.MD5()
        var first = Insecure.MD5()
        var size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if isCanceled() { throw CancellationError() }
            if size < 16384 {
                first.update(data: chunk.prefix(Int(16384 - size)))
            }
            full.update(data: chunk)
            size += UInt64(chunk.count)
            progress(UInt64(chunk.count))
        }
        return (Data(full.finalize()), Data(first.finalize()), size)
    }

    static func md5First16K(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return Data(Insecure.MD5.hash(data: try handle.read(upToCount: 16384) ?? Data()))
    }
}

extension Data {
    /// Little-endian UInt64 at `offset` bytes from the start of this data.
    func uint64(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return self[start..<(start + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    func utf16LittleEndianUnits() -> [UInt16] {
        stride(from: startIndex, to: endIndex - 1, by: 2).map { UInt16(self[$0]) | UInt16(self[$0 + 1]) << 8 }
    }

    mutating func appendUInt64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

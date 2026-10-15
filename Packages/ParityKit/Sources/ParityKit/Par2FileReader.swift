import Foundation

/// Reads the file list from a PAR2 file's FileDesc packets without running par2.
///
/// Packet layout (PAR 2.0 spec): 8-byte magic `PAR2\0PKT`, UInt64 length (whole packet),
/// 16-byte packet MD5, 16-byte recovery set ID, 16-byte type, then the body.
/// A FileDesc body is file ID (16), MD5 (16), MD5 of the first 16 KiB (16),
/// UInt64 length, then the NUL-padded file name.
public enum Par2FileReader {
    public struct FileDescription: Equatable, Sendable {
        public var name: String
        public var length: UInt64
    }

    public enum ReadError: Error {
        case noFileDescriptions
    }

    private static let magic = Data("PAR2\0PKT".utf8)
    private static let fileDescType = Data("PAR 2.0\0FileDesc".utf8)
    private static let headerSize = 64

    public static func fileDescriptions(in url: URL) throws -> [FileDescription] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let descriptions = fileDescriptions(in: data)
        guard !descriptions.isEmpty else { throw ReadError.noFileDescriptions }
        return descriptions
    }

    public static func fileDescriptions(in data: Data) -> [FileDescription] {
        var result: [String: FileDescription] = [:]
        var offset = data.startIndex

        while let range = data.range(of: magic, in: offset..<data.endIndex) {
            let start = range.lowerBound
            guard start + headerSize <= data.endIndex else { break }
            let length = Int(clamping: readUInt64(data, at: start + 8))
            guard length >= headerSize, length % 4 == 0, start + length <= data.endIndex else {
                offset = range.upperBound
                continue
            }
            let type = data[(start + 48)..<(start + 64)]
            // A FileDesc body needs at least its fixed 56 bytes.
            if type.elementsEqual(fileDescType), length >= headerSize + 56 {
                let body = start + headerSize
                let fileLength = readUInt64(data, at: body + 48)
                let nameBytes = data[(body + 56)..<(start + length)].prefix { $0 != 0 }
                let name = displayName(String(decoding: nameBytes, as: UTF8.self))
                result[name] = FileDescription(name: name, length: fileLength)
            }
            offset = start + length
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The name as par2cmdline uses it on disk: no leading slash, ".." components escaped,
    /// so a crafted set cannot point outside its folder.
    static func displayName(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0 == ".." ? "%2E%2E" : String($0) }
            .joined(separator: "/")
    }

    private static func readUInt64(_ data: Data, at index: Data.Index) -> UInt64 {
        data[index..<(index + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}

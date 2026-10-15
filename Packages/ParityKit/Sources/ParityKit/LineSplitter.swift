import Foundation

/// Splits a byte stream into lines. par2 redraws progress with `\r`, so both
/// `\r` and `\n` end a line.
public struct LineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            if !lineData.isEmpty {
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
        }
        return lines
    }

    /// Returns whatever is left once the stream has ended.
    public mutating func finish() -> [String] {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
    }
}

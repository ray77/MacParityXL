import Foundation

/// Something par2cmdline reported, decoded from one line of its output.
public enum Par2Event: Equatable, Sendable {
    case loading(parFile: String)
    case progress(phase: String, percent: Double)
    case statistics(Par2Statistics)
    case target(name: String, state: TargetFileState)
    /// An extra file whose contents belong to a target under another name.
    case renamedMatch(actual: String, target: String)
    case repairingStarted
    case outcome(ParRunOutcome)
    /// Any other line, kept for the raw output view.
    case other(String)
}

/// Turns par2cmdline-turbo output into events. Feed it complete lines.
///
/// The parser keeps running totals so `.statistics` events always carry everything
/// seen so far, which lets the UI just replace its copy.
public struct Par2OutputParser: Sendable {
    public private(set) var statistics = Par2Statistics()
    private var verifyingRepairedFiles = false

    public init() {}

    public mutating func parse(line rawLine: String) -> [Par2Event] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }

        if let name = quoted(line, after: "Loading \"") {
            return [.loading(parFile: name)]
        }
        if let (phase, percent) = progress(line) {
            return [.progress(phase: phase, percent: percent)]
        }
        if line.hasPrefix("Target: \"") {
            return targetEvents(line)
        }
        if line.hasPrefix("File: \""), let match = renamedMatch(line) {
            guard case let .renamedMatch(actual, target) = match else { return [match] }
            return [match, .target(name: target, state: .okAfterRenaming(from: actual))]
        }
        if let events = statisticsEvents(line) {
            return events
        }

        switch line {
        case "All files are correct, repair is not required.":
            return [.outcome(.allFilesCorrect)]
        case "Repair is possible.":
            return [.outcome(.repairPossible)]
        case "Repair is not possible.":
            return [.outcome(.repairNotPossible(neededBlocks: statistics.missingRecoveryBlocks))]
        case "Repair complete.":
            return [.outcome(.repaired)]
        case "Main packet not found.":
            return [.outcome(.invalidParFile)]
        case "Verifying repaired files:":
            verifyingRepairedFiles = true
            return [.other(line)]
        case "Computing Reed Solomon matrix.":
            return [.repairingStarted, .other(line)]
        case "Done":
            return [.outcome(.created)]
        default:
            return [.other(line)]
        }
    }

    // MARK: - Line kinds

    private func targetEvents(_ line: String) -> [Par2Event] {
        guard let name = quoted(line, after: "Target: \"") else { return [.other(line)] }
        let rest = line.components(separatedBy: "\" - ").dropFirst().joined(separator: "\" - ")

        if rest.hasPrefix("found") {
            return [.target(name: name, state: verifyingRepairedFiles ? .repaired : .ok)]
        }
        if rest.hasPrefix("missing") {
            return [.target(name: name, state: .missing)]
        }
        if rest.hasPrefix("damaged") {
            let numbers = integers(in: rest)
            let found = numbers.count >= 2 ? numbers[0] : 0
            let total = numbers.count >= 2 ? numbers[1] : 0
            return [.target(name: name, state: .damaged(foundBlocks: found, totalBlocks: total))]
        }
        return [.other(line)]
    }

    private func renamedMatch(_ line: String) -> Par2Event? {
        // File: "renamed.bin" - is a match for "file 3.bin".
        let parts = line.components(separatedBy: "\"")
        guard parts.count >= 4, line.contains("is a match for") else { return nil }
        return .renamedMatch(actual: parts[1], target: parts[3])
    }

    private mutating func statisticsEvents(_ line: String) -> [Par2Event]? {
        let numbers = integers(in: line)
        if line.hasPrefix("There are ") && line.contains("recoverable files"), numbers.count >= 2 {
            statistics.recoverableFileCount = numbers[0]
            statistics.otherFileCount = numbers[1]
        } else if line.hasPrefix("The block size used was"), let size = numbers.first {
            statistics.blockSize = size
        } else if line.hasPrefix("There are a total of") && line.hasSuffix("data blocks."), let total = numbers.first {
            statistics.totalDataBlocks = total
        } else if line.hasPrefix("The total size of the data files is"), let bytes = int64(in: line) {
            statistics.totalDataBytes = bytes
        } else if line.hasPrefix("You have ") && line.contains("data blocks available"), numbers.count >= 2 {
            statistics.availableDataBlocks = numbers[0]
        } else if line.hasPrefix("You have ") && line.contains("recovery blocks available"), let count = numbers.first {
            statistics.availableRecoveryBlocks = count
        } else if line.hasPrefix("You need ") && line.contains("more recovery blocks"), let count = numbers.first {
            // par2 prints the verdict before the shortfall, so repeat it with the number.
            statistics.missingRecoveryBlocks = count
            return [.statistics(statistics), .outcome(.repairNotPossible(neededBlocks: count)), .other(line)]
        } else {
            return nil
        }
        return [.statistics(statistics), .other(line)]
    }

    // MARK: - Helpers

    private func quoted(_ line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let end = rest.lastIndex(of: "\"") else { return nil }
        // Target lines continue after the closing quote; take the quote before " - ".
        if let separator = rest.range(of: "\" - ") {
            return String(rest[..<separator.lowerBound])
        }
        return String(rest[..<end])
    }

    private func progress(_ line: String) -> (String, Double)? {
        guard line.hasSuffix("%"), let colon = line.firstIndex(of: ":") else { return nil }
        let phase = String(line[..<colon])
        let value = line[line.index(after: colon)...].dropLast().trimmingCharacters(in: .whitespaces)
        guard let percent = Double(value) else { return nil }
        return (phase, percent)
    }

    private func integers(in text: some StringProtocol) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    private func int64(in text: String) -> Int64? {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }.first
    }
}

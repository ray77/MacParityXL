import Foundation

/// The par format a set uses.
public enum ParFormat: String, Codable, Sendable, CaseIterable {
    case par1
    case par2

    public var maximumFileCount: Int {
        switch self {
        case .par1: 255
        case .par2: 32768
        }
    }
}

/// State of one file protected by a par set, as shown in the document window.
public enum TargetFileState: Equatable, Sendable {
    /// Added to an untitled set, no parity data yet.
    case notInParSet
    case pending
    case checking
    case ok
    /// The data was found under a different name.
    case okAfterRenaming(from: String)
    case missing
    case damaged(foundBlocks: Int, totalBlocks: Int)
    case recoverable(wasMissing: Bool)
    case unrecoverable(wasMissing: Bool)
    case repaired

    public var isMissing: Bool {
        switch self {
        case .missing, .recoverable(wasMissing: true), .unrecoverable(wasMissing: true): true
        default: false
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .ok, .okAfterRenaming, .repaired, .notInParSet, .pending, .checking: false
        case .missing, .damaged, .recoverable, .unrecoverable: true
        }
    }
}

public struct TargetFile: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var state: TargetFileState
    /// False for PAR1 entries that are checked but not covered by the recovery volumes,
    /// so they can't be repaired (and aren't needed to repair others).
    public var contributesToParity: Bool

    public init(name: String, state: TargetFileState = .pending, contributesToParity: Bool = true) {
        self.name = name
        self.state = state
        self.contributesToParity = contributesToParity
    }
}

/// Totals reported by par2 after scanning.
public struct Par2Statistics: Equatable, Sendable {
    public var recoverableFileCount = 0
    public var otherFileCount = 0
    public var blockSize = 0
    public var totalDataBlocks = 0
    public var totalDataBytes: Int64 = 0
    public var availableDataBlocks: Int?
    public var availableRecoveryBlocks: Int?
    public var missingRecoveryBlocks: Int?

    public init() {}

    /// Bytes still missing for a repair, derived from the block shortfall.
    public var missingBytes: Int64? {
        missingRecoveryBlocks.map { Int64($0) * Int64(blockSize) }
    }
}

/// Final verdict of a verify or repair run.
public enum ParRunOutcome: Equatable, Sendable {
    case allFilesCorrect
    case repairPossible
    case repairNotPossible(neededBlocks: Int?)
    case repaired
    case created
    case invalidParFile
    case canceled
    case failed(message: String)
}

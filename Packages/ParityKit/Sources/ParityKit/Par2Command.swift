import Foundation

/// Arguments for one par2cmdline invocation.
public enum Par2Command: Sendable {
    /// `extraFiles` are scanned for misnamed or partial copies of the targets.
    case verify(parFile: URL, extraFiles: [URL])
    case repair(parFile: URL, extraFiles: [URL])
    case create(parFile: URL, sourceFiles: [URL], options: Par2CreateOptions)

    public var arguments: [String] {
        switch self {
        case let .verify(parFile, extraFiles):
            ["v", "-B\(parFile.deletingLastPathComponent().path)", "--", parFile.path] + extraFiles.map(\.path)
        case let .repair(parFile, extraFiles):
            ["r", "-B\(parFile.deletingLastPathComponent().path)", "--", parFile.path] + extraFiles.map(\.path)
        case let .create(parFile, sourceFiles, options):
            ["c", "-B\(parFile.deletingLastPathComponent().path)"] + options.arguments + ["--", parFile.path] + sourceFiles.map(\.path)
        }
    }

    public var workingDirectory: URL {
        switch self {
        case let .verify(parFile, _), let .repair(parFile, _), let .create(parFile, _, _):
            parFile.deletingLastPathComponent()
        }
    }
}

public struct Par2CreateOptions: Equatable, Codable, Sendable {
    public enum BlockSize: Equatable, Codable, Sendable {
        case automatic
        case kilobytes(Int)
    }

    /// Percentage of the set size to generate as recovery data (1–100).
    public var redundancyPercent: Int
    public var blockSize: BlockSize
    /// Keep the largest recovery file no bigger than the largest source file.
    public var limitRecoveryFileSize: Bool

    public init(redundancyPercent: Int = 10, blockSize: BlockSize = .automatic, limitRecoveryFileSize: Bool = false) {
        self.redundancyPercent = redundancyPercent
        self.blockSize = blockSize
        self.limitRecoveryFileSize = limitRecoveryFileSize
    }

    var arguments: [String] {
        var arguments = ["-r\(redundancyPercent)"]
        if case let .kilobytes(kb) = blockSize {
            // par2 requires the block size to be a multiple of 4.
            arguments.append("-s\(kb * 1024)")
        }
        if limitRecoveryFileSize {
            arguments.append("-l")
        }
        return arguments
    }
}

/// par2cmdline exit codes (see par2cmdline's `Result` enum).
public enum Par2ExitCode: Int32, Sendable {
    case success = 0
    case repairPossible = 1
    case repairNotPossible = 2
    case invalidCommandLineArguments = 3
    case insufficientCriticalData = 4
    case repairFailed = 5
    case fileIOError = 6
    case logicError = 7
    case memoryError = 8
}

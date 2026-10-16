import Foundation

/// Arguments for one par2cmdline invocation.
public enum Par2Command: Sendable {
    /// `extraFiles` are scanned for misnamed or partial copies of the targets.
    case verify(parFile: URL, extraFiles: [URL])
    case repair(parFile: URL, extraFiles: [URL])
    case create(parFile: URL, sourceFiles: [URL], options: Par2CreateOptions)

    public var arguments: [String] {
        arguments(fileList: nil)
    }

    /// The source or extra files. There can be thousands, more than fit on a command line.
    public var listedFiles: [URL] {
        switch self {
        case let .verify(_, files), let .repair(_, files), let .create(_, files, _): files
        }
    }

    /// Arguments with the listed files read from `fileList` (one path per line, par2's `@file`)
    /// instead of passed one by one. Files whose path contains a line break stay on the command line.
    public func arguments(fileList: URL?) -> [String] {
        let files: [String]
        if let fileList {
            files = ["@" + fileList.path] + listedFiles.map(\.path).filter(Self.needsCommandLine)
        } else {
            files = listedFiles.map(\.path)
        }
        switch self {
        case let .verify(parFile, _):
            return ["v", "-B\(parFile.deletingLastPathComponent().path)", "--", parFile.path] + files
        case let .repair(parFile, _):
            return ["r", "-B\(parFile.deletingLastPathComponent().path)", "--", parFile.path] + files
        case let .create(parFile, _, options):
            return ["c", "-B\(parFile.deletingLastPathComponent().path)"] + options.arguments + ["--", parFile.path] + files
        }
    }

    /// Contents for the `@file` list: every listed path that can go on its own line.
    public var fileListContents: String {
        listedFiles.map(\.path).filter { !Self.needsCommandLine($0) }.map { $0 + "\n" }.joined()
    }

    static func needsCommandLine(_ path: String) -> Bool {
        path.contains("\n") || path.contains("\r")
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

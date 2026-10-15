import Foundation

/// Runs the bundled par2 executable and streams decoded events.
public final class Par2Process: Sendable {
    public enum Update: Sendable {
        case event(Par2Event)
        case rawLine(String)
        case finished(exitCode: Int32, canceled: Bool)
    }

    private let executable: URL
    private let command: Par2Command
    private let process = Process()

    public init(executable: URL, command: Par2Command) {
        self.executable = executable
        self.command = command
    }

    /// Starts the process. The stream finishes after `.finished`.
    public func run() throws -> AsyncStream<Update> {
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.standardOutput = pipe
        process.standardError = pipe

        let (stream, continuation) = AsyncStream<Update>.makeStream()
        let reader = OutputReader()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for update in reader.consume(data) {
                continuation.yield(update)
            }
        }
        process.terminationHandler = { process in
            pipe.fileHandleForReading.readabilityHandler = nil
            let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
            for update in reader.consume(remaining) + reader.finish() {
                continuation.yield(update)
            }
            let canceled = process.terminationReason == .uncaughtSignal
            continuation.yield(.finished(exitCode: process.terminationStatus, canceled: canceled))
            continuation.finish()
        }

        try process.run()
        return stream
    }

    public func cancel() {
        if process.isRunning {
            process.terminate()
        }
    }
}

/// Serializes splitting and parsing across the pipe's background callbacks.
private final class OutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()
    private var parser = Par2OutputParser()

    func consume(_ data: Data) -> [Par2Process.Update] {
        lock.withLock { updates(for: splitter.append(data)) }
    }

    func finish() -> [Par2Process.Update] {
        lock.withLock { updates(for: splitter.finish()) }
    }

    private func updates(for lines: [String]) -> [Par2Process.Update] {
        lines.flatMap { line -> [Par2Process.Update] in
            let events = parser.parse(line: line)
            let isProgress = events.contains { if case .progress = $0 { true } else { false } }
            return (isProgress ? [] : [.rawLine(line)]) + events.map(Par2Process.Update.event)
        }
    }
}

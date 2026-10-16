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

    /// Starts the process. The stream delivers updates in batches, at most about ten a second:
    /// par2 prints a line per file, and handling each one separately keeps a UI busy redrawing
    /// long after par2 is done. The last batch ends with `.finished`.
    public func run(batchInterval: TimeInterval = 0.1) throws -> AsyncStream<[Update]> {
        // Process throws an Objective-C exception (not a Swift error) for a missing executable
        // or an oversized command line, so rule both out first.
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: executable.path])
        }
        let fileList = try writeFileList()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = command.arguments(fileList: fileList)
        process.currentDirectoryURL = command.workingDirectory
        process.standardOutput = pipe
        process.standardError = pipe

        let (stream, continuation) = AsyncStream<[Update]>.makeStream()
        let reader = OutputReader()
        let batcher = UpdateBatcher(continuation: continuation, interval: batchInterval)

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            batcher.add(reader.consume(data))
        }
        process.terminationHandler = { process in
            if let fileList { try? FileManager.default.removeItem(at: fileList) }
            pipe.fileHandleForReading.readabilityHandler = nil
            let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
            let canceled = process.terminationReason == .uncaughtSignal
            batcher.finish(with: reader.consume(remaining) + reader.finish()
                + [.finished(exitCode: process.terminationStatus, canceled: canceled)])
        }

        do {
            try process.run()
        } catch {
            if let fileList { try? FileManager.default.removeItem(at: fileList) }
            throw error
        }
        return stream
    }

    /// Writes the listed files to a temporary `@file`, or returns nil if there are none.
    private func writeFileList() throws -> URL? {
        let contents = command.fileListContents
        guard !contents.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "MacParityXL-files-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public func cancel() {
        if process.isRunning {
            process.terminate()
        }
    }
}

/// Collects updates and hands them on together after `interval`.
private final class UpdateBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<[Par2Process.Update]>.Continuation
    private let interval: TimeInterval
    private var pending: [Par2Process.Update] = []
    private var flushScheduled = false
    private var finished = false

    init(continuation: AsyncStream<[Par2Process.Update]>.Continuation, interval: TimeInterval) {
        self.continuation = continuation
        self.interval = interval
    }

    func add(_ updates: [Par2Process.Update]) {
        guard !updates.isEmpty else { return }
        lock.withLock {
            guard !finished else { return }
            pending += updates
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [self] in
                lock.withLock {
                    flushScheduled = false
                    flushLocked()
                }
            }
        }
    }

    func finish(with updates: [Par2Process.Update]) {
        lock.withLock {
            guard !finished else { return }
            pending += updates
            flushLocked()
            finished = true
            continuation.finish()
        }
    }

    /// Yields under the lock so batches keep their order; yielding never blocks.
    private func flushLocked() {
        guard !pending.isEmpty, !finished else { return }
        continuation.yield(pending)
        pending = []
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

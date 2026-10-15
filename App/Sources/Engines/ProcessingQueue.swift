import Foundation

/// Runs par checks and unrars one after another unless the user allows
/// simultaneous processing.
@MainActor
final class ProcessingQueue {
    static let shared = ProcessingQueue()

    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Waits for a turn, runs `job`, then lets the next waiter go.
    func run(_ job: () async -> Void) async {
        if AppSettings.shared.processSimultaneously {
            await job()
            return
        }
        if isBusy {
            await withCheckedContinuation { waiting.append($0) }
        }
        isBusy = true
        await job()
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

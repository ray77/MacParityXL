import AppKit
import SwiftUI

enum PasswordPrompt {
    /// Asks for the password of an encrypted archive. Nil if the user cancels.
    @MainActor
    static func ask(archiveName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Enter the password for “\(archiveName)”")
        alert.informativeText = String(localized: "The same password is used for the entire archive.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

@MainActor
@Observable
private final class UnrarProgress {
    var archiveName: String
    var currentFile = ""
    var done: Int64 = 0
    var total: Int64 = 0

    /// Nil until the library reports the archive's size.
    var percent: Double? {
        total > 0 ? min(100, Double(done) / Double(total) * 100) : nil
    }

    init(archiveName: String) {
        self.archiveName = archiveName
    }
}

private struct UnrarProgressView: View {
    let progress: UnrarProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extracting “\(progress.archiveName)”")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if progress.total > 0 {
                        Text("\(progress.done.formatted(.byteCount(style: .file))) of \(progress.total.formatted(.byteCount(style: .file)))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ParProgressBar(percent: progress.percent, phase: progress.currentFile)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Small floating window showing Unrar progress.
@MainActor
final class UnrarProgressWindowController: NSWindowController {
    private let progress: UnrarProgress

    init(archiveName: String, onCancel: @escaping () -> Void) {
        progress = UnrarProgress(archiveName: archiveName)
        let window = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Unrar")
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: UnrarProgressView(progress: progress, onCancel: onCancel))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(done: Int64, total: Int64, currentFile: String) {
        progress.done = done
        progress.total = total
        progress.currentFile = currentFile
    }
}

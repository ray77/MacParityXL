import AppKit
import ParityKit
import SwiftUI
import UniformTypeIdentifiers

/// A par set window. Opening an existing set starts verify and repair right away;
/// an untitled document collects files for a new set.
///
/// The document never writes itself: "Create PAR Set…" runs par2, which produces the files.
class ParSetDocument: NSDocument {
    nonisolated class var format: ParFormat { .par2 }

    private(set) lazy var model = ParSetModel(format: Self.format)
    private var didStart = false
    private let toolbar = ParSetToolbar()

    override class var autosavesInPlace: Bool { false }

    // Documents don't read concurrently, so AppKit calls this on the main thread.
    override func read(from url: URL, ofType typeName: String) throws {
        MainActor.assumeIsolated {
            model = ParSetModel(format: Self.format, parFile: url)
            model.loadFileList()
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    override func makeWindowControllers() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingController(rootView: rootView)
        // Only enforce the minimum; otherwise the window snaps to the view's ideal size.
        hosting.sizingOptions = [.minSize, .preferredContentSize]
        window.contentViewController = hosting
        window.toolbar = toolbar.makeToolbar()
        // Title on its own row, so the localized labels all fit without an overflow menu.
        window.toolbarStyle = .expanded
        // Assigning the content view controller resizes the window, so restore the size afterwards.
        window.setContentSize(NSSize(width: 760, height: 500))
        if !window.setFrameUsingName("ParSetWindow") {
            window.center()
        }
        window.setFrameAutosaveName("ParSetWindow")
        // Restoring a par window on launch would silently start another check.
        window.isRestorable = false
        let controller = NSWindowController(window: window)
        addWindowController(controller)
        model.onFinishedPostProcessing = { [weak self] in self?.close() }
        model.onParFileChanged = { [weak self] url in
            // A freshly created set becomes a regular document named after its par file.
            guard let self, fileURL == nil else { return }
            fileURL = url
            didStart = true
            windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        model.confirmManyUnrelatedFiles = { folderName, count in
            let alert = NSAlert()
            alert.messageText = String(localized: "The folder “\(folderName)” contains \(count) other files.")
            alert.informativeText = String(localized: "They probably don't belong to this PAR set. Scanning them for missing data can take a long time.")
            alert.addButton(withTitle: String(localized: "Proceed"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Don't ask again")
            let proceed = alert.runModal() == .alertFirstButtonReturn
            if proceed, alert.suppressionButton?.state == .on {
                AppSettings.shared.skipUnrelatedFilesWarning = true
            }
            return proceed
        }
    }

    override func showWindows() {
        super.showWindows()
        guard !didStart, fileURL != nil else { return }
        didStart = true
        Task { await model.verifyAndRepair() }
    }

    override var displayName: String! {
        get {
            guard fileURL != nil else { return "\(super.displayName ?? "") (\(Self.format.rawValue.uppercased()))" }
            // Keep the original name even after "Auto delete par files" moved the file to the Trash.
            return model.parFile?.lastPathComponent ?? super.displayName
        }
        set { super.displayName = newValue }
    }

    private var rootView: some View {
        ParSetView(model: model, onAddFiles: { [unowned self] in add($0) })
    }

    // MARK: - Closing

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        // A running par2 must be canceled first, like in the original.
        let canClose = !model.isRunning
        if let shouldCloseSelector, let object = delegate as? NSObject {
            typealias Callback = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
            let implementation = object.method(for: shouldCloseSelector)
            unsafeBitCast(implementation, to: Callback.self)(object, shouldCloseSelector, self, canClose, contextInfo)
        }
    }

    // MARK: - Actions

    @IBAction func cancelParOperation(_ sender: Any?) {
        model.cancel()
    }

    @IBAction func repairAgain(_ sender: Any?) {
        Task { await model.verifyAndRepair() }
    }

    @IBAction func applyRule(_ sender: Any?) {
        Task { await model.applyRule() }
    }

    @IBAction func toggleParOutput(_ sender: Any?) {
        model.showsOutput.toggle()
    }

    @IBAction func addFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard let window = windowControllers.first?.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls)
        }
    }

    @IBAction func removeFiles(_ sender: Any?) {
        model.removeFiles(named: model.selection)
    }

    @IBAction func selectAllNonOK(_ sender: Any?) {
        model.selection = Set(model.files.filter(\.state.needsAttention).map(\.id))
    }

    @IBAction func copy(_ sender: Any?) {
        let names = model.files.filter { model.selection.contains($0.id) }.map(\.name)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }

    @IBAction func createParSet(_ sender: Any?) {
        guard let window = windowControllers.first?.window else { return }
        CreateParSetPanel.run(for: model, in: window)
    }

    private func add(_ urls: [URL]) {
        guard let message = model.addFiles(urls), let window = windowControllers.first?.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let isUntitled = model.parFile == nil
        switch item.action {
        case #selector(cancelParOperation(_:)): return model.isRunning
        case #selector(repairAgain(_:)), #selector(applyRule(_:)): return !isUntitled && !model.isRunning
        case #selector(addFiles(_:)): return isUntitled && !model.isRunning
        case #selector(removeFiles(_:)): return isUntitled && !model.selection.isEmpty && !model.isRunning
        case #selector(createParSet(_:)): return isUntitled && !model.files.isEmpty && !model.isRunning
        case #selector(copy(_:)): return !model.selection.isEmpty
        case #selector(selectAllNonOK(_:)): return model.files.contains { $0.state.needsAttention }
        case #selector(toggleParOutput(_:)):
            (item as? NSMenuItem)?.title = model.showsOutput ? String(localized: "Hide par2 Output") : String(localized: "Show par2 Output")
            return true
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

final class Par2Document: ParSetDocument {
    nonisolated override class var format: ParFormat { .par2 }
}

final class Par1Document: ParSetDocument {
    nonisolated override class var format: ParFormat { .par1 }
}

/// Opening a RAR archive just runs Unrar; there is no window of its own.
final class UnrarDocument: NSDocument {
    override func read(from url: URL, ofType typeName: String) throws {}

    override func makeWindowControllers() {}

    override func showWindows() {
        guard let fileURL else { return }
        Task {
            await UnrarJob(archive: fileURL).run()
            close()
        }
    }
}

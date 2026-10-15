import AppKit
import ParityKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        // Must exist before anything touches NSDocumentController.shared.
        _ = ParDocumentController()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = MainMenu.make()
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.activate()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !NSDocumentController.shared.documents.contains { $0.fileURL != nil }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = NSDocumentController.shared.documents.contains { ($0 as? ParSetDocument)?.model.isRunning == true }
        return busy ? .terminateCancel : .terminateNow
    }

    // MARK: - Actions

    @IBAction func showAbout(_ sender: Any?) {
        if aboutWindow == nil {
            let hosting = NSHostingController(rootView: AboutView())
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.title = String(localized: "About \(ProcessInfo.processInfo.processName)")
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            aboutWindow = window
        }
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @IBAction func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @IBAction func newDefaultSet(_ sender: Any?) {
        (NSDocumentController.shared as? ParDocumentController)?.openUntitled(AppSettings.shared.defaultFormat)
    }

    @IBAction func newPar2Set(_ sender: Any?) {
        (NSDocumentController.shared as? ParDocumentController)?.openUntitled(.par2)
    }

    @IBAction func newPar1Set(_ sender: Any?) {
        (NSDocumentController.shared as? ParDocumentController)?.openUntitled(.par1)
    }

    @IBAction func unrarArchive(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the first file of the archive.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await UnrarJob(archive: url).run() }
    }

    @IBAction func closeAll(_ sender: Any?) {
        NSDocumentController.shared.closeAllDocuments(withDelegate: nil, didCloseAllSelector: nil, contextInfo: nil)
    }
}

/// Picks the document class for new windows and enables rar files in the Open panel.
final class ParDocumentController: NSDocumentController {
    static let par2Type = "org.parchive.par2"
    static let par1Type = "org.parchive.par"

    override var defaultType: String? {
        MainActor.assumeIsolated {
            AppSettings.shared.defaultFormat == .par1 ? Self.par1Type : Self.par2Type
        }
    }

    func openUntitled(_ format: ParFormat) {
        let type = format == .par1 ? Self.par1Type : Self.par2Type
        do {
            let document = try makeUntitledDocument(ofType: type)
            addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            presentError(error)
        }
    }

    override func typeForContents(of url: URL) throws -> String {
        // .p01, .p02 … belong to a PAR1 set; .r00 or .001 to a RAR archive.
        let ext = url.pathExtension.lowercased()
        if ext.count == 3, ext.first == "p", ext.dropFirst().allSatisfy(\.isNumber) {
            return Self.par1Type
        }
        if RarVolumes.isVolume(url.lastPathComponent) {
            return "com.rarlab.rar-archive"
        }
        return try super.typeForContents(of: url)
    }
}

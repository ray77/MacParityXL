import AppKit
import ParityKit
import UserNotifications

/// One Unrar operation: picks the destination, extracts with a progress window,
/// reports the result as a notification and cleans up the segments.
@MainActor
final class UnrarJob {
    let archive: URL
    private let settings = AppSettings.shared
    private var progressWindow: UnrarProgressWindowController?

    init(archive: URL) {
        self.archive = archive
    }

    func run() async {
        await ProcessingQueue.shared.run {
            await self.extract()
        }
    }

    private func extract() async {
        guard let destinationFolder = chooseDestinationFolder() else { return }
        let unrar = UnrarArchive(url: archive)
        unrar.keepBrokenFiles = settings.keepBrokenFiles
        let unattended = settings.runUnattended
        let archiveName = archive.lastPathComponent
        unrar.passwordProvider = {
            guard !unattended else { return nil }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { PasswordPrompt.ask(archiveName: archiveName) }
            }
        }

        let window = UnrarProgressWindowController(archiveName: archiveName) { unrar.cancel() }
        progressWindow = window
        window.showWindow(nil)
        unrar.progressHandler = { done, total, file in
            Task { @MainActor in window.update(done: done, total: total, currentFile: file) }
        }
        defer { window.close() }

        do {
            let items = try await Task.detached { try unrar.topLevelItems() }.value
            // Several top-level items go into a folder named after the archive.
            let output: URL
            if items.count > 1 {
                guard let folder = resolveExisting(destinationFolder.appending(path: Self.archiveBaseName(archive))) else { return }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                output = folder
            } else {
                if let item = items.first, resolveExisting(destinationFolder.appending(path: item)) == nil { return }
                output = destinationFolder
            }

            try await Task.detached { try unrar.extract(to: output) }.value
            cleanUpSegments()
            Notifier.post(title: String(localized: "Unrar successful"), subtitle: archiveName, revealing: output)
        } catch UnrarArchive.UnrarError.canceled {
            return
        } catch {
            Notifier.post(title: String(localized: "Unrar failed"), subtitle: archiveName, body: error.localizedDescription)
        }
    }

    private func chooseDestinationFolder() -> URL? {
        switch settings.unrarDestination {
        case .besideArchive:
            return archive.deletingLastPathComponent()
        case .fixedFolder:
            return settings.unrarFixedFolder ?? archive.deletingLastPathComponent()
        case .askEveryTime:
            guard !settings.runUnattended else { return archive.deletingLastPathComponent() }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Unrar to This Folder")
            panel.directoryURL = archive.deletingLastPathComponent()
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    /// Applies the "destination already exists" preference. Returns nil to cancel.
    private func resolveExisting(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        var action = settings.existingDestinationAction
        if settings.runUnattended && action == .ask {
            action = .keepBoth
        }
        if action == .ask {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(url.lastPathComponent)” already exists.")
            alert.addButton(withTitle: String(localized: "Keep Both"))
            alert.addButton(withTitle: String(localized: "Overwrite"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: action = .keepBoth
            case .alertSecondButtonReturn: action = .overwrite
            default: action = .cancel
            }
        }
        switch action {
        case .overwrite:
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return url
        case .keepBoth:
            // Like the original: rename the existing item out of the way.
            let renamed = Self.uniqueURL(for: url)
            try? FileManager.default.moveItem(at: url, to: renamed)
            return url
        case .cancel, .ask:
            return nil
        }
    }

    private func cleanUpSegments() {
        let folder = archive.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let segments = RarVolumes.segments(of: archive.lastPathComponent, in: names).map { folder.appending(path: $0) }
        for segment in segments {
            switch settings.segmentsAfterUnrar {
            case .leave: break
            case .moveToTrash: try? FileManager.default.trashItem(at: segment, resultingItemURL: nil)
            case .delete: try? FileManager.default.removeItem(at: segment)
            }
        }
    }

    static func archiveBaseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        if let range = name.range(of: #"\.part[0-9]+\.(rar|exe)$"#, options: [.regularExpression, .caseInsensitive]) {
            return String(name[..<range.lowerBound])
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func uniqueURL(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for counter in 2... {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = folder.appending(path: name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

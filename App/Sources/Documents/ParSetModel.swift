import AppKit
import Observation
import ParityKit

/// What the status line at the bottom of a par window says.
enum ParSetStatus: Equatable {
    case idle
    case waiting
    case verifying
    case repairing
    case creating
    case allCorrect(renamed: Bool)
    case repaired(renamed: Bool)
    case needMoreBlocks(Int?)
    /// PAR1: this many more recovery volumes (.pNN) are needed.
    case needMoreVolumes(Int)
    /// PAR1: only files that don't contribute to the parity data are missing or damaged.
    case onlyUnprotectedProblems
    case created
    case invalidParFile
    case canceled
    case failed(String)
    case engineUnavailable(String)

    var text: String {
        switch self {
        case .idle: ""
        case .waiting: String(localized: "Waiting to start PAR check…")
        case .verifying: String(localized: "Verifying files. Press ⌘. to cancel.")
        case .repairing: String(localized: "Repairing files. Press ⌘. to cancel.")
        case .creating: String(localized: "Creating PAR files. Press ⌘. to cancel.")
        case .allCorrect(false): String(localized: "All files are correct.")
        case .allCorrect(true): String(localized: "All files are correct; one or more files were renamed.")
        case .repaired(false): String(localized: "Files repaired successfully.")
        case .repaired(true): String(localized: "Files repaired successfully; one or more files were renamed.")
        case .needMoreBlocks(let count?): String(localized: "Cannot repair; \(count) more recovery blocks needed.")
        case .needMoreBlocks(nil): String(localized: "Cannot repair.")
        case .needMoreVolumes(1): String(localized: "Cannot repair; need one more recovery file.")
        case .needMoreVolumes(let count): String(localized: "Cannot repair; need \(count) more recovery files.")
        case .onlyUnprotectedProblems: String(localized: "Only files without recovery data are missing or damaged.")
        case .created: String(localized: "PAR files created successfully.")
        case .invalidParFile: String(localized: "The PAR file is not valid.")
        case .canceled: String(localized: "Canceled.")
        case .failed(let message): message
        case .engineUnavailable(let message): message
        }
    }

    var isSuccess: Bool {
        switch self {
        case .allCorrect, .repaired, .created, .onlyUnprotectedProblems: true
        default: false
        }
    }

    var isFailure: Bool {
        switch self {
        case .needMoreBlocks, .needMoreVolumes, .invalidParFile, .failed, .engineUnavailable: true
        default: false
        }
    }
}

/// State and processing for one par set window.
@MainActor
@Observable
final class ParSetModel {
    let format: ParFormat
    private(set) var parFile: URL?
    private(set) var files: [TargetFile] = []
    private(set) var statistics = Par2Statistics()
    private(set) var status: ParSetStatus = .idle {
        // A new phase starts from zero; otherwise the bar shows the previous phase until the engine reports.
        didSet { if status != oldValue { progress = nil } }
    }
    private(set) var progress: (phase: String, percent: Double)?
    private(set) var rawOutput = ""
    private(set) var isRunning = false {
        // Toolbar items only revalidate on events; make Cancel/Repair Again follow the run state.
        didSet { NSApp.windows.forEach { $0.toolbar?.validateVisibleItems() } }
    }
    var selection = Set<TargetFile.ID>()
    var showsOutput = false

    /// Called after a successful run so the document can close itself if configured.
    var onFinishedPostProcessing: (() -> Void)?
    /// Asked before scanning a folder full of unrelated files; return false to cancel.
    var confirmManyUnrelatedFiles: ((_ folderName: String, _ count: Int) -> Bool)?

    /// Above this many extra files a scan is probably slow and pointless.
    static let unrelatedFileWarningThreshold = 25

    private var process: Par2Process?
    private var par1Engine: Par1Engine?
    /// PAR1: usable recovery volumes found by the last check.
    private(set) var par1VolumeCount = 0
    /// Copies of damaged files that par2 kept ("name.1") during the last repair.
    private var backupFiles: [URL] = []
    private var sawRename = false

    init(format: ParFormat, parFile: URL? = nil) {
        self.format = format
        self.parFile = parFile
    }

    /// Folder of the files in an untitled set.
    private(set) var sourceFolder: URL?

    var goodFileCount: Int { files.filter { !$0.state.needsAttention && $0.state != .notInParSet }.count }
    var problemFileCount: Int { files.filter(\.state.needsAttention).count }
    var missingFileCount: Int { files.filter { $0.state.isMissing }.count }
    var damagedFileCount: Int { problemFileCount - missingFileCount }

    // MARK: - Opening an existing set

    func loadFileList() {
        guard let parFile else { return }
        do {
            switch format {
            case .par2:
                files = try Par2FileReader.fileDescriptions(in: parFile).map { TargetFile(name: $0.name) }
            case .par1:
                files = try Par1Header.read(from: parFile, verifyControlHash: false).entries
                    .map { TargetFile(name: $0.name, contributesToParity: $0.isProtected) }
            }
        } catch {
            status = .invalidParFile
        }
    }

    /// Verifies the set and repairs it if possible, then runs post-processing.
    func verifyAndRepair() async {
        guard let parFile, !isRunning else { return }
        guard FileManager.default.isWritableFile(atPath: parFile.deletingLastPathComponent().path) else {
            status = .failed(String(localized: "No write access to folder “\(parFile.deletingLastPathComponent().lastPathComponent)”."))
            return
        }

        // Only par2 scans every extra file's contents; PAR1 just compares sizes first.
        let extras = format == .par2 ? extraFiles(besides: parFile) : []
        if extras.count > Self.unrelatedFileWarningThreshold,
           !AppSettings.shared.runUnattended,
           !AppSettings.shared.skipUnrelatedFilesWarning,
           confirmManyUnrelatedFiles?(parFile.deletingLastPathComponent().lastPathComponent, extras.count) == false {
            status = .canceled
            return
        }

        status = .waiting
        let folder = parFile.deletingLastPathComponent()
        let namesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        await ProcessingQueue.shared.run {
            switch self.format {
            case .par2: await self.runRepair(parFile: parFile)
            case .par1: await self.runPar1Repair(parFile: parFile)
            }
        }
        backupFiles = repairBackups(in: folder, excluding: namesBefore)
        if status.isSuccess {
            await postProcess()
        }
    }

    private func runRepair(parFile: URL) async {
        isRunning = true
        sawRename = false
        status = .verifying
        rawOutput = ""
        defer {
            isRunning = false
            progress = nil
            process = nil
        }

        let command = Par2Command.repair(parFile: parFile, extraFiles: extraFiles(besides: parFile))
        let process = Par2Process(executable: BundledTools.par2, command: command)
        self.process = process

        let updates: AsyncStream<Par2Process.Update>
        do {
            updates = try process.run()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        var outcome: ParRunOutcome?
        for await update in updates {
            switch update {
            case .rawLine(let line):
                rawOutput += line + "\n"
            case .event(let event):
                if let newOutcome = apply(event) {
                    outcome = newOutcome
                }
            case let .finished(exitCode, canceled):
                status = finalStatus(outcome: outcome, exitCode: exitCode, canceled: canceled)
            }
        }
    }

    /// Updates file rows and statistics; returns a verdict if the event carries one.
    private func apply(_ event: Par2Event) -> ParRunOutcome? {
        switch event {
        case let .progress(phase, percent):
            progress = (phase, percent)
        case let .statistics(statistics):
            self.statistics = statistics
        case let .target(name, state):
            if case .okAfterRenaming = state { sawRename = true }
            setState(state, for: name)
        case .repairingStarted:
            status = .repairing
            for index in files.indices {
                switch files[index].state {
                case .missing: files[index].state = .recoverable(wasMissing: true)
                case .damaged: files[index].state = .recoverable(wasMissing: false)
                default: break
                }
            }
        case .outcome(let outcome):
            if case .repairNotPossible = outcome {
                markRemainingProblems(recoverable: false)
            }
            return outcome
        case .loading, .renamedMatch, .other:
            break
        }
        return nil
    }

    private func finalStatus(outcome: ParRunOutcome?, exitCode: Int32, canceled: Bool) -> ParSetStatus {
        if canceled { return .canceled }
        switch outcome {
        case .allFilesCorrect: return .allCorrect(renamed: sawRename)
        case .repaired: return .repaired(renamed: sawRename)
        case .repairNotPossible(let needed): return .needMoreBlocks(needed)
        case .invalidParFile: return .invalidParFile
        default:
            let code = Par2ExitCode(rawValue: exitCode).map { "\($0)" } ?? "\(exitCode)"
            return .failed(String(localized: "par2 failed (\(code))."))
        }
    }

    private func setState(_ state: TargetFileState, for name: String) {
        if let index = files.firstIndex(where: { $0.name == name }) {
            files[index].state = state
        } else {
            files.append(TargetFile(name: name, state: state))
        }
    }

    private func markRemainingProblems(recoverable: Bool) {
        for index in files.indices {
            switch files[index].state {
            case .missing:
                files[index].state = recoverable ? .recoverable(wasMissing: true) : .unrecoverable(wasMissing: true)
            case .damaged:
                files[index].state = recoverable ? .recoverable(wasMissing: false) : .unrecoverable(wasMissing: false)
            default:
                break
            }
        }
    }

    /// Every other file in the folder, so par2 can find renamed or partial copies.
    private func extraFiles(besides parFile: URL) -> [URL] {
        let folder = parFile.deletingLastPathComponent()
        let targetNames = Set(files.map(\.name))
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { url in
            let name = url.lastPathComponent
            return !targetNames.contains(name)
                && url.pathExtension.lowercased() != "par2"
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func cancel() {
        process?.cancel()
        par1Engine?.cancel()
    }

    // MARK: - PAR1

    private func makePar1Engine() -> Par1Engine {
        let engine = Par1Engine()
        engine.progressHandler = { [weak self] phase, fraction in
            Task { @MainActor in self?.progress = (phase, fraction * 100) }
        }
        engine.logHandler = { [weak self] line in
            Task { @MainActor in self?.rawOutput += line + "\n" }
        }
        par1Engine = engine
        return engine
    }

    private func runPar1Repair(parFile: URL) async {
        isRunning = true
        status = .verifying
        rawOutput = ""
        defer {
            isRunning = false
            progress = nil
            par1Engine = nil
        }

        let engine = makePar1Engine()
        do {
            var scan = try await Task.detached { try engine.scan(parFile: parFile) }.value
            apply(scan)
            let renamed = scan.needsRenaming

            if !scan.filesToRestore.isEmpty && scan.missingVolumeCount > 0 {
                status = .needMoreVolumes(scan.missingVolumeCount)
                return
            }
            if !scan.filesToRestore.isEmpty || renamed {
                status = .repairing
                let toRepair = scan
                scan = try await Task.detached { try engine.repair(toRepair) }.value
                apply(scan)
            }

            if scan.unprotectedProblems > 0 {
                status = .onlyUnprotectedProblems
            } else if files.contains(where: { $0.state == .repaired }) {
                status = .repaired(renamed: renamed)
            } else {
                status = .allCorrect(renamed: renamed)
            }
        } catch Par1Engine.Par1Error.canceled {
            status = .canceled
        } catch Par1Engine.Par1Error.notEnoughVolumes(let needed) {
            status = .needMoreVolumes(needed)
        } catch Par1Header.ReadError.notAParFile, Par1Header.ReadError.truncated, Par1Header.ReadError.controlHashMismatch {
            status = .invalidParFile
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func apply(_ scan: Par1Engine.Scan) {
        files = scan.files
        par1VolumeCount = scan.volumes.count
    }

    /// Number of .pNN files to create by default, from the settings.
    var defaultPar1RecoveryCount: Int {
        switch AppSettings.shared.par1RecoveryCount {
        case .fixed(let count): return count
        case .onePer(let perVolume): return files.isEmpty ? 0 : (files.count - 1) / max(1, perVolume) + 1
        }
    }

    func createPar1(parFile: URL, recoveryCount: Int) async {
        guard let folder = sourceFolder, !isRunning else { return }
        isRunning = true
        status = .creating
        rawOutput = ""
        defer {
            isRunning = false
            progress = nil
            par1Engine = nil
        }

        let engine = makePar1Engine()
        let sources = files.map { folder.appending(path: $0.name) }
        do {
            try await Task.detached { try engine.create(parFile: parFile, sources: sources, recoveryCount: recoveryCount) }.value
            status = .created
            self.parFile = parFile
            par1VolumeCount = recoveryCount
            for index in files.indices { files[index].state = .ok }
        } catch Par1Engine.Par1Error.canceled {
            status = .canceled
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Post-processing

    private func postProcess() async {
        guard let parFile else { return }
        let settings = AppSettings.shared

        if settings.autoDeleteParFiles {
            trashParFiles(of: parFile)
        }
        guard settings.autoPostProcess else { return }
        await applyRule()
        if settings.closeWindowAfterPostProcessing {
            onFinishedPostProcessing?()
        }
    }

    /// Runs the first matching post-processing rule (also the Process ▸ Apply Rule command).
    func applyRule() async {
        guard let folder = parFile?.deletingLastPathComponent() else { return }
        let names = files.map(\.name).finderSorted()
        guard let (rule, fileName) = PostProcessRule.firstMatch(in: AppSettings.shared.postProcessRules, fileNames: names) else { return }
        let file = folder.appending(path: fileName)

        switch rule.action {
        case .builtInUnrar:
            let first = names.first(where: RarVolumes.isFirstVolume).map { folder.appending(path: $0) } ?? file
            await UnrarJob(archive: first).run()
        case .openInFinder:
            NSWorkspace.shared.open(file)
        case .openWithApplication(let bundleURL):
            _ = try? await NSWorkspace.shared.open([file], withApplicationAt: bundleURL, configuration: .init())
        case .commandLine(let template):
            TerminalLauncher.run(Macro.expand(template, file: file, rule: rule))
        }
    }

    /// Before writing a repaired file, par2 renames the damaged one to "name.N" and the
    /// PAR1 engine to "name.bad" / "name.badN".
    private func repairBackups(in folder: URL, excluding existing: Set<String>) -> [URL] {
        let targetNames = Set(files.map(\.name))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { name in
            guard !existing.contains(name), let dot = name.lastIndex(of: ".") else { return false }
            var suffix = name[name.index(after: dot)...]
            if suffix.hasPrefix("bad") {
                suffix = suffix.dropFirst(3)
            } else if suffix.isEmpty {
                return false
            }
            return suffix.allSatisfy(\.isNumber) && targetNames.contains(String(name[..<dot]))
        }
        .map { folder.appending(path: $0) }
    }

    private func trashParFiles(of parFile: URL) {
        for backup in backupFiles {
            try? FileManager.default.trashItem(at: backup, resultingItemURL: nil)
        }
        backupFiles = []
        let folder = parFile.deletingLastPathComponent()
        let base = parFile.deletingPathExtension().lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in contents where Self.isParFile(url, format: format) && url.deletingPathExtension().lastPathComponent.hasPrefix(base) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// `.par2` for PAR2 sets; `.par` and `.p01`, `.p02`, … for PAR1 sets.
    private static func isParFile(_ url: URL, format: ParFormat) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch format {
        case .par2:
            return ext == "par2"
        case .par1:
            return ext == "par" || (ext.count >= 3 && ext.first == "p" && ext.dropFirst().allSatisfy(\.isNumber))
        }
    }

    // MARK: - Creating a new set

    func addFiles(_ urls: [URL]) -> String? {
        let regular = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        guard let firstFolder = regular.first?.deletingLastPathComponent() else { return nil }
        let folder = sourceFolder ?? firstFolder
        guard regular.allSatisfy({ $0.deletingLastPathComponent() == folder }) else {
            return String(localized: "All files of a PAR set must be in the same folder.")
        }
        let newNames = regular.map(\.lastPathComponent).filter { name in !files.contains { $0.name == name } }
        guard files.count + newNames.count <= format.maximumFileCount else {
            let room = format.maximumFileCount - files.count
            return String(localized: "Too many files; the set has room for \(room) more.")
        }
        sourceFolder = folder
        files += newNames.map { TargetFile(name: $0, state: .notInParSet) }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return nil
    }

    func removeFiles(named names: Set<String>) {
        files.removeAll { names.contains($0.name) }
        selection.subtract(names)
        if files.isEmpty { sourceFolder = nil }
    }

    /// File name suggestion: the common base name of all files, if they share one.
    var suggestedParFileName: String {
        let bases = Set(files.map { ($0.name as NSString).deletingPathExtension })
        return (bases.count == 1 ? bases.first! : String(localized: "Untitled")) + (format == .par1 ? ".par" : ".par2")
    }

    func create(parFile: URL, options: Par2CreateOptions) async {
        guard format == .par2 else { return }
        guard let folder = sourceFolder, !isRunning else { return }
        isRunning = true
        status = .creating
        rawOutput = ""
        defer {
            isRunning = false
            progress = nil
            process = nil
        }

        let sources = files.map { folder.appending(path: $0.name) }
        let process = Par2Process(executable: BundledTools.par2, command: .create(parFile: parFile, sourceFiles: sources, options: options))
        self.process = process
        guard let updates = try? process.run() else {
            status = .failed(String(localized: "Could not start par2."))
            return
        }
        var created = false
        for await update in updates {
            switch update {
            case .rawLine(let line):
                rawOutput += line + "\n"
            case .event(.progress(let phase, let percent)):
                progress = (phase, percent)
            case .event(.outcome(.created)):
                created = true
            case .event:
                break
            case let .finished(exitCode, canceled):
                if canceled {
                    status = .canceled
                } else if created && exitCode == 0 {
                    status = .created
                    self.parFile = parFile
                    for index in files.indices { files[index].state = .ok }
                } else {
                    status = .failed(String(localized: "par2 failed (\(exitCode))."))
                }
            }
        }
    }
}

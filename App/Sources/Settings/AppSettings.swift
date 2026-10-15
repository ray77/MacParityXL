import Foundation
import Observation
import ParityKit

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum UnrarDestination: String, Codable, CaseIterable {
        case besideArchive
        case askEveryTime
        case fixedFolder
    }

    enum ExistingDestinationAction: String, Codable, CaseIterable {
        case ask
        case overwrite
        case keepBoth
        case cancel
    }

    enum SegmentsAfterUnrar: String, Codable, CaseIterable {
        case leave
        case moveToTrash
        case delete
    }

    enum Par1RecoveryCount: Codable, Equatable {
        /// One recovery file for every N source files.
        case onePer(files: Int)
        case fixed(Int)
    }

    // Basic
    var autoDeleteParFiles = false { didSet { save() } }
    var closeWindowAfterPostProcessing = false { didSet { save() } }
    var defaultFormat: ParFormat = .par2 { didSet { save() } }
    var runUnattended = false { didSet { save() } }
    var processSimultaneously = false { didSet { save() } }
    var skipUnrelatedFilesWarning = false { didSet { save() } }

    // Creation
    var par1RecoveryCount: Par1RecoveryCount = .onePer(files: 5) { didSet { save() } }
    var par2Options = Par2CreateOptions() { didSet { save() } }

    // Unrar
    var keepBrokenFiles = false { didSet { save() } }
    var unrarDestination: UnrarDestination = .besideArchive { didSet { save() } }
    var unrarFixedFolder: URL? { didSet { save() } }
    var existingDestinationAction: ExistingDestinationAction = .ask { didSet { save() } }
    var segmentsAfterUnrar: SegmentsAfterUnrar = .moveToTrash { didSet { save() } }

    // Post-processing
    var autoPostProcess = true { didSet { save() } }
    var postProcessRules: [PostProcessRule] = PostProcessRule.standardRules { didSet { save() } }

    private let defaults: UserDefaults
    private var isLoading = false
    private static let key = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private struct Stored: Codable {
        var autoDeleteParFiles: Bool
        var closeWindowAfterPostProcessing: Bool
        var defaultFormat: ParFormat
        var runUnattended: Bool
        var processSimultaneously: Bool
        var skipUnrelatedFilesWarning: Bool?
        var par1RecoveryCount: Par1RecoveryCount
        var par2Options: Par2CreateOptions
        var keepBrokenFiles: Bool
        var unrarDestination: UnrarDestination
        var unrarFixedFolder: URL?
        var existingDestinationAction: ExistingDestinationAction
        var segmentsAfterUnrar: SegmentsAfterUnrar
        var autoPostProcess: Bool
        var postProcessRules: [PostProcessRule]
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        isLoading = true
        defer { isLoading = false }
        autoDeleteParFiles = stored.autoDeleteParFiles
        closeWindowAfterPostProcessing = stored.closeWindowAfterPostProcessing
        defaultFormat = stored.defaultFormat
        runUnattended = stored.runUnattended
        processSimultaneously = stored.processSimultaneously
        skipUnrelatedFilesWarning = stored.skipUnrelatedFilesWarning ?? false
        par1RecoveryCount = stored.par1RecoveryCount
        par2Options = stored.par2Options
        keepBrokenFiles = stored.keepBrokenFiles
        unrarDestination = stored.unrarDestination
        unrarFixedFolder = stored.unrarFixedFolder
        existingDestinationAction = stored.existingDestinationAction
        segmentsAfterUnrar = stored.segmentsAfterUnrar
        autoPostProcess = stored.autoPostProcess
        postProcessRules = Self.withBuiltInRule(stored.postProcessRules)
    }

    /// The built-in Unrar rule can't be deleted and always comes last.
    private static func withBuiltInRule(_ rules: [PostProcessRule]) -> [PostProcessRule] {
        guard !rules.contains(where: \.isBuiltIn),
              let builtIn = PostProcessRule.standardRules.first(where: \.isBuiltIn) else { return rules }
        return rules + [builtIn]
    }

    private func save() {
        guard !isLoading else { return }
        let stored = Stored(
            autoDeleteParFiles: autoDeleteParFiles,
            closeWindowAfterPostProcessing: closeWindowAfterPostProcessing,
            defaultFormat: defaultFormat,
            runUnattended: runUnattended,
            processSimultaneously: processSimultaneously,
            skipUnrelatedFilesWarning: skipUnrelatedFilesWarning,
            par1RecoveryCount: par1RecoveryCount,
            par2Options: par2Options,
            keepBrokenFiles: keepBrokenFiles,
            unrarDestination: unrarDestination,
            unrarFixedFolder: unrarFixedFolder,
            existingDestinationAction: existingDestinationAction,
            segmentsAfterUnrar: segmentsAfterUnrar,
            autoPostProcess: autoPostProcess,
            postProcessRules: postProcessRules
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func restoreStandardRules() {
        postProcessRules = PostProcessRule.standardRules
    }
}

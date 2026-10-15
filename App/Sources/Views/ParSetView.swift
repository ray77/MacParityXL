import AppKit
import ParityKit
import SwiftUI
import UniformTypeIdentifiers

/// Content of a par set window: file table, status bar with progress and statistics,
/// and the raw par2 output.
struct ParSetView: View {
    @Bindable var model: ParSetModel
    var onAddFiles: ([URL]) -> Void

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                fileTable
                    .overlay {
                        if model.files.isEmpty && model.parFile == nil {
                            EmptySetPlaceholder()
                        }
                    }
                Divider()
                StatusBar(model: model)
            }
            .frame(minHeight: 300)

            if model.showsOutput {
                ScrollView {
                    Text(model.rawOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .defaultScrollAnchor(.bottom)
                .background(Color(nsColor: .textBackgroundColor))
                .frame(minHeight: 80, idealHeight: 150)
            }
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 422, idealHeight: 500)
    }

    private var fileTable: some View {
        Table(rows, selection: $model.selection) {
            TableColumn("File") { row in
                switch row {
                case .data(let file):
                    FileNameCell(name: file.name, dimmed: false)
                case .recovery(let file):
                    FileNameCell(name: file.name, dimmed: true)
                }
            }
            .width(min: 160, ideal: 250)

            TableColumn("Size") { row in
                Group {
                    switch row {
                    case .data(let file):
                        Text(model.fileSizes[file.name].map { $0.formatted(.byteCount(style: .file)) } ?? "–")
                    case .recovery(let file):
                        Text(file.size.formatted(.byteCount(style: .file)))
                    }
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 76, max: 110)

            TableColumn("Status") { row in
                switch row {
                case .data(let file):
                    HStack(spacing: 6) {
                        StatusBadge(state: file.state)
                        if !file.contributesToParity {
                            Badge(text: String(localized: "No recovery data"), symbol: "minus.circle", tint: .secondary)
                                .help("This file is checked, but it did not contribute to the recovery files, so it can't be restored.")
                        }
                    }
                case .recovery(let file):
                    Badge(text: file.kind.description, symbol: "lifepreserver", tint: .secondary)
                }
            }
            .width(min: 180, ideal: 340)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.parFile == nil else { return false }
            onAddFiles(urls)
            return true
        }
    }

    /// Data files first, then the set's own par files.
    private var rows: [ParSetRow] {
        model.files.map(ParSetRow.data) + model.recoveryFiles.map(ParSetRow.recovery)
    }
}

// MARK: - Status bar

/// Bottom bar: status icon and message, key figures, and the progress bar while running.
private struct StatusBar: View {
    let model: ParSetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRunning {
                // While fading out after the run, show a full bar instead of a stale phase.
                ParProgressBar(percent: model.isRunning ? model.progress?.percent : 100,
                               phase: model.isRunning ? progressPhase : "")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .center, spacing: 12) {
                if let icon = statusIcon {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 24, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(icon.tint)
                        .frame(width: 30)
                        .transition(.scale.combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 3) {
                    if !model.status.text.isEmpty {
                        Text(model.status.text)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(model.status.isFailure ? Color.red : Color.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.files.isEmpty {
                        figures
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .animation(.easeInOut(duration: 0.25), value: model.isRunning)
        .animation(.easeInOut(duration: 0.2), value: model.status)
    }

    private var statusIcon: (symbol: String, tint: Color)? {
        guard !model.isRunning else { return nil }
        switch model.status {
        case .allCorrect, .created, .onlyUnprotectedProblems: return ("checkmark.seal.fill", .green)
        case .repaired: return ("wand.and.sparkles", .accentColor)
        case .canceled: return ("stop.circle.fill", .secondary)
        case .waiting: return ("clock.fill", .secondary)
        case .needMoreBlocks, .needMoreVolumes, .invalidParFile, .failed, .engineUnavailable:
            return ("xmark.octagon.fill", .red)
        case .idle, .verifying, .repairing, .creating: return nil
        }
    }

    @ViewBuilder
    private var figures: some View {
        HStack(spacing: 18) {
            switch model.format {
            case .par2:
                Figure("Total", "\(model.files.count)")
                Figure("Good", "\(model.goodFileCount)")
                if let blocks = model.statistics.missingRecoveryBlocks, let bytes = model.statistics.missingBytes {
                    Figure("Need", String(localized: "\(blocks) blocks = \(bytes.formatted(.byteCount(style: .file)))"), tint: .red)
                }
            case .par1:
                Figure("Good files", "\(model.goodFileCount)")
                Figure("Damaged files", "\(model.damagedFileCount)", tint: model.damagedFileCount > 0 ? .orange : nil)
                Figure("Missing files", "\(model.missingFileCount)", tint: model.missingFileCount > 0 ? .orange : nil)
                Figure("Recovery files", "\(model.par1VolumeCount)")
            }
        }
        .font(.callout)
    }

    /// The engine's phase ("Scanning", "Repairing", …), or what the window is doing before it reports one.
    private var progressPhase: String {
        if let phase = model.progress?.phase { return Self.localizedPhase(phase) }
        switch model.status {
        case .waiting: return String(localized: "Waiting")
        case .repairing: return String(localized: "Repairing")
        case .creating: return String(localized: "Creating")
        default: return String(localized: "Verifying")
        }
    }

    /// The engines report their phases in English; unknown ones are shown as they are.
    private static func localizedPhase(_ phase: String) -> String {
        switch phase {
        case "Loading": String(localized: "Loading")
        case "Opening": String(localized: "Opening")
        case "Scanning": String(localized: "Scanning")
        case "Verifying": String(localized: "Verifying")
        case "Repairing": String(localized: "Repairing")
        case "Hashing": String(localized: "Hashing")
        case "Creating": String(localized: "Creating")
        case "Processing": String(localized: "Processing")
        case "Constructing": String(localized: "Constructing")
        case "Writing": String(localized: "Writing")
        default: phase
        }
    }
}

/// "Label value" pair in the status bar.
private struct Figure: View {
    let label: LocalizedStringKey
    let value: String
    var tint: Color?

    init(_ label: LocalizedStringKey, _ value: String, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
    }
}

// MARK: - Table cells

private enum ParSetRow: Identifiable {
    case data(TargetFile)
    case recovery(RecoveryFile)

    var id: String {
        switch self {
        case .data(let file): file.id
        case .recovery(let file): file.id
        }
    }
}

/// File type icon and name; a subfolder path is shown in front of the name, subdued.
private struct FileNameCell: View {
    let name: String
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: Self.icon(for: name))
                .resizable()
                .frame(width: 18, height: 18)
                .opacity(dimmed ? 0.55 : 1)
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            (parts.count > 1
                ? Text(parts.dropLast().joined(separator: "/") + "/").foregroundStyle(.tertiary) + Text(String(parts.last!))
                : Text(name))
                .foregroundStyle(dimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @MainActor private static var iconCache: [String: NSImage] = [:]

    @MainActor
    private static func icon(for name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let cached = iconCache[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        iconCache[ext] = icon
        return icon
    }
}

/// Capsule-shaped label with an optional symbol.
private struct Badge: View {
    let text: String
    var symbol: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
        .help(text)
    }
}

private struct StatusBadge: View {
    let state: TargetFileState

    var body: some View {
        switch state {
        case .pending:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(state.description).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .ok:
            Badge(text: state.description, symbol: "checkmark", tint: .green)
        case .okAfterRenaming:
            Badge(text: state.description, symbol: "arrow.left.arrow.right", tint: .green)
        case .repaired:
            Badge(text: state.description, symbol: "wand.and.sparkles", tint: .accentColor)
        case .recoverable:
            Badge(text: state.description, symbol: "bandage.fill", tint: .orange)
        case .missing, .damaged:
            Badge(text: state.description, symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .unrecoverable:
            Badge(text: state.description, symbol: "xmark", tint: .red)
        case .notInParSet:
            Badge(text: state.description, symbol: "plus", tint: .secondary)
        }
    }
}

/// Shown in an untitled set before any files were added.
private struct EmptySetPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop files or folders here")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Or click Add in the toolbar to choose them.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 20)
        .allowsHitTesting(false)
    }
}

extension RecoveryFile.Kind {
    var description: String {
        switch self {
        case .index: String(localized: "Index file")
        case .blocks(let count): String(localized: "Recovery blocks: \(count)")
        case .volume(let number): String(localized: "Recovery volume \(number)")
        }
    }
}

extension TargetFileState: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .notInParSet: String(localized: "Not in PAR set yet")
        case .pending: ""
        case .checking: String(localized: "Checking…")
        case .ok: String(localized: "OK")
        case .okAfterRenaming(let from): String(localized: "OK after renaming “\(from)”")
        case .missing: String(localized: "Missing")
        case .damaged(_, 0): String(localized: "Damaged")
        case let .damaged(found, total): String(localized: "Damaged (\(found) of \(total) blocks found)")
        case .recoverable(true): String(localized: "Missing, but can be recovered")
        case .recoverable(false): String(localized: "Damaged, but can be recovered")
        case .unrecoverable(true): String(localized: "Missing and cannot be recovered")
        case .unrecoverable(false): String(localized: "Damaged and cannot be recovered")
        case .repaired: String(localized: "Recovered successfully")
        }
    }
}

import ParityKit
import SwiftUI
import UniformTypeIdentifiers

/// Content of a par set window: file table, statistics, status line and raw par2 output.
struct ParSetView: View {
    @Bindable var model: ParSetModel
    var onAddFiles: ([URL]) -> Void

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                fileTable
                Divider()
                footer
            }
            .frame(minHeight: 300)

            if model.showsOutput {
                ScrollView {
                    Text(model.rawOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .defaultScrollAnchor(.bottom)
                .frame(minHeight: 80, idealHeight: 150)
            }
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 422, idealHeight: 500)
    }

    private var fileTable: some View {
        Table(model.files, selection: $model.selection) {
            TableColumn("") { file in
                StatusSymbol(state: file.state)
            }
            .width(20)
            TableColumn("File", value: \.name)
            TableColumn("Status") { file in
                HStack(spacing: 6) {
                    Text(file.state.description)
                        .foregroundStyle(file.state.needsAttention ? .red : .primary)
                    if !file.contributesToParity {
                        Text("No recovery data")
                            .foregroundStyle(.secondary)
                            .help("This file is checked, but it did not contribute to the recovery files, so it can't be restored.")
                    }
                }
            }
        }
        .alternatingRowBackgrounds()
        .dropDestination(for: URL.self) { urls, _ in
            guard model.parFile == nil else { return false }
            onAddFiles(urls)
            return true
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRunning {
                ParProgressBar(percent: model.progress?.percent, phase: progressPhase)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            statistics
            Text(model.status.text)
                .foregroundStyle(model.status.isSuccess ? .green : model.status.isFailure ? .red : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .animation(.easeInOut(duration: 0.25), value: model.isRunning)
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

    @ViewBuilder
    private var statistics: some View {
        switch model.format {
        case .par2:
            HStack(spacing: 16) {
                LabeledContent("Total", value: "\(model.files.count)")
                LabeledContent("Good", value: "\(model.goodFileCount)")
                if let blocks = model.statistics.missingRecoveryBlocks, let bytes = model.statistics.missingBytes {
                    LabeledContent("Need", value: String(localized: "\(blocks) blocks = \(bytes.formatted(.byteCount(style: .file)))"))
                }
            }
        case .par1:
            HStack(spacing: 16) {
                LabeledContent("Good files", value: "\(model.goodFileCount)")
                LabeledContent("Damaged files", value: "\(model.damagedFileCount)")
                LabeledContent("Missing files", value: "\(model.missingFileCount)")
                LabeledContent("Recovery files", value: "\(model.par1VolumeCount)")
            }
        }
    }
}

private struct StatusSymbol: View {
    let state: TargetFileState

    var body: some View {
        switch state {
        case .ok, .okAfterRenaming, .repaired:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .recoverable:
            Image(systemName: "bandage.fill").foregroundStyle(.orange)
        case .missing, .damaged:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .unrecoverable:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .notInParSet, .pending, .checking:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
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

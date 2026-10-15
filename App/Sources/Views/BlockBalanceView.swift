import ParityKit
import SwiftUI

/// What a set has and what a repair needs, in blocks (PAR2) or files (PAR1).
struct BlockBalance: Equatable {
    enum Unit { case blocks, files }

    var unit: Unit
    /// All data blocks (or protected files) of the set.
    var total: Int
    /// Intact before any repair.
    var present: Int
    /// Rebuilt by the last repair.
    var repaired: Int
    /// Recovery blocks (or volumes) on disk.
    var recovery: Int
    /// Recovery blocks (or volumes) still lacking for a repair.
    var shortfall: Int

    var missing: Int { max(0, total - present - repaired) }

    @MainActor
    init?(model: ParSetModel) {
        switch model.format {
        case .par2:
            let statistics = model.statistics
            // Until par2 reports what it found, the numbers would claim an intact set.
            guard statistics.totalDataBlocks > 0,
                  !model.isRunning || statistics.availableDataBlocks != nil else { return nil }
            let onDisk = model.recoveryFiles.reduce(0) { sum, file in
                if case .blocks(let count) = file.kind { sum + count } else { sum }
            }
            let available = statistics.availableDataBlocks ?? statistics.totalDataBlocks
            let damaged = statistics.totalDataBlocks - available
            let wasRepaired = if case .repaired = model.status { true } else { false }
            unit = .blocks
            total = statistics.totalDataBlocks
            present = available
            repaired = wasRepaired ? damaged : 0
            recovery = statistics.availableRecoveryBlocks ?? onDisk
            shortfall = statistics.missingRecoveryBlocks ?? 0
        case .par1:
            let protected = model.files.filter(\.contributesToParity)
            guard !protected.isEmpty, model.parFile != nil,
                  protected.allSatisfy({ $0.state != .pending && $0.state != .checking }) else { return nil }
            unit = .files
            total = protected.count
            repaired = protected.filter { $0.state == .repaired }.count
            present = protected.filter { !$0.state.needsAttention && $0.state != .repaired }.count
            recovery = model.par1VolumeCount
            shortfall = if case .needMoreVolumes(let count) = model.status { count } else { 0 }
        }
    }
}

/// Two bars: the data (intact, repaired, missing) and the recovery data
/// (available, still lacking), on the same scale so the shortfall is visible at a glance.
struct BlockBalanceView: View {
    let balance: BlockBalance

    private static let presentColor = Color.green
    private static let repairedColor = Color.accentColor
    private static let missingColor = Color.red
    private static let recoveryColor = Color(red: 0.16, green: 0.62, blue: 1.0)

    private var scale: Double {
        Double(max(balance.total, balance.recovery + balance.shortfall, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: balance.unit == .blocks ? String(localized: "Data") : String(localized: "Files"),
                value: "\(balance.present + balance.repaired) / \(balance.total)",
                segments: [
                    Segment(count: balance.present, color: Self.presentColor),
                    Segment(count: balance.repaired, color: Self.repairedColor),
                    Segment(count: balance.missing, color: Self.missingColor),
                ])
            row(label: String(localized: "Recovery"),
                value: balance.shortfall > 0 ? "\(balance.recovery) / \(balance.recovery + balance.shortfall)" : "\(balance.recovery)",
                segments: [
                    Segment(count: balance.recovery, color: Self.recoveryColor),
                    Segment(count: balance.shortfall, color: Self.missingColor, hatched: true),
                ])
            legend
        }
        .frame(width: 270)
        .help(helpText)
        .animation(.easeInOut(duration: 0.35), value: balance)
    }

    private func row(label: String, value: String, segments: [Segment]) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)
            BarTrack(segments: segments, scale: scale)
                .frame(height: 9)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            LegendItem(color: Self.presentColor, text: String(localized: "Intact"))
            if balance.repaired > 0 {
                LegendItem(color: Self.repairedColor, text: String(localized: "Repaired"))
            }
            if balance.missing > 0 || balance.shortfall > 0 {
                LegendItem(color: Self.missingColor, text: String(localized: "Missing"))
            }
            LegendItem(color: Self.recoveryColor, text: String(localized: "Recovery"))
        }
        .padding(.leading, 86)
    }

    private var helpText: String {
        switch balance.unit {
        case .blocks:
            String(localized: "\(balance.present) of \(balance.total) data blocks intact, \(balance.recovery) recovery blocks available, \(balance.shortfall) more needed.")
        case .files:
            String(localized: "\(balance.present) of \(balance.total) files intact, \(balance.recovery) recovery files available, \(balance.shortfall) more needed.")
        }
    }
}

private struct Segment: Identifiable {
    var id: Int { count.hashValue ^ color.hashValue }
    let count: Int
    let color: Color
    var hatched = false
}

/// A rounded track with proportional, adjoining segments.
private struct BarTrack: View {
    let segments: [Segment]
    let scale: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.count > 0 {
                            // Keep tiny but nonzero shares visible.
                            let share = max(Double(segment.count) / scale * width, 3)
                            Group {
                                if segment.hatched {
                                    Hatch(color: segment.color)
                                } else {
                                    LinearGradient(colors: [segment.color.opacity(0.85), segment.color],
                                                   startPoint: .top, endPoint: .bottom)
                                }
                            }
                            .frame(width: share)
                        }
                    }
                }
                .clipShape(Capsule())
            }
        }
    }
}

/// Diagonal stripes for the recovery data that is still lacking.
private struct Hatch: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.22)))
            var stripes = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4
            }
            context.stroke(stripes, with: .color(color.opacity(0.85)), lineWidth: 1.4)
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

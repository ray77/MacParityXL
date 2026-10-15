import SwiftUI

/// Full-width blue progress bar for par checks, repairs and creation.
/// Shows the engine's current phase and percentage; without a percentage it runs
/// an indeterminate sweep.
struct ParProgressBar: View {
    /// 0…100, or nil while the engine hasn't reported progress yet.
    var percent: Double?
    var phase: String

    private static let blueGradient = LinearGradient(
        colors: [Color(red: 0.05, green: 0.36, blue: 0.95), Color(red: 0.16, green: 0.62, blue: 1.0), Color(red: 0.36, green: 0.84, blue: 1.0)],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(phase)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let percent {
                    Text(percent / 100, format: .percent.precision(.fractionLength(0)))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color(red: 0.16, green: 0.62, blue: 1.0))
                        .contentTransition(.numericText(value: percent))
                }
            }
            track
                .frame(height: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase)
        .accessibilityValue(percent.map { "\(Int($0)) %" } ?? "")
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.blue.opacity(0.14))
                    .overlay(Capsule().strokeBorder(Color.blue.opacity(0.22), lineWidth: 0.5))

                if let percent {
                    fill
                        .frame(width: max(10, width * min(1, percent / 100)))
                        .animation(.easeOut(duration: 0.3), value: percent)
                } else {
                    IndeterminateSweep(gradient: Self.blueGradient, width: width)
                }
            }
        }
    }

    private var fill: some View {
        Capsule()
            .fill(Self.blueGradient)
            .overlay(Shine().clipShape(Capsule()))
            .overlay(
                // Glassy top highlight.
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                    .padding(.horizontal, 2)
                    .padding(.top, 1)
            )
            .shadow(color: Color(red: 0.16, green: 0.62, blue: 1.0).opacity(0.55), radius: 5)
    }
}

/// A soft highlight that keeps sliding across the filled part.
private struct Shine: View {
    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geometry in
                let period = 1.8
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let band = max(40, geometry.size.width * 0.25)
                LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: -band + (geometry.size.width + band) * phase)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A blue segment moving back and forth while the percentage is unknown.
private struct IndeterminateSweep: View {
    let gradient: LinearGradient
    let width: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let period = 1.4
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            // Ease in and out between the two ends.
            let eased = (1 - cos(t * 2 * .pi)) / 2
            let segment = width * 0.3
            Capsule()
                .fill(gradient)
                .frame(width: segment)
                .offset(x: (width - segment) * eased)
                .shadow(color: Color(red: 0.16, green: 0.62, blue: 1.0).opacity(0.55), radius: 5)
        }
    }
}


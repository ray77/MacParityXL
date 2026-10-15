import AppKit
import SwiftUI

/// The About window: a large app icon instead of the standard panel's small one,
/// plus the bundled engines and their licenses.
struct AboutView: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    private var name: String { info["CFBundleName"] as? String ?? "MacParityXL" }
    private var version: String { info["CFBundleShortVersionString"] as? String ?? "" }
    private var build: String { info["CFBundleVersion"] as? String ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .padding(.bottom, 14)

            Text(name)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Version \(version) (\(build))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            Text("Verify, repair and create PAR2 and PAR1 sets, and extract RAR archives.")
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Divider()
                .padding(.vertical, 16)

            VStack(alignment: .leading, spacing: 8) {
                Text("Includes")
                    .font(.headline)
                engine("par2cmdline-turbo", role: String(localized: "PAR2 engine, GPL-2.0"),
                       license: "par2cmdline-turbo-COPYING.txt")
                engine("UnRAR", role: String(localized: "RAR extraction, © Alexander Roshal"),
                       license: "unrar-license.txt")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(width: 400)
    }

    private func engine(_ title: String, role: String, license: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(role).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("License") {
                if let url = Bundle.main.url(forResource: license, withExtension: nil, subdirectory: "licenses")
                    ?? Bundle.main.url(forResource: license, withExtension: nil) {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }
}

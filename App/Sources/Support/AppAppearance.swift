import AppKit

/// Light or dark mode for the app's windows, independent of the system if the user wants.
enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic (System)")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    private static let key = "appearance"

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init) ?? .automatic
    }

    /// Stores the choice and applies it to all windows right away.
    @MainActor
    static func set(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: key)
        appearance.apply()
    }

    @MainActor
    func apply() {
        NSApp.appearance = switch self {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

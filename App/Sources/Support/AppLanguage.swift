import AppKit

/// The app's UI language. `.automatic` follows the system's preferred languages;
/// the others override them through the app's own `AppleLanguages` default.
enum AppLanguage: String, CaseIterable, Identifiable {
    case automatic = ""
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case ukrainian = "uk"

    var id: String { rawValue }

    /// Languages are listed by their own name, so they can be found in any UI language.
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic (System)")
        case .english: "English"
        case .german: "Deutsch"
        case .french: "Français"
        case .spanish: "Español"
        case .ukrainian: "Українська"
        }
    }

    private static let key = "AppleLanguages"

    /// The language set in the app's own defaults domain (ignoring the global one).
    static var current: AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String],
              let first = languages.first
        else { return .automatic }
        return allCases.first { $0 != .automatic && first.hasPrefix($0.rawValue) } ?? .automatic
    }

    /// Takes effect the next time the app is launched.
    static func set(_ language: AppLanguage) {
        if language == .automatic {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

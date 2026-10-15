import Foundation

/// Locations of the command-line engines shipped inside the app bundle.
enum BundledTools {
    static var par2: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/par2")
    }
}

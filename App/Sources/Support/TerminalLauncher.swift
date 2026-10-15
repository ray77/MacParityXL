import Foundation

/// Runs a post-processing command in a new Terminal window.
enum TerminalLauncher {
    @MainActor
    static func run(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped); exit"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Notifier.post(
                title: String(localized: "Post-processing failed"),
                subtitle: command,
                body: error[NSAppleScript.errorMessage] as? String ?? ""
            )
        }
    }
}

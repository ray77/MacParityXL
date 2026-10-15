import Foundation

/// A rule applied to a par set after it verified or repaired successfully.
/// Rules are evaluated top to bottom; the first one with a matching file wins.
public struct PostProcessRule: Identifiable, Codable, Equatable, Sendable {
    public enum Relation: String, Codable, Sendable, CaseIterable {
        case endsWith
        case contains
    }

    public enum Action: Codable, Equatable, Sendable {
        case builtInUnrar
        case openInFinder
        case openWithApplication(bundleURL: URL)
        /// A shell command run in Terminal; may contain macros, see `Macro`.
        case commandLine(String)
    }

    public var id = UUID()
    public var name: String
    public var relation: Relation
    public var pattern: String
    public var ignoresCase: Bool
    public var action: Action

    public init(name: String, relation: Relation, pattern: String, ignoresCase: Bool = true, action: Action) {
        self.name = name
        self.relation = relation
        self.pattern = pattern
        self.ignoresCase = ignoresCase
        self.action = action
    }

    public var isBuiltIn: Bool { action == .builtInUnrar }

    public func matches(fileName: String) -> Bool {
        let options: String.CompareOptions = ignoresCase ? [.caseInsensitive] : []
        switch relation {
        case .endsWith:
            return fileName.range(of: pattern, options: options.union(.anchored).union(.backwards)) != nil
        case .contains:
            return fileName.range(of: pattern, options: options) != nil
        }
    }

    /// The rule that applies to a set and the file that triggered it.
    public static func firstMatch(in rules: [PostProcessRule], fileNames: [String]) -> (rule: PostProcessRule, fileName: String)? {
        for rule in rules {
            if let name = fileNames.first(where: rule.matches) {
                return (rule, name)
            }
        }
        return nil
    }

    public static let standardRules: [PostProcessRule] = [
        PostProcessRule(name: "Zip archive", relation: .endsWith, pattern: ".zip", action: .openInFinder),
        PostProcessRule(name: "7-Zip archive", relation: .endsWith, pattern: ".7z", action: .openInFinder),
        PostProcessRule(name: "Built-in Unrar", relation: .endsWith, pattern: ".rar", action: .builtInUnrar),
    ]
}

/// Placeholders a command-line rule can contain, replaced for the triggering file.
public enum Macro: String, CaseIterable, Sendable {
    /// Full path.
    case fullPath = "«F»"
    /// Full path without extension.
    case fullPathWithoutExtension = "«E»"
    /// File name.
    case fileName = "«L»"
    /// File name without extension.
    case fileNameWithoutExtension = "«K»"
    /// File name with the part that matched the rule removed.
    case fileNameWithoutMatch = "«A»"
    /// Containing directory, no trailing slash.
    case directory = "«D»"

    /// Expands all macros. Values are single-quoted for the shell.
    public static func expand(_ command: String, file: URL, rule: PostProcessRule) -> String {
        var result = command
        for macro in allCases {
            result = result.replacingOccurrences(of: macro.rawValue, with: shellQuoted(macro.value(for: file, rule: rule)))
        }
        return result
    }

    func value(for file: URL, rule: PostProcessRule) -> String {
        let name = file.lastPathComponent
        switch self {
        case .fullPath:
            return file.path
        case .fullPathWithoutExtension:
            return file.deletingPathExtension().path
        case .fileName:
            return name
        case .fileNameWithoutExtension:
            return file.deletingPathExtension().lastPathComponent
        case .fileNameWithoutMatch:
            let options: String.CompareOptions = rule.ignoresCase ? [.caseInsensitive] : []
            let searchOptions = rule.relation == .endsWith ? options.union([.anchored, .backwards]) : options
            guard let range = name.range(of: rule.pattern, options: searchOptions) else { return name }
            return name.replacingCharacters(in: range, with: "")
        case .directory:
            return file.deletingLastPathComponent().path
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

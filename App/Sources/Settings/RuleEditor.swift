import AppKit
import ParityKit
import SwiftUI

/// Sheet for creating or changing a post-processing rule.
struct RuleEditor: View {
    private enum ActionKind: Hashable {
        case openInFinder, openWithApplication, commandLine
    }

    @State private var name: String
    @State private var relation: PostProcessRule.Relation
    @State private var pattern: String
    @State private var ignoresCase: Bool
    @State private var actionKind: ActionKind
    @State private var application: URL?
    @State private var command: String

    private let original: PostProcessRule?
    private let onSave: (PostProcessRule) -> Void
    @Environment(\.dismiss) private var dismiss

    init(rule: PostProcessRule?, onSave: @escaping (PostProcessRule) -> Void) {
        original = rule
        self.onSave = onSave
        _name = State(initialValue: rule?.name ?? "")
        _relation = State(initialValue: rule?.relation ?? .endsWith)
        _pattern = State(initialValue: rule?.pattern ?? "")
        _ignoresCase = State(initialValue: rule?.ignoresCase ?? true)
        switch rule?.action {
        case .openWithApplication(let url):
            _actionKind = State(initialValue: .openWithApplication)
            _application = State(initialValue: url)
            _command = State(initialValue: "")
        case .commandLine(let command):
            _actionKind = State(initialValue: .commandLine)
            _application = State(initialValue: nil)
            _command = State(initialValue: command)
        default:
            _actionKind = State(initialValue: .openInFinder)
            _application = State(initialValue: nil)
            _command = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField("Description", text: $name)

                Section("If the PAR set contains a file whose name") {
                    HStack {
                        Picker("", selection: $relation) {
                            Text("ends with").tag(PostProcessRule.Relation.endsWith)
                            Text("contains").tag(PostProcessRule.Relation.contains)
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("", text: $pattern, prompt: Text(".zip"))
                    }
                    Toggle("Ignore case", isOn: $ignoresCase)
                }

                Section("Then") {
                    Picker("", selection: $actionKind) {
                        Text("Open it (like a double-click in Finder)").tag(ActionKind.openInFinder)
                        Text("Open it with an application").tag(ActionKind.openWithApplication)
                        Text("Run a command in Terminal").tag(ActionKind.commandLine)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    switch actionKind {
                    case .openInFinder:
                        EmptyView()
                    case .openWithApplication:
                        HStack {
                            if let application {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                Text(application.deletingPathExtension().lastPathComponent)
                            } else {
                                Text("No application chosen").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose…", action: chooseApplication)
                        }
                    case .commandLine:
                        HStack(alignment: .top) {
                            TextField("", text: $command, prompt: Text("unzip «F» -d «D»"), axis: .vertical)
                                .lineLimit(2...4)
                                .font(.system(.body, design: .monospaced))
                            Menu("Insert") {
                                ForEach(Macro.allCases, id: \.self) { macro in
                                    Button("\(macro.title) \(macro.rawValue)") { command += macro.rawValue }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 500, height: 470)
    }

    private var isValid: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasPattern = !pattern.isEmpty
        switch actionKind {
        case .openInFinder: return hasName && hasPattern
        case .openWithApplication: return hasName && hasPattern && application != nil
        case .commandLine: return hasName && hasPattern && !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func save() {
        let action: PostProcessRule.Action
        switch actionKind {
        case .openInFinder: action = .openInFinder
        case .openWithApplication: action = .openWithApplication(bundleURL: application!)
        case .commandLine: action = .commandLine(command)
        }
        var rule = PostProcessRule(name: name, relation: relation, pattern: pattern, ignoresCase: ignoresCase, action: action)
        if let original {
            rule.id = original.id
        }
        onSave(rule)
        dismiss()
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            application = panel.url
        }
    }
}

private extension Macro {
    var title: String {
        switch self {
        case .fullPath: String(localized: "Full path")
        case .fullPathWithoutExtension: String(localized: "Full path without extension")
        case .fileName: String(localized: "File name")
        case .fileNameWithoutExtension: String(localized: "File name without extension")
        case .fileNameWithoutMatch: String(localized: "File name without matching part")
        case .directory: String(localized: "Folder")
        }
    }
}

import AppKit
import ParityKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CreationSettings().tabItem { Label("Creation", systemImage: "doc.badge.plus") }
            UnrarSettings().tabItem { Label("Unrar", systemImage: "archivebox") }
            RulesSettings().tabItem { Label("Post-processing", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 600)
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var language = AppLanguage.current
    /// The language the running app was launched with, to tell whether a restart is pending.
    @State private var launchedLanguage = AppLanguage.current
    @State private var appearance = AppAppearance.current

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: appearance) { AppAppearance.set(appearance) }
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { AppLanguage.set(language) }
                if language != launchedLanguage {
                    HStack {
                        Text("The new language is used after restarting MacParityXL.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                    }
                }
            }
            Section {
                Picker("New document type", selection: $settings.defaultFormat) {
                    Text("PAR2").tag(ParFormat.par2)
                    Text("PAR1").tag(ParFormat.par1)
                }
                Picker("When opening several files", selection: $settings.processSimultaneously) {
                    Text("Process them one by one").tag(false)
                    Text("Process them simultaneously").tag(true)
                }
            }
            Section {
                Toggle("Move PAR files to Trash after a successful check", isOn: $settings.autoDeleteParFiles)
                Toggle("Close the window after automatic post-processing", isOn: $settings.closeWindowAfterPostProcessing)
            }
            Section {
                Toggle(isOn: $settings.runUnattended) {
                    Text("Run unattended")
                    Text("Unattended runs show no dialogs. Existing items are kept, passwords are skipped, and errors are reported as notifications.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CreationSettings: View {
    @Bindable private var settings = AppSettings.shared

    private var isFixedCount: Binding<Bool> {
        Binding(
            get: { if case .fixed = settings.par1RecoveryCount { true } else { false } },
            set: { settings.par1RecoveryCount = $0 ? .fixed(par1Number) : .onePer(files: par1Number) }
        )
    }

    private var par1Number: Int {
        switch settings.par1RecoveryCount {
        case .onePer(let n), .fixed(let n): n
        }
    }

    private var par1NumberBinding: Binding<Int> {
        Binding(
            get: { par1Number },
            set: { settings.par1RecoveryCount = isFixedCount.wrappedValue ? .fixed(max(0, $0)) : .onePer(files: max(1, $0)) }
        )
    }

    private var blockSizeKB: Binding<Int> {
        Binding(
            get: { if case .kilobytes(let kb) = settings.par2Options.blockSize { kb } else { 0 } },
            set: { settings.par2Options.blockSize = $0 > 0 ? .kilobytes($0) : .automatic }
        )
    }

    var body: some View {
        Form {
            Section("PAR2") {
                LabeledContent("Redundancy") {
                    HStack(spacing: 4) {
                        TextField("", value: $settings.par2Options.redundancyPercent, format: .number)
                            .frame(width: 50)
                        Stepper("", value: $settings.par2Options.redundancyPercent, in: 1...100)
                            .labelsHidden()
                        Text("%")
                    }
                }
                Toggle("Limit recovery file size to the largest data file", isOn: $settings.par2Options.limitRecoveryFileSize)
                LabeledContent("Block size") {
                    HStack {
                        TextField("", value: blockSizeKB, format: .number).frame(width: 70)
                        Text("KB (0 = automatic)")
                    }
                }
            }
            Section("PAR1 recovery files") {
                Picker("", selection: isFixedCount) {
                    Text("One for every \(par1Number) files").tag(false)
                    Text("\(par1Number), independent of the number of files").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                LabeledContent("Number") {
                    HStack(spacing: 4) {
                        TextField("", value: par1NumberBinding, format: .number)
                            .frame(width: 50)
                        Stepper("", value: par1NumberBinding, in: isFixedCount.wrappedValue ? 0...99 : 1...99)
                            .labelsHidden()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UnrarSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Picker("Extract to", selection: $settings.unrarDestination) {
                Text("The archive's folder").tag(AppSettings.UnrarDestination.besideArchive)
                Text("Ask every time").tag(AppSettings.UnrarDestination.askEveryTime)
                Text(settings.unrarFixedFolder?.lastPathComponent ?? String(localized: "A fixed folder…"))
                    .tag(AppSettings.UnrarDestination.fixedFolder)
            }
            .onChange(of: settings.unrarDestination) { _, newValue in
                if newValue == .fixedFolder { chooseFixedFolder() }
            }
            Picker("If the destination exists", selection: $settings.existingDestinationAction) {
                Text("Ask").tag(AppSettings.ExistingDestinationAction.ask)
                Text("Overwrite").tag(AppSettings.ExistingDestinationAction.overwrite)
                Text("Keep both").tag(AppSettings.ExistingDestinationAction.keepBoth)
                Text("Cancel").tag(AppSettings.ExistingDestinationAction.cancel)
            }
            Picker("After a successful unrar", selection: $settings.segmentsAfterUnrar) {
                Text("Leave the segments").tag(AppSettings.SegmentsAfterUnrar.leave)
                Text("Move segments to Trash").tag(AppSettings.SegmentsAfterUnrar.moveToTrash)
                Text("Delete segments permanently").tag(AppSettings.SegmentsAfterUnrar.delete)
            }
            Toggle("Keep incorrectly extracted (broken) files", isOn: $settings.keepBrokenFiles)
        }
        .formStyle(.grouped)
    }

    private func chooseFixedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            settings.unrarFixedFolder = url
        } else if settings.unrarFixedFolder == nil {
            settings.unrarDestination = .besideArchive
        }
    }
}

private struct RulesSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var selection: PostProcessRule.ID?
    @State private var editing: EditTarget?

    private enum EditTarget: Identifiable {
        case new
        case existing(PostProcessRule)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let rule): rule.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Automatically post-process files after repair", isOn: $settings.autoPostProcess)
            HStack(alignment: .top) {
                List(selection: $selection) {
                    ForEach(settings.postProcessRules) { rule in
                        VStack(alignment: .leading) {
                            Text(displayName(of: rule))
                            Text(summary(of: rule)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(rule.id)
                    }
                }
                .frame(minHeight: 180)
                VStack(spacing: 8) {
                    Button { editing = .new } label: { Text("New Rule…").frame(maxWidth: .infinity) }
                    Button { selectedRule.map { editing = .existing($0) } } label: { Text("Modify…").frame(maxWidth: .infinity) }
                        .disabled(selectedRule.map(\.isBuiltIn) ?? true)
                    HStack(spacing: 8) {
                        Button { move(by: -1) } label: { Image(systemName: "chevron.up").frame(maxWidth: .infinity) }
                            .disabled(!canMove(by: -1))
                        Button { move(by: 1) } label: { Image(systemName: "chevron.down").frame(maxWidth: .infinity) }
                            .disabled(!canMove(by: 1))
                    }
                    Button { delete() } label: { Text("Delete").frame(maxWidth: .infinity) }
                        .disabled(selectedRule.map(\.isBuiltIn) ?? true)
                    Spacer().frame(height: 4)
                    Button { settings.restoreStandardRules() } label: { Text("Standard").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered)
                .frame(width: 140)
            }
        }
        .padding(20)
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                RuleEditor(rule: nil) { insert($0) }
            case .existing(let rule):
                RuleEditor(rule: rule) { replace($0) }
            }
        }
    }

    /// New rules go just above the built-in Unrar rule, which always stays last.
    private func insert(_ rule: PostProcessRule) {
        let index = settings.postProcessRules.firstIndex(where: \.isBuiltIn) ?? settings.postProcessRules.endIndex
        settings.postProcessRules.insert(rule, at: index)
        selection = rule.id
    }

    private func replace(_ rule: PostProcessRule) {
        guard let index = settings.postProcessRules.firstIndex(where: { $0.id == rule.id }) else { return }
        settings.postProcessRules[index] = rule
    }

    private var selectedRule: PostProcessRule? {
        settings.postProcessRules.first { $0.id == selection }
    }

    /// The standard rules are stored with English names; show those translated until the user renames them.
    private func displayName(of rule: PostProcessRule) -> String {
        switch rule.name {
        case "Zip archive": String(localized: "Zip archive")
        case "7-Zip archive": String(localized: "7-Zip archive")
        case "Built-in Unrar": String(localized: "Built-in Unrar")
        default: rule.name
        }
    }

    private func summary(of rule: PostProcessRule) -> String {
        let condition = rule.relation == .endsWith
            ? String(localized: "ends with “\(rule.pattern)”")
            : String(localized: "contains “\(rule.pattern)”")
        let action = switch rule.action {
        case .builtInUnrar: String(localized: "Built-in Unrar")
        case .openInFinder: String(localized: "Open")
        case .openWithApplication(let url): String(localized: "Open with \(url.deletingPathExtension().lastPathComponent)")
        case .commandLine(let command): command
        }
        return "\(condition) → \(action)"
    }

    /// The built-in Unrar rule always stays last.
    private func canMove(by offset: Int) -> Bool {
        guard let index = settings.postProcessRules.firstIndex(where: { $0.id == selection }),
              !settings.postProcessRules[index].isBuiltIn else { return false }
        let target = index + offset
        return settings.postProcessRules.indices.contains(target) && !settings.postProcessRules[target].isBuiltIn
    }

    private func move(by offset: Int) {
        guard canMove(by: offset), let index = settings.postProcessRules.firstIndex(where: { $0.id == selection }) else { return }
        settings.postProcessRules.swapAt(index, index + offset)
    }

    private func delete() {
        settings.postProcessRules.removeAll { $0.id == selection && !$0.isBuiltIn }
        selection = nil
    }
}

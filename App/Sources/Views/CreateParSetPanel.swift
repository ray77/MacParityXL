import AppKit
import ParityKit
import SwiftUI

/// Save panel for "Create PAR Set…", with the amount of recovery data as accessory:
/// a redundancy percentage for PAR2, the number of .pNN files for PAR1.
@MainActor
enum CreateParSetPanel {
    static func run(for model: ParSetModel, in window: NSWindow) {
        guard let folder = model.sourceFolder else { return }
        let options = OptionsBox(par2: AppSettings.shared.par2Options, par1Count: model.defaultPar1RecoveryCount)
        let format = model.format

        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = model.suggestedParFileName
        panel.allowedContentTypes = [.init(importedAs: format == .par1 ? "org.parchive.par" : "org.parchive.par2")]
        panel.message = String(localized: "The PAR set must be saved in the folder that contains the files.")
        let accessory: AnyView = switch format {
        case .par2: AnyView(RedundancyField(options: options))
        case .par1: AnyView(RecoveryCountField(options: options))
        }
        panel.accessoryView = NSHostingView(rootView: accessory.padding())

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            // Both formats store names relative to the par file, so it has to sit next to the files.
            let target = folder.appending(path: url.lastPathComponent)
            Task {
                switch format {
                case .par2: await model.create(parFile: target, options: options.par2)
                case .par1: await model.createPar1(parFile: target, recoveryCount: options.par1Count)
                }
            }
        }
    }
}

@MainActor
@Observable
private final class OptionsBox {
    var par2: Par2CreateOptions
    var par1Count: Int

    init(par2: Par2CreateOptions, par1Count: Int) {
        self.par2 = par2
        self.par1Count = par1Count
    }
}

private struct RedundancyField: View {
    @Bindable var options: OptionsBox

    var body: some View {
        HStack {
            Text("Recovery data:")
            TextField("", value: $options.par2.redundancyPercent, format: .number)
                .frame(width: 50)
            Stepper("", value: $options.par2.redundancyPercent, in: 1...100)
                .labelsHidden()
            Text("%")
        }
    }
}

private struct RecoveryCountField: View {
    @Bindable var options: OptionsBox

    var body: some View {
        HStack {
            Text("Number of recovery files (.pNN):")
            TextField("", value: $options.par1Count, format: .number)
                .frame(width: 50)
            Stepper("", value: $options.par1Count, in: 0...99)
                .labelsHidden()
        }
    }
}

import AppKit

/// Customizable toolbar of a par set window. Items send their actions to the
/// first responder, so the document validates and handles them like menu items.
@MainActor
final class ParSetToolbar: NSObject, NSToolbarDelegate {
    private struct Item {
        let id: NSToolbarItem.Identifier
        let label: String
        let symbol: String
        let action: Selector
        let tip: String
    }

    private static let items: [Item] = [
        Item(id: .init("new"), label: String(localized: "New"), symbol: "doc.badge.plus",
             action: #selector(AppDelegate.newDefaultSet(_:)), tip: String(localized: "New PAR set")),
        Item(id: .init("open"), label: String(localized: "Open+Repair"), symbol: "wrench.and.screwdriver",
             action: #selector(NSDocumentController.openDocument(_:)), tip: String(localized: "Open a PAR set, verify it and repair if needed")),
        Item(id: .init("add"), label: String(localized: "Add"), symbol: "plus",
             action: #selector(ParSetDocument.addFiles(_:)), tip: String(localized: "Add files to the new PAR set")),
        Item(id: .init("remove"), label: String(localized: "Remove"), symbol: "minus",
             action: #selector(ParSetDocument.removeFiles(_:)), tip: String(localized: "Remove the selected files")),
        Item(id: .init("create"), label: String(localized: "Create"), symbol: "square.and.arrow.down",
             action: #selector(ParSetDocument.createParSet(_:)), tip: String(localized: "Create PAR files for the added files")),
        Item(id: .init("repair"), label: String(localized: "Repair Again"), symbol: "arrow.clockwise",
             action: #selector(ParSetDocument.repairAgain(_:)), tip: String(localized: "Check and repair again, e.g. after adding more recovery files")),
        Item(id: .init("cancel"), label: String(localized: "Cancel"), symbol: "stop.circle",
             action: #selector(ParSetDocument.cancelParOperation(_:)), tip: String(localized: "Cancel the running operation")),
        Item(id: .init("output"), label: String(localized: "Output"), symbol: "terminal",
             action: #selector(ParSetDocument.toggleParOutput(_:)), tip: String(localized: "Show or hide the par2 output")),
        Item(id: .init("settings"), label: String(localized: "Settings"), symbol: "gearshape",
             action: #selector(AppDelegate.showSettings(_:)), tip: String(localized: "Show settings")),
    ]

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ParSetToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconAndLabel
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("new"), .init("open"), .space, .init("add"), .init("remove"), .init("create"),
         .flexibleSpace, .init("repair"), .init("cancel")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.items.map(\.id) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let spec = Self.items.first(where: { $0.id == id }) else { return nil }
        let item = ValidatedToolbarItem(itemIdentifier: id)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.toolTip = spec.tip
        item.action = spec.action
        item.view = ToolbarCircleButton(image: Self.squareSymbol(spec.symbol, label: spec.label), label: spec.label, action: spec.action)
        return item
    }

    /// Centers every symbol in the same square canvas, so tall symbols such as
    /// `doc.badge.plus` look as large as the others.
    private static func squareSymbol(_ name: String, label: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration) else { return nil }
        let side: CGFloat = 22
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let size = symbol.size
            let scale = min(1, side / max(size.width, size.height))
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            symbol.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                   width: drawn.width, height: drawn.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }
}

private extension NSToolbarItem.Identifier {
    init(_ raw: String) { self.init(rawValue: raw) }
}

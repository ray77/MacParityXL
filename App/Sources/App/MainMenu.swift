import AppKit

/// Builds the menu bar in code (no nib). Items target the first responder,
/// so document actions reach the key window's ParSetDocument.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addSubmenu(appMenu())
        main.addSubmenu(fileMenu())
        main.addSubmenu(editMenu())
        main.addSubmenu(processMenu())
        let window = windowMenu()
        main.addSubmenu(window)
        NSApp.windowsMenu = window
        let help = NSMenu(title: String(localized: "Help"))
        main.addSubmenu(help)
        NSApp.helpMenu = help
        return main
    }

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.add(String(localized: "About \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        menu.add(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        menu.addItem(withTitle: services.title, action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.add(String(localized: "Hide \(name)"), #selector(NSApplication.hide(_:)), "h")
        menu.add(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        menu.add(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.add(String(localized: "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "menu.file", defaultValue: "File"))
        menu.add(String(localized: "New PAR2 Set"), #selector(AppDelegate.newPar2Set(_:)), "n")
        menu.add(String(localized: "New PAR1 Set"), #selector(AppDelegate.newPar1Set(_:)), "n", [.command, .option])
        menu.add(String(localized: "Open and Repair…"), #selector(NSDocumentController.openDocument(_:)), "o")
        let recent = NSMenu(title: String(localized: "Open Recent"))
        recent.add(String(localized: "Clear Menu"), #selector(NSDocumentController.clearRecentDocuments(_:)))
        menu.addItem(withTitle: recent.title, action: nil, keyEquivalent: "").submenu = recent
        menu.addItem(.separator())
        menu.add(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w")
        menu.add(String(localized: "Close All"), #selector(AppDelegate.closeAll(_:)), "w", [.command, .option])
        menu.add(String(localized: "Create PAR Set…"), #selector(ParSetDocument.createParSet(_:)), "s", [.command, .shift])
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.add(String(localized: "Copy"), #selector(NSText.copy(_:)), "c")
        menu.add(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a")
        menu.add(String(localized: "Select All Non-OK"), #selector(ParSetDocument.selectAllNonOK(_:)), "a", [.command, .option])
        menu.addItem(.separator())
        menu.add(String(localized: "Add Files…"), #selector(ParSetDocument.addFiles(_:)), "f", [.command, .shift])
        menu.add(String(localized: "Remove"), #selector(ParSetDocument.removeFiles(_:)), "\u{8}")
        menu.addItem(.separator())
        menu.add(String(localized: "Repair Again"), #selector(ParSetDocument.repairAgain(_:)), "r")
        menu.add(String(localized: "Cancel Operation"), #selector(ParSetDocument.cancelParOperation(_:)), ".")
        return menu
    }

    private static func processMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Process"))
        menu.add(String(localized: "Unrar Archive…"), #selector(AppDelegate.unrarArchive(_:)), "u")
        menu.add(String(localized: "Apply Rule"), #selector(ParSetDocument.applyRule(_:)))
        menu.add(String(localized: "Show par2 Output"), #selector(ParSetDocument.toggleParOutput(_:)))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.add(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        menu.add(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        menu.add(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }
}

private extension NSMenu {
    func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
    }

    func addSubmenu(_ submenu: NSMenu) {
        addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
    }
}

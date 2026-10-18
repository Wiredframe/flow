import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var grid: GridViewController?
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let grid = GridViewController()
        let window = NSWindow(contentViewController: grid)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Erst mit Toolbar stehen Titel und Untertitel links untereinander, das Raster läuft darunter durch.
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 400, height: 300)
        if !window.setFrameUsingName("Main") {
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.center()
        }
        window.setFrameAutosaveName("Main")
        self.window = window
        self.grid = grid

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        let last = UserDefaults.standard.string(forKey: "lastFolder").map { URL(fileURLWithPath: $0) }
        if let url = pendingURL ?? last { grid.open(url) }

        ThumbnailCache.shared.prune()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let grid {
            grid.open(url)
            window?.makeKeyAndOrderFront(nil)
        } else {
            pendingURL = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let host = NSMenuItem()
            host.submenu = menu
            main.addItem(host)
            return menu
        }

        submenu("Flow", [
            item("Über Flow", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Flow ausblenden", #selector(NSApplication.hide(_:)), "h"),
            item("Andere ausblenden", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Alle einblenden", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Flow beenden", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Ablage", [
            item("Ordner öffnen …", #selector(GridViewController.openFolder(_:)), "o"),
            item("Im Finder zeigen", #selector(GridViewController.showInFinder(_:)), "r"),
            .separator(),
            item("Fenster schließen", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Darstellung", [
            item("Dateinamen", #selector(GridViewController.toggleNames(_:)), "n", [.command, .shift]),
            item("Ton", #selector(GridViewController.toggleSound(_:)), "m", []),
            .separator(),
            item("Größer", #selector(GridViewController.zoomIn(_:)), "+"),
            item("Kleiner", #selector(GridViewController.zoomOut(_:)), "-"),
            .separator(),
            item("Vollbild", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        NSApp.windowsMenu = submenu("Fenster", [
            item("Im Dock ablegen", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoomen", #selector(NSWindow.performZoom(_:))),
        ])

        NSApp.mainMenu = main
    }
}

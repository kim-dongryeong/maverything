import AppKit
import MaverythingCore
import SwiftUI
import UniformTypeIdentifiers

/// The gear/options button as an AppKit NSButton + NSMenu. Built fresh on each
/// click from current state, so live-refresh re-renders never reposition it
/// (a SwiftUI `Menu` bounces because the open menu rebuilds on every @Published change).
struct OptionsButton: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coord { Coord(model: model) }

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleProportionallyDown
        b.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Options")
        b.imagePosition = .imageOnly
        b.target = context.coordinator
        b.action = #selector(Coord.show(_:))
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    func updateNSView(_ nsView: NSButton, context: Context) { context.coordinator.model = model }

    @MainActor
    final class Coord: NSObject {
        var model: AppModel
        init(model: AppModel) { self.model = model }

        @objc func show(_ sender: NSButton) {
            let m = NSMenu()
            group(m, "Layout", UILayout.allCases.map(\.label),
                  selected: UILayout.allCases.firstIndex(of: model.layout) ?? 0, cmd: "layout")
            // (Matching lives in the search bar's match menu + menu-bar Search —
            // the gear is VIEW & APP options only, so nothing is listed twice.)
            group(m, "Sort by", ["Name", "Path", "Size", "Date Modified", "Date Created", "Relevance", "Run Count"],
                  selected: sortIndex(model.sortKey), cmd: "sort",
                  keys: ["1", "2", "3", "4", "5", "6", "7"], keyMask: [.control])
            group(m, "Appearance", Appearance.allCases.map(\.label),
                  selected: Appearance.allCases.firstIndex(of: model.appearance) ?? 0, cmd: "appear")
            group(m, "Density", RowDensity.allCases.map(\.label),
                  selected: RowDensity.allCases.firstIndex(of: model.density) ?? 0, cmd: "density")
            group(m, "Thumbnail Size", ["Medium", "Large", "Extra Large"],
                  selected: model.thumbSize >= 176 ? 2 : (model.thumbSize >= 128 ? 1 : 0), cmd: "thumb")
            check(m, "Ascending", model.ascending, cmd: "asc", key: "0", mask: [.control])
            check(m, "Folders First", model.foldersFirst, cmd: "ff")
            check(m, "Show Hidden Files", model.showHidden, cmd: "hidden")
            check(m, "Icon Preview in List", model.iconPreview, cmd: "iconprev")
            m.addItem(.separator())
            check(m, "Include cloud storage (Google Drive, iCloud…)", model.includeCloud, cmd: "cloud")
            item(m, "Reindex Now", cmd: "reindex")
            if !model.hasFullDiskAccess { item(m, "Grant Full Disk Access…", cmd: "fda") }
            m.addItem(.separator())
            item(m, "Copy All Paths", cmd: "copypaths")
            item(m, "Export Results as CSV…", cmd: "export")
            m.addItem(.separator())
            item(m, "Check for Updates…", cmd: "update")
            item(m, "Settings…", cmd: "settings")
            m.addItem(.separator())
            // With no menu-bar icon, the gear is the app's only clickable Quit
            // (⌘Q still works whenever a window is frontmost).
            let quit = NSMenuItem(title: "Quit Maverything", action: #selector(pick(_:)), keyEquivalent: "q")
            quit.target = self; quit.representedObject = "quit:0"
            m.addItem(quit)
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        private func exportCSV() {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Maverything results.csv"
            panel.canCreateDirectories = true
            panel.title = "Export Results"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let csv = model.buildResultsCSV()
            do { try csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { NSSound.beep() }
        }

        private func sortIndex(_ k: SortKey) -> Int {
            switch k { case .name: 0; case .path: 1; case .size: 2; case .dateModified: 3
                       case .dateCreated: 4; case .relevance: 5; case .runCount: 6 }
        }

        private func group(_ menu: NSMenu, _ title: String, _ items: [String], selected: Int, cmd: String,
                           keys: [String] = [], keyMask: NSEvent.ModifierFlags = []) {
            let sub = NSMenu()
            for (i, t) in items.enumerated() {
                let it = NSMenuItem(title: t, action: #selector(pick(_:)),
                                    keyEquivalent: i < keys.count ? keys[i] : "")
                if i < keys.count { it.keyEquivalentModifierMask = keyMask }
                it.target = self; it.representedObject = "\(cmd):\(i)"
                it.state = (i == selected) ? .on : .off
                sub.addItem(it)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        private func check(_ menu: NSMenu, _ title: String, _ on: Bool, cmd: String,
                           key: String = "", mask: NSEvent.ModifierFlags = []) {
            let it = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: key)
            it.keyEquivalentModifierMask = mask   // displayed natively (e.g. ⌃U) at the right edge
            it.target = self; it.representedObject = "\(cmd):0"; it.state = on ? .on : .off
            menu.addItem(it)
        }
        private func item(_ menu: NSMenu, _ title: String, cmd: String) {
            let it = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = "\(cmd):0"
            menu.addItem(it)
        }

        @objc private func pick(_ sender: NSMenuItem) {
            guard let repr = sender.representedObject as? String else { return }
            let parts = repr.split(separator: ":"); let cmd = String(parts[0])
            let i = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            // Assign only on change — the search-trigger pipeline has no removeDuplicates,
            // so re-selecting the current value would needlessly reset scroll/selection.
            switch cmd {
            case "layout":  if model.layout != UILayout.allCases[i] { model.layout = UILayout.allCases[i] }
            case "sort":    let k: SortKey = [.name, .path, .size, .dateModified, .dateCreated, .relevance, .runCount][i]
                            if model.sortKey != k {
                                model.sortKey = k
                                if k == .runCount || k == .relevance || k == .size
                                    || k == .dateModified || k == .dateCreated { model.ascending = false }
                            }
            case "appear":  model.appearance = Appearance.allCases[i]
            case "density": model.density = RowDensity.allCases[i]
            case "thumb":   model.thumbSize = [112, 144, 192][i]
            case "asc":     model.ascending.toggle()
            case "ff":      model.foldersFirst.toggle()
            case "hidden":  model.showHidden.toggle()
            case "iconprev": model.iconPreview.toggle()
            case "cloud":   model.setIncludeCloud(!model.includeCloud)
            case "reindex": model.reindex()
            case "fda":     model.showOnboarding = true
            case "copypaths":
                let s = model.allResultPaths()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            case "export":  exportCSV()
            case "update":  AppDelegate.shared?.updaterController.checkForUpdates(nil)
            case "settings": model.requestOpenSettings()
            case "quit":    NSApp.terminate(nil)   // willTerminate saves the snapshot once
            default: break
            }
        }
    }
}

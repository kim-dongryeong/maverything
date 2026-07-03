import AppKit
import Carbon.HIToolbox
import MaverythingCore
import SwiftUI

@main
struct MaverythingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Maverything", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 420)
                .background(WindowConfigurator())
                .onAppear {
                    delegate.model = model
                    model.start()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 620)
        .commands {
            SearchCommands(model: model)   // Everything's Search menu (⌃U/⌃I/⌃B/⌃R live here)
            ViewCommands(model: model)     // layouts ⌘1/2/3 in the View menu
            CommandGroup(replacing: .help) {
                Button("Search Syntax") { model.showSyntax = true }
                    .keyboardShortcut("/")
                Button("Keyboard Shortcuts") { model.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }

        MenuBarExtra("Maverything", systemImage: "magnifyingglass.circle") {
            Button("Show Maverything") { delegate.summon() }
            Button("Reindex Now") { model.reindex() }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit Maverything") { NSApp.terminate(nil) }   // willTerminate saves the snapshot once
        }
    }
}

/// The menu-bar "Search" menu — the canonical macOS home for these shortcuts
/// (mirrors Windows Everything's Search menu, same key set).
struct SearchCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Search") {
            Button("Focus Search Field") { model.focusNonce &+= 1 }
                .keyboardShortcut("f")                                    // ⌘F, the standard "find"
            Divider()
            Toggle("Match Path", isOn: Binding(
                get: { model.scope == .fullPath },
                set: { model.scope = $0 ? .fullPath : .nameOnly }))
                .keyboardShortcut("u", modifiers: .control)
            Toggle("Match Case", isOn: $model.matchCase)
                .keyboardShortcut("i", modifiers: .control)
            Toggle("Match Whole Word", isOn: $model.wholeWord)
                .keyboardShortcut("b", modifiers: .control)
            Divider()
            // Mode shortcuts: each is a to-mode/back toggle (Everything's ⌃R
            // regex semantics, extended to the whole trio) + a ⌃M cycler.
            Toggle("Exact Match", isOn: Binding(
                get: { model.matchMode == .exact },
                set: { _ in model.matchMode = .exact }))
                .keyboardShortcut("e", modifiers: .control)
            Toggle("Fuzzy Match", isOn: Binding(
                get: { model.matchMode == .fuzzy },
                set: { model.matchMode = $0 ? .fuzzy : .exact }))
                .keyboardShortcut("f", modifiers: .control)
            Toggle("Enable Regex", isOn: Binding(
                get: { model.matchMode == .regex },
                set: { model.matchMode = $0 ? .regex : .exact }))
                .keyboardShortcut("r", modifiers: .control)
            Button("Cycle Match Mode") { model.cycleMatchMode() }
                .keyboardShortcut("m", modifiers: .control)
            Divider()
            Button("Reindex Now") { model.reindex() }
                .keyboardShortcut("r", modifiers: [.command, .option])   // ⌥⌘R — frees ⌘R for Reveal in Finder
            Divider()
            Button("Search Syntax") { model.showSyntax = true }
                .keyboardShortcut("/")                                    // ⌘/
            Button("Keyboard Shortcuts") { model.showShortcuts = true }
                .keyboardShortcut("/", modifiers: [.command, .option])    // ⌥⌘/ — ⇧⌘/ is macOS's Help-search
        }
    }
}

/// Layout switching as real View-menu items (⌘1/2/3), with checkmarks.
struct ViewCommands: Commands {
    @ObservedObject var model: AppModel

    private func layoutToggle(_ l: UILayout) -> Binding<Bool> {
        Binding(get: { model.layout == l }, set: { if $0 { model.layout = l } })
    }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Toggle("Table", isOn: layoutToggle(.table)).keyboardShortcut("1")
            Toggle("Compact Bar", isOn: layoutToggle(.compact)).keyboardShortcut("2")
            Toggle("Two-Pane Preview", isOn: layoutToggle(.twoPane)).keyboardShortcut("3")
            Divider()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        HotkeyController.shared.onTrigger = { [weak self] in self?.toggle() }
        HotkeyController.shared.reregister()   // user-configurable global hotkey (default ⌥Space)
        // Re-register on activation so granting Accessibility upgrades us to the
        // event-tap mechanism (any-combo, e.g. ⇧Space) without a relaunch.
        NotificationCenter.default.addObserver(
            self, selector: #selector(onActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func onActive() {
        if Accessibility.isTrusted, !HotkeyController.shared.usingEventTap {
            HotkeyController.shared.reregister()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        summon(); return true
    }

    func summon() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow ?? NSApp.windows.first {
            w.makeKeyAndOrderFront(nil)        // keep the user's position; no re-center
        }
        model?.focusNonce &+= 1
    }

    private func toggle() {
        if let w = mainWindow, w.isVisible, w.isKeyWindow {
            w.orderOut(nil)
        } else {
            summon()
        }
    }
}

/// Grabs the hosting NSWindow once it exists and gives it the floating,
/// title-less quick-search look — done here (not by creating a window manually)
/// so SwiftUI owns realization and there's no launch-time deadlock.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            (NSApp.delegate as? AppDelegate)?.mainWindow = window
            window.level = .normal               // not always-on-top
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isHidden = false
            // (SwiftUI's Window(id:) scene already persists frame; a manual
            // setFrameAutosaveName would fight it, so we don't set one.)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

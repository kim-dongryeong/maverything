import AppKit
import Carbon.HIToolbox
import MaverythingCore
import ServiceManagement
import Sparkle
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
                .onAppear {
                    delegate.model = model
                    model.requestHide = { [weak delegate] in delegate?.hideMainWindow() }
                    model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)   // no native title bar → content goes edge-to-edge, so the
                                        // emerald title-bar strip reaches up behind the traffic lights
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 620)
        .commands {
            NewSearchWindowCommand()       // File ▸ New Search Window (⌘N)
            SearchCommands(primary: model) // Everything's Search menu (⌃U/⌃I/⌃B/⌃R live here)
            ViewCommands(primary: model)   // layouts ⌘1/2/3 in the View menu
            HelpCommands(primary: model)
        }

        // Everything-style "New Search Window" (⌘N): every window shares the ONE index +
        // engine (no second crawl, no extra RAM for the index) but owns its own query,
        // results, sort, chips, and layout — a per-window AppModel attached to the primary.
        WindowGroup(id: "search") {
            SecondarySearchWindow(primary: model)
                .frame(minWidth: 720, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 620)

        Settings {
            SettingsView().environmentObject(model)
        }

        // No MenuBarExtra: the app is summoned by the global hotkey (⌥Space) or by
        // launching it again (Spotlight/Finder → applicationShouldHandleReopen). While
        // hidden it drops to the accessory activation policy — gone from the Dock and
        // ⌘Tab, "feels quit", yet stays resident so the index keeps updating live.
        // Check-for-Updates and Quit moved into the gear (Options) menu.
    }
}

/// Holds a "New Search Window"'s AppModel and builds it EXACTLY ONCE per window.
///
/// Why this indirection: `MaverythingApp.body` re-evaluates on every primary @Published
/// change (searches landing, live-refresh index growth, status text) — several times a
/// second while the app is busy. That re-runs the `WindowGroup(id:"search")` content
/// closure, which re-runs `SecondarySearchWindow.init`. If the per-window AppModel were
/// built in a `StateObject(wrappedValue: AppModel(attachedTo:))` autoclosure, a fresh
/// (throwaway) AppModel — with its whole Combine pipeline + notification observers — would
/// be constructed on EVERY one of those re-evaluations (measured: ~15 builds over 6s per
/// window). This host's own autoclosure is trivial, and the real AppModel is created lazily
/// once and cached, so the storm collapses to a single build.
@MainActor private final class SecondaryModelHost: ObservableObject {
    private var model: AppModel?
    func model(attachedTo primary: AppModel) -> AppModel {
        if let model { return model }
        let m = AppModel(attachedTo: primary)
        model = m
        return m
    }
}

/// Root of a "New Search Window": a per-window AppModel attached to the primary
/// (shared index/engine, independent view state), built once via `SecondaryModelHost`.
private struct SecondarySearchWindow: View {
    private let primary: AppModel
    @StateObject private var host = SecondaryModelHost()

    init(primary: AppModel) {
        self.primary = primary
    }

    var body: some View {
        let model = host.model(attachedTo: primary)
        ContentView()
            .environmentObject(model)
            .onAppear {
                primary.start()   // idempotent — covers state restoration reopening only this window
                model.start()
            }
    }
}

/// File ▸ New Search Window (⌘N) — replaces the default New item.
struct NewSearchWindowCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Search Window") { openWindow(id: "search") }
                .keyboardShortcut("n")
        }
    }
}

/// The menu-bar "Search" menu — the canonical macOS home for these shortcuts
/// (mirrors Windows Everything's Search menu, same key set).
/// Multi-window: commands target the KEY window's model (published by each ContentView
/// via .focusedSceneObject), falling back to the primary when no search window is key.
struct SearchCommands: Commands {
    @FocusedObject private var focused: AppModel?
    @ObservedObject var primary: AppModel
    private var model: AppModel { focused ?? primary }

    var body: some Commands {
        CommandMenu("Search") {
            Button("Focus Search Field") { model.focusNonce &+= 1 }      // '/' or Tab from the results
            Button("Advanced Search…") { model.showAdvancedSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])     // ⇧⌘F — form builds the query
            Divider()
            Toggle("Match Path", isOn: Binding(
                get: { model.scope == .fullPath },
                set: { model.scope = $0 ? .fullPath : .nameOnly }))
                .keyboardShortcut("u", modifiers: .control)
            Toggle("Match Case", isOn: Binding(
                get: { model.matchCase }, set: { model.matchCase = $0 }))
                .keyboardShortcut("i", modifiers: .control)
            Toggle("Match Whole Word", isOn: Binding(
                get: { model.wholeWord }, set: { model.wholeWord = $0 }))
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
                .keyboardShortcut("/", modifiers: .control)               // ⌃/ — ⇧⌘/ is macOS's Help-search
        }
    }
}

/// Layout switching as real View-menu items (⌘1/2/3), with checkmarks.
/// Targets the key window's model (multi-window), falling back to the primary.
struct ViewCommands: Commands {
    @FocusedObject private var focused: AppModel?
    @ObservedObject var primary: AppModel
    private var model: AppModel { focused ?? primary }

    private func layoutToggle(_ l: UILayout) -> Binding<Bool> {
        Binding(get: { model.layout == l }, set: { if $0 { model.layout = l } })
    }

    /// Finder's Sort-By semantics on re-select: choosing the ACTIVE key flips
    /// the direction instead (same muscle memory as clicking a table header).
    private func sortToggle(_ k: SortKey) -> Binding<Bool> {
        Binding(get: { model.sortKey == k },
                set: { _ in
                    if model.sortKey == k { model.ascending.toggle() }
                    else {
                        model.sortKey = k
                        // "best first" computed sorts default to descending (most-run /
                        // highest-relevance / biggest / newest at the top).
                        if k == .runCount || k == .relevance || k == .size
                            || k == .dateModified || k == .dateCreated {
                            model.ascending = false
                        }
                    }
                })
    }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Toggle("Table", isOn: layoutToggle(.table)).keyboardShortcut("1")
            Toggle("Compact Bar", isOn: layoutToggle(.compact)).keyboardShortcut("2")
            Toggle("Two-Pane Preview", isOn: layoutToggle(.twoPane)).keyboardShortcut("3")
            Toggle("Icon Grid", isOn: layoutToggle(.grid)).keyboardShortcut("4")
            Divider()
            // Sort By — ⌃n, matching Everything's Ctrl+n exactly
            Toggle("Sort by Name", isOn: sortToggle(.name))
                .keyboardShortcut("1", modifiers: .control)
            Toggle("Sort by Path", isOn: sortToggle(.path))
                .keyboardShortcut("2", modifiers: .control)
            Toggle("Sort by Size", isOn: sortToggle(.size))
                .keyboardShortcut("3", modifiers: .control)
            Toggle("Sort by Date Modified", isOn: sortToggle(.dateModified))
                .keyboardShortcut("4", modifiers: .control)
            Toggle("Sort by Date Created", isOn: sortToggle(.dateCreated))
                .keyboardShortcut("5", modifiers: .control)
            Toggle("Sort by Relevance", isOn: sortToggle(.relevance))
                .keyboardShortcut("6", modifiers: .control)
            Toggle("Sort by Run Count", isOn: sortToggle(.runCount))
                .keyboardShortcut("7", modifiers: .control)
            Toggle("Ascending", isOn: Binding(
                get: { model.ascending }, set: { model.ascending = $0 }))
                .keyboardShortcut("0", modifiers: .control)
            Divider()
        }
    }
}

/// Help-menu items routed to the key window's model (syntax sheet opens in THAT window).
struct HelpCommands: Commands {
    @FocusedObject private var focused: AppModel?
    @ObservedObject var primary: AppModel
    private var model: AppModel { focused ?? primary }

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Check for Updates…") {
                AppDelegate.shared?.updaterController.checkForUpdates(nil)
            }
            Divider()
            Button("Search Syntax") { model.showSyntax = true }
                .keyboardShortcut("/")
            Button("Keyboard Shortcuts") { model.showShortcuts = true }
                .keyboardShortcut("/", modifiers: .control)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The adaptor-created instance. ⚠️ Never reach it via `NSApp.delegate as? AppDelegate`:
    /// @NSApplicationDelegateAdaptor can install SwiftUI's own wrapper as NSApp.delegate,
    /// making that cast silently nil (bit us: adoptMainWindow never ran, mainWindow stayed
    /// nil, and every caller limped along on keyWindow fallbacks).
    static private(set) weak var shared: AppDelegate?
    weak var model: AppModel?
    weak var mainWindow: NSWindow?
    let updaterController: SPUStandardUpdaterController
    /// True when THIS launch came from the login item (Settings ▸ Start at login):
    /// the app then starts silently — accessory policy, main window ordered out on
    /// attach — and just keeps the index warm until the hotkey summons it.
    private(set) var launchedAtLogin = false
    private var startHiddenPending = false

    override init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A login-item launch carries the launched-as-login-item Apple event — the
        // only supported way to tell "user opened me" from "launchd opened me at login".
        let ev = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = ev?.eventID == kAEOpenApplication
            && ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        startHiddenPending = launchedAtLogin
        NSApp.setActivationPolicy(launchedAtLogin ? .accessory : .regular)

        // Default "Start at login" ON — a real-time index is only useful if the app is
        // actually running to keep it warm, so we opt in on the FIRST launch from
        // /Applications. Done exactly once: if the user later turns it off in Settings the
        // flag stays set and we never re-enable it (never fight the user). Gated on
        // /Applications so a translocated/Downloads first-run doesn't register a bad path;
        // the flag is only recorded once we're properly installed. macOS shows its own
        // "added a login item" notice, so this is transparent, not silent.
        let defs = UserDefaults.standard
        if !defs.bool(forKey: "didInitialLoginItemSetup"),
           Bundle.main.bundlePath.hasPrefix("/Applications/") {
            defs.set(true, forKey: "didInitialLoginItemSetup")
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        }

        HotkeyController.shared.onTrigger = { [weak self] in self?.toggle() }
        HotkeyController.shared.reregister()   // user-configurable global hotkey (default ⌥Space)
        // Re-register on activation so granting Accessibility upgrades us to the
        // event-tap mechanism (any-combo, e.g. ⇧Space) without a relaunch.
        NotificationCenter.default.addObserver(
            self, selector: #selector(onActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // Any window closing (e.g. ESC closing a ⌘N window while the main one is already
        // hidden) may leave nothing on screen → drop out of the Dock/⌘Tab then too.
        NotificationCenter.default.addObserver(
            self, selector: #selector(someWindowWillClose),
            name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func onActive() {
        if Accessibility.isTrusted, !HotkeyController.shared.usingEventTap {
            HotkeyController.shared.reregister()
        }
    }

    @objc private func someWindowWillClose() {
        // willClose fires while the window still counts as visible — re-check next tick.
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        summon(); return true
    }

    /// Called by AppModel.attachWindow when the PRIMARY window lands. For a login-item
    /// launch this is where the silent start is enforced: SwiftUI has just created the
    /// window, so order it right back out before the user ever sees it.
    func adoptMainWindow(_ w: NSWindow) {
        Diag.log("adoptMainWindow: #\(w.windowNumber) startHidden=\(startHiddenPending)")
        mainWindow = w
        if startHiddenPending {
            startHiddenPending = false
            w.orderOut(nil)
        }
    }

    /// Everything semantics: ESC hides the window (⌘W-style); reopen via the Dock/
    /// Spotlight (ShouldHandleReopen) or the global hotkey. Once nothing is on screen
    /// the app also leaves the Dock and ⌘Tab (accessory) — "feels quit", stays indexing.
    func hideMainWindow() {
        let w = mainWindow ?? NSApp.keyWindow
        // A window with an attached sheet (onboarding, Sparkle's update prompt) silently
        // REFUSES orderOut — dismiss sheets first. SwiftUI sheets are state-driven, so
        // e.g. onboarding simply re-presents when the window next shows.
        if let w { for s in w.sheets { w.endSheet(s) } }
        w?.orderOut(nil)
        if model?.clearSearchOnClose == true { model?.query = "" }   // Everything's option
        updateActivationPolicy()
    }

    /// Accessory (no Dock icon, no ⌘Tab entry) whenever NO window is visible; regular
    /// as soon as anything shows. The index/watcher never notice — they run either way.
    func updateActivationPolicy() {
        let anyVisible = NSApp.windows.contains { $0.isVisible }
        let want: NSApplication.ActivationPolicy = anyVisible ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    func summon() {
        NSApp.setActivationPolicy(.regular)    // back into the Dock + ⌘Tab before showing
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow ?? NSApp.windows.first {
            w.makeKeyAndOrderFront(nil)        // keep the user's position; no re-center
        }
        model?.focusNonce &+= 1
    }

    private func toggle() {
        if let w = mainWindow, w.isVisible, w.isKeyWindow {
            hideMainWindow()                   // same path as ESC → also leaves Dock/⌘Tab
        } else {
            summon()
        }
    }
}


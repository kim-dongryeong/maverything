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
            CommandGroup(replacing: .appInfo) {
                Button("Reindex Now") { model.reindex() }.keyboardShortcut("r", modifiers: .command)
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
            window.setFrameAutosaveName("MaverythingMainWindow")   // remember size & position
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

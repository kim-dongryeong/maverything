import AppKit
import Carbon.HIToolbox
import MaverythingCore
import SwiftUI

/// Persisted global-hotkey configuration (Carbon virtual keycode + Carbon modifier
/// mask + a human display string). Default: ⌥Space.
struct HotkeyConfig: Equatable {
    var keyCode: UInt32
    var carbonMods: UInt32
    var display: String

    static let `default` = HotkeyConfig(keyCode: UInt32(kVK_Space),
                                        carbonMods: UInt32(optionKey), display: "⌥Space")

    static var current: HotkeyConfig {
        let d = UserDefaults.standard
        guard d.object(forKey: "mv.hotkey.keyCode") != nil else { return .default }
        return HotkeyConfig(keyCode: UInt32(d.integer(forKey: "mv.hotkey.keyCode")),
                            carbonMods: UInt32(d.integer(forKey: "mv.hotkey.mods")),
                            display: d.string(forKey: "mv.hotkey.display") ?? "⌥Space")
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "mv.hotkey.keyCode")
        d.set(Int(carbonMods), forKey: "mv.hotkey.mods")
        d.set(display, forKey: "mv.hotkey.display")
    }

    static func carbonMods(from f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option)  { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    static func display(for event: NSEvent) -> String {
        var s = ""
        let f = event.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        switch Int(event.keyCode) {
        case kVK_Space: s += "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: s += "↩"
        case kVK_Tab: s += "⇥"
        case kVK_Escape: s += "⎋"
        case kVK_LeftArrow: s += "←"; case kVK_RightArrow: s += "→"
        case kVK_DownArrow: s += "↓"; case kVK_UpArrow: s += "↑"
        default: s += (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        return s
    }
}

/// A click-to-record shortcut field (AppKit, so it captures raw key events).
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var display: String
    var onCapture: (HotkeyConfig) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.display = display
        v.onCapture = { cfg in display = cfg.display; onCapture(cfg) }
        return v
    }
    func updateNSView(_ v: RecorderView, context: Context) { v.display = display; v.needsDisplay = true }

    final class RecorderView: NSView {
        var display = "⌥Space"
        var onCapture: ((HotkeyConfig) -> Void)?
        private var recording = false

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 26) }

        override func mouseDown(with event: NSEvent) {
            recording = true; window?.makeFirstResponder(self); needsDisplay = true
        }
        override func resignFirstResponder() -> Bool { recording = false; needsDisplay = true; return true }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == UInt32(kVK_Escape) {   // cancel
                recording = false; needsDisplay = true; return
            }
            let mods = HotkeyConfig.carbonMods(from: event.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return }   // require ≥1 modifier
            let cfg = HotkeyConfig(keyCode: UInt32(event.keyCode), carbonMods: mods,
                                   display: HotkeyConfig.display(for: event))
            display = cfg.display
            recording = false
            onCapture?(cfg)
            window?.makeFirstResponder(nil)
            needsDisplay = true
        }

        override func draw(_ rect: NSRect) {
            let r = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                       : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = recording ? 2 : 1; path.stroke()
            let text = recording ? "Type a shortcut…" : display
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                                y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var hotkeyDisplay = HotkeyConfig.current.display

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            indexing.tabItem { Label("Indexing", systemImage: "externaldrive") }
        }
        .frame(width: 460, height: 300)
        .environmentObject(model)
    }

    private var general: some View {
        Form {
            LabeledContent("Global hotkey") {
                HStack {
                    HotkeyRecorder(display: $hotkeyDisplay) { cfg in
                        cfg.save()
                        (NSApp.delegate as? AppDelegate)?.reregisterHotKey()
                    }
                    .frame(width: 170, height: 26)
                    Button("Reset") {
                        HotkeyConfig.default.save()
                        hotkeyDisplay = HotkeyConfig.default.display
                        (NSApp.delegate as? AppDelegate)?.reregisterHotKey()
                    }
                }
            }
            Text("Click the field, then press the key combination to summon Maverything from anywhere.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Match mode", selection: $model.matchMode) {
                ForEach(MatchMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Layout", selection: $model.layout) {
                ForEach(UILayout.allCases) { Text($0.label).tag($0) }
            }
            Picker("Appearance", selection: $model.appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            Picker("Row density", selection: $model.density) {
                ForEach(RowDensity.allCases) { Text($0.label).tag($0) }
            }
        }
        .padding(20)
    }

    private var indexing: some View {
        Form {
            Toggle("Include cloud storage (Google Drive, iCloud…)", isOn: Binding(
                get: { model.includeCloud }, set: { model.setIncludeCloud($0) }))
            LabeledContent("Indexed items", value: model.indexedCount.formatted())
            LabeledContent("Full Disk Access", value: model.hasFullDiskAccess ? "Granted ✓" : "Not granted")
            if !model.hasFullDiskAccess {
                Button("Grant Full Disk Access…") { model.showOnboarding = true }
            }
            Divider()
            Button("Reindex Now") { model.reindex() }
        }
        .padding(20)
    }
}

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

    var cocoaFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonMods & UInt32(cmdKey) != 0 { f.insert(.command) }
        if carbonMods & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonMods & UInt32(controlKey) != 0 { f.insert(.control) }
        if carbonMods & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
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
        return s + keyLabel(Int(event.keyCode))
    }

    /// Layout-INDEPENDENT label for a virtual keycode, so ⌥O reads "⌥O" even when
    /// the current input source is Korean (charactersIgnoringModifiers would give ㅐ).
    static func keyLabel(_ kc: Int) -> String {
        switch kc {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"; case kVK_UpArrow: return "↑"
        case kVK_Home: return "↖"; case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"; case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"; case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["; case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"; case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"; case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."; case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        default: return "key\(kc)"
        }
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
            recording = true
            HotkeyController.shared.suspend()   // so pressing the CURRENT combo records, not triggers
            window?.makeFirstResponder(self); needsDisplay = true
        }
        override func resignFirstResponder() -> Bool {
            if recording { recording = false; HotkeyController.shared.reregister() }  // canceled by click-away
            needsDisplay = true; return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == UInt32(kVK_Escape) {   // cancel
                recording = false; HotkeyController.shared.reregister()
                window?.makeFirstResponder(nil); needsDisplay = true; return
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
        .onExitCommand {   // ESC closes Settings (macOS default is ⌘W only)
            NSApp.keyWindow?.performClose(nil)
        }
        .frame(width: 500, height: 480)
        .environmentObject(model)
    }

    private var general: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Global hotkey") {
                    HStack {
                        HotkeyRecorder(display: $hotkeyDisplay) { cfg in
                            let previous = HotkeyConfig.current
                            cfg.save()
                            Diag.log("recorder captured \(cfg.display) (keyCode=\(cfg.keyCode) mods=\(cfg.carbonMods))")
                            let ok = HotkeyController.shared.reregister()
                            if !ok {                       // OS refused the combo → restore + tell the user
                                previous.save()
                                hotkeyDisplay = previous.display
                                _ = HotkeyController.shared.reregister()   // put the working one back
                                let a = NSAlert()
                                a.messageText = "Couldn't set “\(cfg.display)”"
                                a.informativeText = "That shortcut is reserved or already in use. Try another — combos with ⌘, ⌥, or ⌃ work best."
                                a.runModal()
                            }
                        }
                        .frame(width: 170, height: 26)
                        Button("Reset") {
                            HotkeyConfig.default.save()
                            hotkeyDisplay = HotkeyConfig.default.display
                            HotkeyController.shared.reregister()
                        }
                    }
                }
                Text("Click the field, then press the key combination to summon Maverything from anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Any-combo hotkeys") {
                    if Accessibility.isTrusted {
                        Label("Enabled (Accessibility)", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    } else {
                        Button("Enable…") {
                            Accessibility.requestTrust()
                            Accessibility.openSettings()
                        }
                    }
                }
                Text("Enable to use shortcuts other apps also grab — like ⇧Space, ⌃Space (works like BetterTouchTool/Karabiner). Without it, prefer a ⌘/⌥/⌃ combo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Search & Appearance") {
                Picker("Match mode", selection: $model.matchMode) {
                    ForEach(MatchMode.uiModes, id: \.self) { Text($0.label).tag($0) }
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
                Picker("Title bar accent", selection: $model.titleBarTint) {
                    ForEach(TitleBarTintStyle.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("Run history")
                    Spacer()
                    Button("Clear Run History") { model.clearRunHistory() }
                }
                Text("Sort by Run Count (⌃7) floats files you open most/recently to the top; Relevance also uses it. This clears those counts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                Toggle("Enter key renames (instead of opens)", isOn: $model.enterRenames)
                Toggle("Clear search when window closes (ESC)", isOn: $model.clearSearchOnClose)
                Toggle("Page Up/Down · Home/End move the selection", isOn: $model.navKeysMoveSelection)
                Text("On (Everything-style): the cursor jumps by a page / to the first-last row. Off: macOS default — only the scroll moves.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("F2 always renames. Space = Quick Look · ⌘⌫ = Move to Trash · drag rows to Finder to copy/move.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var indexing: some View {
        Form {
            Section("Index") {
                Toggle("Include cloud storage (Google Drive, iCloud…)", isOn: Binding(
                    get: { model.includeCloud }, set: { model.setIncludeCloud($0) }))
                Toggle("Show & sort real folder sizes", isOn: $model.indexFolderSizes)
                Text("Folders sort and display by their total contents (Everything 1.5's folder-size indexing). Off = folders show -- and sort as 0.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Indexed items") {
                    Text(model.indexedCount.formatted()).monospacedDigit()
                }
                LabeledContent("Full Disk Access", value: model.hasFullDiskAccess ? "Granted ✓" : "Not granted")
                if !model.hasFullDiskAccess {
                    Button("Grant Full Disk Access…") { model.showOnboarding = true }
                }
            }

            // Everything's "folder indexing" — for locations the local-volume scan
            // doesn't reach (above all network shares / NAS mounts).
            Section("Extra index folders") {
                pathList(model.customRoots, remove: { model.removeCustomRoot($0) })
                Button("Add Folder…") { pickFolder { model.addCustomRoot($0) } }
                Text("Local volumes are indexed automatically — add network shares (NAS/SMB) or other locations the scan doesn't cover. Live updates on network volumes are best-effort; use Reindex to refresh.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Rescan network folders", selection: $model.customRootRescanMinutes) {
                    Text("Off").tag(0)
                    Text("Every 15 min").tag(15)
                    Text("Hourly").tag(60)
                    Text("Every 6 hours").tag(360)
                    Text("Daily").tag(1440)
                }
                Text("Network shares don't deliver reliable file events — periodic rescans keep them fresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Excluded folders") {
                pathList(model.customExcludes, remove: { model.removeCustomExclude($0) })
                Button("Add Exclusion…") { pickFolder { model.addCustomExclude($0) } }
                HStack {
                    TextField("Exclude files (patterns): *.tmp;*.log;.DS_Store",
                              text: $model.excludeFilePatterns)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.applyExcludeFilePatterns() }
                    Button("Apply") { model.applyExcludeFilePatterns() }
                }
                Text("Semicolon-separated name globs (* and ?), matched case-insensitively. Applying reindexes.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Include only files (whitelist): *.mp3;*.flac — empty = everything",
                              text: $model.includeOnlyFilePatterns)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.applyExcludeFilePatterns() }
                    Button("Apply") { model.applyExcludeFilePatterns() }
                }
                Text("When set, ONLY files matching these globs are indexed (folders are kept). Everything's 'Include only files'.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Excluded folders are removed from the index immediately; removing an exclusion triggers a reindex.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Reindex Now") { model.reindex() }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func pathList(_ paths: [String], remove: @escaping (String) -> Void) -> some View {
        if paths.isEmpty {
            Text("None").font(.caption).foregroundStyle(.tertiary)
        } else {
            ForEach(paths, id: \.self) { p in
                HStack {
                    Text(p).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        remove(p)
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }
        }
    }

    private func pickFolder(_ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { done(url.path) }
    }
}

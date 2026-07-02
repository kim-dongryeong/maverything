import AppKit

/// Owns the global hotkey registration in one place (a singleton), so both the
/// AppDelegate (launch / activation) and the Settings recorder can (re)register
/// reliably — no fragile `NSApp.delegate as? AppDelegate` casts.
@MainActor
final class HotkeyController {
    static let shared = HotkeyController()
    private init() {}

    /// Set by the AppDelegate; invoked when the hotkey fires.
    var onTrigger: () -> Void = {}

    private var hotKey: HotKey?
    private var tapHotKey: EventTapHotKey?

    /// (Re)register from the persisted config. Prefers a CGEventTap when
    /// Accessibility is granted (any combo, incl. ⇧Space); otherwise Carbon.
    /// Returns false only if EVERYTHING failed (then default ⌥Space is restored).
    @discardableResult
    func reregister() -> Bool {
        hotKey = nil; tapHotKey = nil
        let cfg = HotkeyConfig.current
        let act: () -> Void = { [weak self] in self?.onTrigger() }
        let trusted = Accessibility.isTrusted
        Diag.log("HotkeyController.reregister: \(cfg.display) keyCode=\(cfg.keyCode) mods=\(cfg.carbonMods) AXtrusted=\(trusted)")
        if trusted, let t = EventTapHotKey(keyCode: cfg.keyCode, mods: cfg.cocoaFlags, action: act) {
            tapHotKey = t; Diag.log("  -> event tap OK"); return true
        }
        if trusted { Diag.log("  -> event tap FAILED, trying Carbon") }
        if let hk = HotKey(keyCode: cfg.keyCode, modifiers: cfg.carbonMods, action: act) {
            hotKey = hk; Diag.log("  -> Carbon OK"); return true
        }
        Diag.log("  -> Carbon FAILED; keeping a working default ⌥Space at runtime")
        let d = HotkeyConfig.default   // runtime fallback only; caller reverts the saved config
        hotKey = HotKey(keyCode: d.keyCode, modifiers: d.carbonMods, action: act)
        return false
    }

    var usingEventTap: Bool { tapHotKey != nil }
}

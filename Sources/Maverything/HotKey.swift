import AppKit
import Carbon.HIToolbox

/// A global hotkey via Carbon `RegisterEventHotKey` (no Accessibility permission).
/// The Carbon event handler is installed ONCE for the process; each HotKey just
/// registers/unregisters its EventHotKeyRef and routes through `active`.
final class HotKey {
    private var ref: EventHotKeyRef?
    fileprivate let action: () -> Void

    private static var handlerInstalled = false
    fileprivate static weak var active: HotKey?

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            HotKey.active?.action()   // only one hotkey is registered at a time
            return noErr
        }, 1, &spec, nil, nil)
    }

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        HotKey.installHandlerOnce()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D56_4B59), id: 1)   // 'MVKY'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            Diag.log("HotKey RegisterEventHotKey failed: status=\(status) keyCode=\(keyCode) mods=\(modifiers)")
            return nil
        }
        HotKey.active = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if HotKey.active === self { HotKey.active = nil }
    }
}

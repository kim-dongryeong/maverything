import AppKit
import ApplicationServices

/// A global hotkey via a CGEventTap (the mechanism BetterTouchTool uses). Unlike
/// Carbon RegisterEventHotKey, this sees the RAW key stream and CONSUMES the match,
/// so combos other processes also grab (⇧Space, ⌃Space, …) fire reliably. Needs
/// Accessibility permission (AXIsProcessTrusted).
final class EventTapHotKey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate let keyCode: CGKeyCode
    fileprivate let mods: NSEvent.ModifierFlags
    fileprivate let action: () -> Void

    init?(keyCode: UInt32, mods: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        self.keyCode = CGKeyCode(keyCode)
        self.mods = mods.intersection([.command, .option, .control, .shift])
        self.action = action

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EventTapHotKey>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type, event)
            }, userInfo: info)
        else { return nil }   // tap creation fails without Accessibility permission

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return Unmanaged.passUnretained(event)   // don't fire on held-key auto-repeat
            }
            let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if kc == keyCode {
                var f: NSEvent.ModifierFlags = []
                let cg = event.flags
                if cg.contains(.maskCommand)   { f.insert(.command) }
                if cg.contains(.maskAlternate) { f.insert(.option) }
                if cg.contains(.maskControl)   { f.insert(.control) }
                if cg.contains(.maskShift)     { f.insert(.shift) }
                if f == mods {
                    DispatchQueue.main.async { self.action() }
                    return nil   // consume so the key doesn't also type/act elsewhere
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    @discardableResult static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

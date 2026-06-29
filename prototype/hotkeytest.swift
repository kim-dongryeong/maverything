// Does Carbon RegisterEventHotKey accept various Space combos? (0 = noErr = OK)
import Carbon.HIToolbox
import Foundation

func test(_ name: String, _ mods: UInt32) {
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x54455354), id: 1)
    let st = RegisterEventHotKey(UInt32(kVK_Space), mods, id, GetApplicationEventTarget(), 0, &ref)
    print(String(format: "%-22@ status=%d %@", name as NSString, st, st == 0 ? "OK" : "FAIL"))
    if let ref { UnregisterEventHotKey(ref) }
}
test("⇧Space (shift only)", UInt32(shiftKey))
test("⌃Space (control)",    UInt32(controlKey))
test("⌥Space (option)",     UInt32(optionKey))
test("⌘Space (command)",    UInt32(cmdKey))
test("⌘⌥Space",             UInt32(cmdKey | optionKey))
test("⌃⌥Space",             UInt32(controlKey | optionKey))
test("⇧⌥Space",             UInt32(shiftKey | optionKey))

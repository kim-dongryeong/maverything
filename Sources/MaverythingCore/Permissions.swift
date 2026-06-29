import AppKit
import Foundation

/// Full Disk Access detection + onboarding. There is no public API that reports
/// FDA status, so we *probe a protected path*: the per-user TCC database is only
/// readable with Full Disk Access granted.
public enum Permissions {

    /// Returns true if the app appears to have Full Disk Access.
    public static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        // These paths are unreadable (even to open) without FDA.
        let probes = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/CloudTabs.db",
        ]
        for p in probes {
            switch probe(p) {
            case .readable: return true
            case .denied: return false
            case .missing: continue
            }
        }
        return false
    }

    private enum ProbeResult { case readable, denied, missing }

    private static func probe(_ path: String) -> ProbeResult {
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return .readable }
        switch errno {
        case EPERM, EACCES: return .denied
        case ENOENT: return .missing
        default: return .missing
        }
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    public static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

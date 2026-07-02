import Darwin
import Foundation

/// A volume to crawl: the real filesystem path to open vs. the path to *display*.
/// The Data volume is mounted at /System/Volumes/Data but firmlinked into "/",
/// so we open it there but present its files with normal "/Users/…" paths.
public struct CrawlRoot: Sendable, Equatable {
    public let fsPath: String       // where we open() / getattrlistbulk
    public let displayPath: String  // what the user sees (path reconstruction root)
    public init(fsPath: String, displayPath: String) {
        self.fsPath = fsPath; self.displayPath = displayPath
    }
}

public enum Volumes {

    /// Local, physical volumes worth indexing — the macOS analog of "all your
    /// drives". Skips network mounts, devfs/autofs, and tiny system-internal
    /// nobrowse volumes (VM/Preboot/Update/…). Cloud storage is excluded via
    /// `defaultExclusions`, not here (it lives *inside* a local volume).
    public static func localCrawlRoots(includeRemovable: Bool = true) -> [CrawlRoot] {
        var roots: [CrawlRoot] = []
        var seen = Set<String>()

        // The boot volume group: crawl "/" and FOLLOW firmlinks (they are real dirs
        // on the Data volume spliced into "/"), giving the whole /Users…/Applications…
        // namespace exactly once with normal paths. Cross-volume MOUNTS are skipped
        // during this crawl (see Volumes.allMountPoints) and indexed as their own
        // roots below — so nothing is double-counted and the Data volume is never
        // reached via /System/Volumes/Data.
        add(&roots, &seen, CrawlRoot(fsPath: "/", displayPath: "/"))

        for v in mounted() {
            let mp = v.mountPoint
            guard v.isLocal, mp != "/" else { continue }
            if v.fsType == "devfs" || v.fsType == "autofs" || v.fsType == "fdesc" { continue }
            if mp.hasPrefix("/System/Volumes/") { continue }   // Data/VM/Preboot/… (Data via firmlinks)
            add(&roots, &seen, CrawlRoot(fsPath: mp, displayPath: mp))   // /Volumes/*, simulator vols, …
        }
        return roots
    }

    /// Default path prefixes to skip — cloud File Providers (online, slow to
    /// enumerate) and autofs home maps. User-overridable later.
    /// Always-excluded paths, regardless of the cloud toggle (our own snapshot dir
    /// must be skipped or every save triggers an FSEvents→reconcile→resave loop).
    public static func alwaysExclusions() -> [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Application Support/Maverything",  // our snapshot store
            "/System/Volumes/Data/home",                       // autofs automount
        ]
    }

    public static func defaultExclusions() -> [String] {
        let home = NSHomeDirectory()
        return alwaysExclusions() + [
            home + "/Library/CloudStorage",       // Google Drive, OneDrive, Dropbox, Box…
            home + "/Library/Mobile Documents",   // iCloud Drive
        ]
        // Note: /Volumes and cross-volume mounts are handled by the fsid guard,
        // not by path exclusion (so explicit /Volumes/* roots still crawl fully).
    }

    /// All mount points on the system (any fs type). The crawler skips descending
    /// into these (each real volume is crawled as its own root), which prevents
    /// the `/` crawl from re-indexing the Data volume under `/System/Volumes/Data`.
    public static func allMountPoints() -> Set<String> {
        Set(mounted().map { $0.mountPoint })
    }

    // MARK: - getmntinfo

    public struct MountInfo: Sendable {
        public let mountPoint: String
        public let fsType: String
        public let isLocal: Bool
        public let isRemovableOrBrowsable: Bool
    }

    public static func mounted() -> [MountInfo] {
        var mntbuf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&mntbuf, MNT_NOWAIT)
        guard n > 0, let buf = mntbuf else { return [] }
        var out: [MountInfo] = []
        for i in 0..<Int(n) {
            var s = buf[i]
            let mp = withUnsafePointer(to: &s.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let fs = withUnsafePointer(to: &s.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let flags = s.f_flags
            let local = (flags & UInt32(MNT_LOCAL)) != 0
            let dontBrowse = (flags & UInt32(MNT_DONTBROWSE)) != 0
            out.append(MountInfo(mountPoint: mp, fsType: fs, isLocal: local,
                                 isRemovableOrBrowsable: !dontBrowse))
        }
        return out
    }

    private static func add(_ roots: inout [CrawlRoot], _ seen: inout Set<String>, _ r: CrawlRoot) {
        if seen.insert(r.fsPath).inserted { roots.append(r) }
    }
}

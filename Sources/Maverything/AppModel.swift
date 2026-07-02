import AppKit
import Combine
import CoreServices
import Foundation
import MaverythingCore

/// Lightweight file logger so we can verify the in-app engine pipeline headlessly.
enum Diag {
    static let path = NSHomeDirectory() + "/dev/maverything/maverything-diag.log"
    static func log(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Holds the result rows outside of `@Published` so SwiftUI never diffs a
/// 100k-element array. The table reads this directly; `AppModel.resultsVersion`
/// is the cheap signal that tells the table to `reloadData()`.
final class ResultsStore {
    var ids: [Int32] = []
    var index: FileIndex!
}

/// Everything-style quick type filters. Each maps to a query clause that is
/// AND-ed with whatever the user has typed (see `AppModel.effectiveQuery`).
enum TypeFilter: String, CaseIterable, Identifiable {
    case all, folders, documents, images, audio, video, archives, apps
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All";             case .folders: return "Folders"
        case .documents: return "Documents"; case .images: return "Images"
        case .audio: return "Audio";         case .video: return "Video"
        case .archives: return "Archives";   case .apps: return "Apps"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2";  case .folders: return "folder"
        case .documents: return "doc.text";   case .images: return "photo"
        case .audio: return "music.note";     case .video: return "film"
        case .archives: return "archivebox";  case .apps: return "app.badge"
        }
    }

    /// The query fragment this filter contributes (empty for `.all`).
    var clause: String {
        switch self {
        case .all:       return ""
        case .folders:   return "folder:"
        case .documents: return "ext:pdf,doc,docx,txt,rtf,pages,md,markdown,odt,tex,epub,xls,xlsx,csv,ppt,pptx,key,numbers"
        case .images:    return "ext:jpg,jpeg,png,gif,bmp,tiff,tif,heic,heif,webp,svg,raw,cr2,nef,arw,dng,psd,ico"
        case .audio:     return "ext:mp3,wav,flac,aac,m4a,ogg,oga,aiff,aif,wma,alac,opus"
        case .video:     return "ext:mp4,mov,avi,mkv,wmv,flv,webm,m4v,mpg,mpeg,3gp,m2ts,mts"
        case .archives:  return "ext:zip,rar,7z,tar,gz,tgz,bz2,xz,dmg,iso,pkg,cab"
        case .apps:      return "ext:app,pkg,dmg,exe"
        }
    }
}

/// A user-saved search: the query plus the modes it was captured with.
struct SavedSearch: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var query: String
    var matchMode: Int
    var typeFilter: String
    var scope: Int
}

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var statusText = "Starting…"
    @Published var resultTotal = 0
    @Published var indexedCount = 0
    @Published var queryMillis = 0.0
    @Published var resultsVersion = 0
    @Published var queryNonce = 0          // bumps only on a NEW query (not live refresh)
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    @Published var scope: SearchScope = .nameOnly
    @Published var matchMode: MatchMode = .exact
    @Published var typeFilter: TypeFilter = .all   // Everything-style quick type chips
    @Published var recentQueries: [String] = AppModel.loadRecents()
    @Published var savedSearches: [SavedSearch] = AppModel.loadSaved()
    @Published var scopeRoot: String? = nil        // "Search in This Folder" — restrict to a subtree
    @Published var isIndexing = true
    @Published var hasFullDiskAccess = true
    @Published var showOnboarding = false
    @Published var includeCloud = false        // index ~/Library/CloudStorage etc.
    @Published var showHidden = true            // Everything-style: show everything
    @Published var enterRenames: Bool = UserDefaults.standard.bool(forKey: "mv.enterRenames") {
        didSet { UserDefaults.standard.set(enterRenames, forKey: "mv.enterRenames") }
    }
    @Published var focusNonce = 0              // bumped to refocus the search field
    @Published var focusResultsNonce = 0       // bumped to move focus into the results list
    @Published var selectedID: Int32? = nil    // current selection (for the preview pane)
    @Published var selectionCount = 0
    @Published var selectionBytes: Int64 = 0
    @Published var layout: UILayout = UILayout(rawValue:
        UserDefaults.standard.string(forKey: "mv.layout") ?? "") ?? .table {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "mv.layout") }
    }
    @Published var appearance: Appearance = Appearance(rawValue:
        UserDefaults.standard.string(forKey: "mv.appearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "mv.appearance") }
    }
    @Published var density: RowDensity = RowDensity(rawValue:
        UserDefaults.standard.string(forKey: "mv.density") ?? "") ?? .comfortable {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "mv.density") }
    }

    /// Set by the AppDelegate so the search UI can dismiss the panel (ESC).
    var requestHide: (() -> Void)?

    let index = FileIndex()
    lazy var engine = SearchEngine(index: index)
    let resultsStore = ResultsStore()

    private var cancellables = Set<AnyCancellable>()
    private let searchQueue = DispatchQueue(label: "maverything.search", qos: .userInteractive)
    private let indexQueue = DispatchQueue(label: "maverything.index", qos: .userInitiated)
    private var searchSeq = 0
    private var started = false
    private var currentEnumerator: FileEnumerator?
    private var indexGen = 0
    private let watcher = FSWatcher()
    private var reconciler: Reconciler?
    private let reconcileQueue = DispatchQueue(label: "maverything.reconcile", qos: .utility)

    init() {
        resultsStore.index = index

        $query
            .debounce(for: .milliseconds(35), scheduler: DispatchQueue.main)  // fires during window tracking too
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                // if the user edited away from a cycled history entry, drop the cursor
                if self.historyCursor >= 0, self.historyCursor < self.recentQueries.count,
                   self.query != self.recentQueries[self.historyCursor] {
                    self.historyCursor = -1
                }
                self.queryNonce &+= 1; self.runSearch()
            }
            .store(in: &cancellables)

        Publishers.Merge6(
            $sortKey.map { _ in () },
            $ascending.map { _ in () },
            $scope.map { _ in () },
            $matchMode.map { _ in () },
            $typeFilter.map { _ in () },
            $scopeRoot.map { _ in () }
        )
        .dropFirst()
        .sink { [weak self] in self?.queryNonce &+= 1; self?.runSearch() }
        .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveSnapshot(sync: true)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    private var progressTimer: Timer?

    /// Path prefixes to skip. Cloud File Providers are excluded unless the user
    /// opts in; the autofs home map is always skipped.
    private func currentExclusions() -> [String] {
        // always skip our own snapshot dir + autofs; cloud only when not opted in
        if includeCloud { return Volumes.alwaysExclusions() }
        return Volumes.defaultExclusions()
    }

    func start() {
        guard !started else { return }
        started = true

        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        showOnboarding = !hasFullDiskAccess
        startPeriodicSave()
        if !loadFromSnapshot() { beginIndexing() }
    }

    /// Fast path: reload the last snapshot (~100 ms) and resume live updates from
    /// the persisted FSEvents id, instead of a full crawl.
    private func loadFromSnapshot() -> Bool {
        let url = Snapshot.defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        isIndexing = true
        statusText = "Loading saved index…"
        let gen = indexGen
        indexQueue.async { [weak self] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: url), let meta = self.index.loadSnapshot(data) else {
                DispatchQueue.main.async { if gen == self.indexGen { self.beginIndexing() } }
                return
            }
            self.index.buildLiveIndexes()
            DispatchQueue.main.async {
                guard gen == self.indexGen else { return }
                self.isIndexing = false
                self.indexedCount = self.index.count
                self.statusText = "Loaded \(self.index.count.formatted()) items · resuming…"
                self.engine.invalidate()
                self.prewarmAndSearch()
                Diag.log("LOADED snapshot \(self.index.count) items, resume@\(meta.lastEventId)")
                self.startWatching(roots: Volumes.localCrawlRoots(),
                                   exclude: self.currentExclusions(),
                                   sinceWhen: meta.lastEventId)
            }
        }
        return true
    }

    /// (Re)start a whole-disk crawl across all local volumes. Safe to call while
    /// a crawl is running: the previous crawl is cancelled and superseded.
    func beginIndexing() {
        indexGen += 1
        let gen = indexGen
        watcher.stop()                  // pause live updates during (re)index
        currentEnumerator?.cancel()     // abort any in-flight crawl fast
        isIndexing = true
        indexedCount = 0
        statusText = "Indexing all local volumes…"

        let roots = Volumes.localCrawlRoots()
        let exclude = currentExclusions()
        Diag.log("crawl[\(gen)] roots: \(roots.map { "\($0.fsPath)→\($0.displayPath)" }.joined(separator: ", "))  FDA=\(hasFullDiskAccess) cloud=\(includeCloud)")

        progressTimer?.invalidate()
        var ticks = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.indexedCount = self.index.safeCount()
            self.statusText = "Indexing… \(self.indexedCount.formatted()) items"
            ticks += 1
            if ticks % 8 == 0 { Diag.log("…progress \(self.indexedCount) items") }
        }

        // Serial queue guarantees the previous crawl's worker threads have fully
        // exited (crawl() joins them) before we clear + start the next one.
        indexQueue.async { [weak self] in
            guard let self else { return }
            let en = FileEnumerator(index: self.index)
            let proceed: Bool = DispatchQueue.main.sync {
                guard gen == self.indexGen else { return false }
                self.index.clear()
                self.index.reserveCapacity(3_000_000)
                self.currentEnumerator = en
                return true
            }
            guard proceed else { return }   // superseded before we started — don't run the crawl
            // Capture the FSEvents cursor BEFORE crawling so changes made during the
            // crawl are replayed once the stream starts (not lost).
            let sinceId = FSEventsGetCurrentEventId()
            let stats = en.crawl(roots: roots, restrictToVolume: false, exclude: exclude,
                                 mountPoints: Volumes.allMountPoints())
            if en.isCancelled { return }                     // superseded; skip extra work
            DispatchQueue.main.async {
                guard gen == self.indexGen else { return }
                self.statusText = "Preparing live updates…"
            }
            self.index.buildLiveIndexes()                    // O(n), enables the reconciler
            DispatchQueue.main.async {
                guard gen == self.indexGen else { return }   // superseded by a newer crawl
                self.currentEnumerator = nil
                self.progressTimer?.invalidate(); self.progressTimer = nil
                self.isIndexing = false
                self.indexedCount = self.index.count
                self.statusText = String(format: "Indexed %@ items in %.1fs",
                                         self.index.count.formatted(), stats.seconds)
                self.engine.invalidate()
                Diag.log("DONE[\(gen)] indexed \(self.index.count) items in \(stats.seconds)s (\(stats.openErrors) open-errors)")
                self.prewarmAndSearch()
                self.startWatching(roots: roots, exclude: exclude, sinceWhen: sinceId)
                self.saveSnapshot()   // so the next launch is instant
            }
        }
    }

    // MARK: - Real-time watching

    private func startWatching(roots: [CrawlRoot], exclude: [String],
                               sinceWhen: UInt64 = UInt64(kFSEventStreamEventIdSinceNow)) {
        let watchPaths = Array(Set(roots.map { $0.displayPath }))
        let rec = Reconciler(index: index, exclude: exclude)
        reconciler = rec
        let q = reconcileQueue
        watcher.start(paths: watchPaths, sinceWhen: sinceWhen) { [weak self] paths, mustScanAll in
            if mustScanAll {
                // FSEvents history gap / dropped events → safest is a full re-crawl.
                DispatchQueue.main.async { self?.beginIndexing() }
                return
            }
            q.async {
                let r = rec.reconcile(eventPaths: paths)
                guard r.didMutate else { return }
                DispatchQueue.main.async { self?.scheduleLiveRefresh() }
            }
        }
        Diag.log("watching: \(watchPaths.joined(separator: ", ")) since=\(sinceWhen)")
    }

    // Coalesce bursts of filesystem changes into one index refresh so we don't
    // rebuild the sort order (and burn a core) on every individual event.
    private var liveRefreshScheduled = false
    private var pendingLiveRefresh = false
    /// Timestamp (monotonic) of the last keyboard navigation in the results list.
    /// A live refresh reloads the table, which would reset scroll/selection under an
    /// actively-held arrow key — so we defer it until the user pauses.
    var lastNavAt: TimeInterval = 0
    private func scheduleLiveRefresh() {
        snapshotDirty = true
        // When the app isn't frontmost, background file churn shouldn't burn a core
        // rebuilding the sort order — defer until the user comes back.
        guard NSApp.isActive else { pendingLiveRefresh = true; return }
        guard !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.liveRefreshScheduled = false
            guard !self.isIndexing else { return }
            // Don't yank the list out from under active keyboard navigation.
            if ProcessInfo.processInfo.systemUptime - self.lastNavAt < 0.6 {
                self.scheduleLiveRefresh()   // flag is clear now → reschedules for later
                return
            }
            self.engine.invalidate()
            self.indexedCount = self.index.safeCount()   // reconciler may still be appending
            self.runSearch()
        }
    }

    @objc private func appBecameActive() {
        guard pendingLiveRefresh else { return }
        pendingLiveRefresh = false
        scheduleLiveRefresh()
    }

    // MARK: - Snapshot persistence

    private var snapshotDirty = false
    private var saveTimer: Timer?

    private func startPeriodicSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self, !self.isIndexing else { return }
            // Compact away accumulated tombstones (long high-churn sessions) by
            // re-indexing — reuses the well-tested crawl path and reclaims RAM.
            let s = self.index.liveStats()
            if s.total > 50_000, s.deleted > s.total * 2 / 5 {
                Diag.log("compacting: \(s.deleted)/\(s.total) tombstoned → reindex")
                self.beginIndexing()
                return
            }
            if self.snapshotDirty { self.saveSnapshot() }
        }
    }

    /// Write the index to disk. `sync` (used on app termination) blocks until done.
    func saveSnapshot(sync: Bool = false) {
        guard !isIndexing else { return }
        snapshotDirty = false
        let idx = index
        let lastEventId = watcher.lastEventId
        let savedAt = Date().timeIntervalSince1970
        let url = Snapshot.defaultURL()
        let work = {
            let data = idx.snapshotData(lastEventId: lastEventId, savedAt: savedAt)
            try? data.write(to: url, options: .atomic)
            Diag.log("SAVED snapshot \(data.count / (1024*1024)) MB @\(lastEventId)")
        }
        if sync { work() } else { indexQueue.async(execute: work) }
    }

    func recheckFullDiskAccess() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        if hasFullDiskAccess {
            showOnboarding = false
            beginIndexing()   // safely cancels + restarts with protected paths readable
        }
    }

    func openFDASettings() { Permissions.openFullDiskAccessSettings() }

    func reindex() { beginIndexing() }

    func setIncludeCloud(_ on: Bool) {
        guard on != includeCloud else { return }
        includeCloud = on
        beginIndexing()
    }

    func toggleScope() { scope = (scope == .nameOnly) ? .fullPath : .nameOnly }

    /// The user's typed query combined with the active type-filter chip.
    var effectiveQuery: String {
        let c = typeFilter.clause
        if c.isEmpty { return query }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? c : c + " " + q
    }

    // MARK: - recent queries & saved searches

    private static let recentsKey = "mv.recentQueries"
    private static let savedKey = "mv.savedSearches"
    private static func loadRecents() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }
    private static func loadSaved() -> [SavedSearch] {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let arr = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return [] }
        return arr
    }

    /// Record a query the user actually committed (Enter / opened a result).
    func recordRecentQuery(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        recentQueries.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recentQueries.insert(q, at: 0)
        if recentQueries.count > 15 { recentQueries.removeLast(recentQueries.count - 15) }
        UserDefaults.standard.set(recentQueries, forKey: Self.recentsKey)
    }

    func clearRecents() {
        recentQueries.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    /// Shell-style history cycling in the search field: ⌘↑ = older, ⌘↓ = newer.
    private var historyCursor = -1
    func cycleHistory(older: Bool) {
        guard !recentQueries.isEmpty else { return }
        if older { historyCursor = min(historyCursor + 1, recentQueries.count - 1) }
        else { historyCursor -= 1 }
        if historyCursor < 0 { historyCursor = -1; query = "" }
        else { query = recentQueries[historyCursor] }
    }

    /// Apply a recent/saved query and run it.
    func applyQuery(_ q: String) {
        query = q
        focusNonce &+= 1   // keep focus on the search field
    }

    /// Restrict subsequent searches to a folder subtree (files use their parent dir).
    func searchInFolder(path: String, isDir: Bool) {
        scopeRoot = isDir ? path : (path as NSString).deletingLastPathComponent
        focusNonce &+= 1
    }

    func saveCurrentSearch(name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let s = SavedSearch(name: n, query: q, matchMode: matchMode.rawValue,
                            typeFilter: typeFilter.rawValue, scope: scope.rawValue)
        savedSearches.removeAll { $0.name.caseInsensitiveCompare(n) == .orderedSame }
        savedSearches.append(s)
        persistSaved()
    }

    func applySaved(_ s: SavedSearch) {
        matchMode = MatchMode(rawValue: s.matchMode) ?? .exact
        typeFilter = TypeFilter(rawValue: s.typeFilter) ?? .all
        scope = SearchScope(rawValue: s.scope) ?? .nameOnly
        query = s.query
        focusNonce &+= 1
    }

    func deleteSaved(_ s: SavedSearch) {
        savedSearches.removeAll { $0.id == s.id }
        persistSaved()
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(savedSearches) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
    }

    // MARK: - export current results

    /// All current result paths, newline-joined (for "Copy All Paths").
    func allResultPaths() -> String {
        resultsStore.ids.map { index.path(Int($0)) }.joined(separator: "\n")
    }

    /// The current result set as CSV (Name, Path, Size, Date Modified, Date Created).
    func buildResultsCSV() -> String {
        let ids = resultsStore.ids
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func date(_ ns: Int64) -> String { ns == 0 ? "" : df.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9)) }
        func esc(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n"))
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = "Name,Path,Size,Date Modified,Date Created\n"
        out.reserveCapacity(ids.count * 96)
        for id in ids {
            let r = index.row(Int(id))
            let size = r.isDir ? "" : String(r.size)
            out += esc(r.name) + "," + esc(r.path) + "," + size + "," + date(r.mtime) + "," + date(r.crtime) + "\n"
        }
        return out
    }

    func runSearch() {
        guard !isIndexing else { return }   // M1: index is immutable only after crawl
        searchSeq &+= 1
        let seq = searchSeq
        let q = effectiveQuery, sk = sortKey, asc = ascending, sc = scope, mm = matchMode
        let root = scopeRoot
        let now = Date().timeIntervalSince1970
        let engine = self.engine
        let idx = self.index
        searchQueue.async { [weak self] in
            guard let self else { return }
            let rootIdx = root.flatMap { idx.dirIndex(forPath: $0) }
            let res = engine.search(q, mode: mm, scope: sc, sortKey: sk, ascending: asc,
                                    now: now, scopeRoot: rootIdx)
            DispatchQueue.main.async {
                guard seq == self.searchSeq else { return }   // drop stale
                self.resultsStore.ids = res.ids
                self.resultTotal = res.total
                self.queryMillis = res.queryMillis
                self.resultsVersion &+= 1
            }
        }
    }

    /// Warm ALL sort orders off the main thread (so the first search and any
    /// column-sort switch are instant), then run the current query.
    private func prewarmAndSearch() {
        let engine = self.engine
        searchQueue.async {
            for k in [SortKey.name, .size, .dateModified] {
                _ = engine.search("", sortKey: k, ascending: true, limit: 1)
            }
        }
        runSearch()
    }

    // Convenience for the table coordinator.
    func path(_ id: Int32) -> String { index.path(Int(id)) }
    func name(_ id: Int32) -> String { index.name(Int(id)) }
    func directory(_ id: Int32) -> String { index.directory(Int(id)) }
}

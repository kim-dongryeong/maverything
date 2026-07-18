import AppKit
import Combine
import CoreServices
import Foundation
import MaverythingCore
import os

/// Lightweight, **opt-in** file logger so we can verify the in-app engine pipeline
/// headlessly. OFF by default — these lines include the user's folder/volume paths,
/// so a shipped app must not silently write the user's filesystem structure to disk.
/// Enable with `MV_DIAG=1` (writes to `~/Library/Logs/Maverything/maverything-diag.log`,
/// a real, creatable location — not a hardcoded dev path); override the destination
/// with `MV_DIAG_PATH=/some/file`.
enum Diag {
    /// nil ⇒ logging disabled (the release default). Resolved once at launch.
    static let path: String? = {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["MV_DIAG_PATH"], !custom.isEmpty { return custom }
        guard env["MV_DIAG"] == "1" else { return nil }
        let dir = NSHomeDirectory() + "/Library/Logs/Maverything"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/maverything-diag.log"
    }()

    static var isEnabled: Bool { path != nil }

    /// `@autoclosure` so the message (often a `map`/`join` over path lists) is never
    /// built when logging is disabled — zero cost on the default release path.
    static func log(_ s: @autoclosure () -> String) {
        guard let path else { return }
        let line = "[\(Date())] \(s())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
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
    case all, folders, files, documents, images, audio, video, archives, apps
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All";             case .folders: return "Folders"
        case .files: return "Files"
        case .documents: return "Documents"; case .images: return "Images"
        case .audio: return "Audio";         case .video: return "Video"
        case .archives: return "Archives";   case .apps: return "Apps"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2";  case .folders: return "folder"
        case .files: return "doc"
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
        case .files:     return "file:"
        // Media chips mean "…FILES", so they carry file: — otherwise a DIRECTORY that
        // merely ends in an image/doc extension (e.g. a CoreSimulator "IMG_0001.JPG"
        // thumbnail folder) would show up. file: is Finder-package-aware, so .app (an
        // "apps" package) still counts; a plain folder named foo.jpg does not.
        // These emit the `type:` operator (backed by FileIndex.typeClass — one O(1) bit
        // test per candidate instead of re-scanning the extension against a list every
        // keystroke). Category ↔ extension lists live in MaverythingCore.FileTypeClass.
        case .documents: return "file: type:documents"
        case .images:    return "file: type:images"
        case .audio:     return "file: type:audio"
        case .video:     return "file: type:video"
        case .archives:  return "file: type:archives"
        case .apps:      return "file: type:apps"
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
    @Published var resultShown = 0          // rows actually returned (may be capped below resultTotal)
    @Published var contentIncomplete = false   // `content:` hit the scan budget → results may be partial
    @Published var contentSkippedLarge = 0     // files skipped for exceeding the 64 MB content cap
    // The search inputs (query + filters) that produced the CURRENTLY displayed results.
    // "No Results" shows only when this equals `searchSignature` (the inputs right now) —
    // i.e. the empty result really belongs to what's on screen. The instant the user changes
    // a chip/query/scope, `searchSignature` changes (it reads live @Published state), so a
    // stale "No Results" is hidden immediately, with NO dependency on a flag being toggled
    // in time — and a background refresh re-runs the same inputs, so the signature is
    // unchanged and the empty-state can't blink.
    @Published var resultsSignature = "\u{1}initial"

    /// A fingerprint of every input that affects the result SET (not its order). Compared
    /// against `resultsSignature` to decide whether "No Results" is current or stale.
    var searchSignature: String {
        "\(effectiveQuery)\u{1}\(String(describing: scope))\u{1}\(String(describing: matchMode))"
        + "\u{1}\(scopeRoot ?? "")\u{1}\(wholeWord)\u{1}\(matchCase)"
    }
    @Published var indexedCount = 0
    @Published var queryMillis = 0.0
    @Published var resultsVersion = 0
    @Published var queryNonce = 0          // bumps only on a NEW query (not live refresh)
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    @Published var scope: SearchScope = .nameOnly
    @Published var matchMode: MatchMode = .exact
    @Published var wholeWord = false               // Everything's Match Whole Word (ww:, ⌃B)
    @Published var matchCase = false               // Everything's Match Case (case:on, ⌃I)
    /// Everything's "Match whole filename when using wildcards" (Options ▸ Search).
    @Published var wildcardWholeName: Bool =
        (UserDefaults.standard.object(forKey: "mv.wildcardWholeName") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(wildcardWholeName, forKey: "mv.wildcardWholeName")
            engine.wholeNameWildcards = wildcardWholeName
            runSearch()
            broadcastResultsRefresh()   // engine-level option — other windows must re-search too
        }
    }
    @Published var typeFilter: TypeFilter = .all   // Everything-style quick type chips
    @Published var recentQueries: [String] = AppModel.loadRecents()
    @Published var savedSearches: [SavedSearch] = AppModel.loadSaved()
    @Published var scopeRoot: String? = nil        // "Search in This Folder" — restrict to a subtree
    @Published var isIndexing = true {
        didSet { let v = isIndexing; AppModel.indexingMirror.withLock { $0 = v } }   // thread-safe mirror for QueryServer
    }
    /// Lock-protected mirror of `isIndexing` so the background socket-server thread can
    /// read it without touching @MainActor state (Codex + red-team: reading the
    /// @Published Bool off-main is a data race / Swift-6 break).
    static let indexingMirror = OSAllocatedUnfairLock(initialState: true)
    @Published var hasFullDiskAccess = true
    @Published var showOnboarding = false
    @Published var includeCloud = false        // index ~/Library/CloudStorage etc.
    /// Everything 1.5-style OFFLINE VOLUMES (r/macapps ask; the paid "Offline Disks File
    /// Searcher" app's whole value prop): keep an unplugged volume's entries in the index —
    /// searchable, dimmed — instead of tombstoning them on unmount. Re-plugging re-crawls
    /// the volume fresh (the existing addition path already tombstones the stale copy first).
    @Published var keepOfflineVolumes: Bool =
        (UserDefaults.standard.object(forKey: "mv.keepOffline") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(keepOfflineVolumes, forKey: "mv.keepOffline")
            if !keepOfflineVolumes {
                // Turning OFF: purge entries of volumes that are offline right now — they are
                // no longer in watchedRoots, so no future volume sync would clean them up.
                let mounted = Set(desiredCrawlRoots().map(\.displayPath))
                var removed = 0
                for rp in index.liveRootPaths() where !mounted.contains(rp) {
                    removed += index.markDeletedSubtree(displayPath: rp)
                }
                if removed > 0 { scheduleLiveRefresh() }
            }
            updateOfflineRoots()
        }
    }
    /// Roots present in the index but not currently mounted (offline). Read by the table
    /// to dim their rows. Maintained on the main actor after every crawl/volume change.
    private(set) var offlineRootPaths: Set<String> = []
    func updateOfflineRoots() {
        let mounted = Set(desiredCrawlRoots().map(\.displayPath))
        offlineRootPaths = Set(index.liveRootPaths()).subtracting(mounted)
    }
    /// Is this path under an offline (unplugged) volume root?
    func isOffline(_ path: String) -> Bool {
        guard !offlineRootPaths.isEmpty else { return false }
        return offlineRootPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    /// Everything's "folder indexing": user-added index roots for locations the local-
    /// volume scan doesn't cover — above all NETWORK shares/NAS mounts (non-MNT_LOCAL).
    @Published var customRoots: [String] = UserDefaults.standard.stringArray(forKey: "mv.customRoots") ?? [] {
        didSet { UserDefaults.standard.set(customRoots, forKey: "mv.customRoots") }
    }
    /// Everything's "Exclude files": semicolon-separated glob patterns (*.tmp;*.log)
    /// removed from the index at crawl AND live-update time. Changing it reindexes.
    @Published var excludeFilePatterns: String =
        UserDefaults.standard.string(forKey: "mv.excludeFiles") ?? "" {
        didSet {
            UserDefaults.standard.set(excludeFilePatterns, forKey: "mv.excludeFiles")
        }
    }
    func applyExcludeFilePatterns() { beginIndexing() }   // commit action from Settings
    var parsedFilePatterns: [[UInt8]] { FileEnumerator.parseFilePatterns(excludeFilePatterns) }
    /// Everything's "Include only files": non-empty whitelist → ONLY matching files
    /// are indexed (folders always kept for structure). Empty = index everything.
    @Published var includeOnlyFilePatterns: String =
        UserDefaults.standard.string(forKey: "mv.includeOnlyFiles") ?? "" {
        didSet { UserDefaults.standard.set(includeOnlyFilePatterns, forKey: "mv.includeOnlyFiles") }
    }
    var parsedIncludeOnly: [[UInt8]] { FileEnumerator.parseFilePatterns(includeOnlyFilePatterns) }
    /// User-added exclude folders (on top of the built-in exclusions).
    @Published var customExcludes: [String] = UserDefaults.standard.stringArray(forKey: "mv.customExcludes") ?? [] {
        didSet { UserDefaults.standard.set(customExcludes, forKey: "mv.customExcludes") }
    }
    /// Everything 1.5's "Folders first": group directories above files in every sort.
    @Published var foldersFirst: Bool =
        (UserDefaults.standard.object(forKey: "mv.foldersFirst") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(foldersFirst, forKey: "mv.foldersFirst")
            engine.foldersFirst = foldersFirst
            runSearch()
            broadcastResultsRefresh()   // engine-level option — other windows must re-search too
        }
    }
    /// Everything 1.5's "Index folder sizes": folders sort AND display by their live
    /// subtree totals (mutationGen-cached bottom-up pass, ~15 ms per rebuild at 2M).
    @Published var indexFolderSizes: Bool =
        (UserDefaults.standard.object(forKey: "mv.folderSizes") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(indexFolderSizes, forKey: "mv.folderSizes")
            engine.useFolderSizes = indexFolderSizes
            engine.invalidate()          // size order must rebuild with/without folder totals
            runSearch()
            broadcastResultsRefresh()   // engine-level option — other windows must re-search too
        }
    }
    /// Minutes between scheduled rescans of the custom index roots (0 = off).
    /// Network shares deliver no reliable FSEvents, so — like Everything's folder
    /// "Update" schedule — a periodic re-crawl is the only way to keep them fresh.
    @Published var customRootRescanMinutes: Int =
        (UserDefaults.standard.object(forKey: "mv.customRootRescan") as? Int) ?? 60 {
        didSet { UserDefaults.standard.set(customRootRescanMinutes, forKey: "mv.customRootRescan") }
    }
    @Published var showHidden: Bool =
        (UserDefaults.standard.object(forKey: "mv.showHidden") as? Bool) ?? true {
        didSet {                                 // Everything's Exclude-hidden, but LIVE:
            UserDefaults.standard.set(showHidden, forKey: "mv.showHidden")
            engine.hideHidden = !showHidden      // result-level filter — no reindex
            runSearch()
            broadcastResultsRefresh()   // engine-level option — other windows must re-search too
        }
    }
    @Published var enterRenames: Bool = UserDefaults.standard.bool(forKey: "mv.enterRenames") {
        didSet { UserDefaults.standard.set(enterRenames, forKey: "mv.enterRenames") }
    }
    /// PgUp/PgDn/Home/End move the SELECTION (Everything-style, default) vs. macOS's
    /// native scroll-only behavior — user-switchable per the build-all-options rule.
    @Published var navKeysMoveSelection: Bool =
        (UserDefaults.standard.object(forKey: "mv.navKeysMove") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(navKeysMoveSelection, forKey: "mv.navKeysMove") }
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
    /// Title-bar accent style (visual identity) — switch live in Settings to compare.
    @Published var titleBarTint: TitleBarTintStyle = TitleBarTintStyle(rawValue:
        UserDefaults.standard.string(forKey: "mv.titleBarTint") ?? "") ?? .full {
        didSet { UserDefaults.standard.set(titleBarTint.rawValue, forKey: "mv.titleBarTint") }
    }

    /// Set by the AppDelegate so the search UI can dismiss the panel (ESC).
    var requestHide: (() -> Void)?
    /// Everything's "Clear search on close" (Tools ▸ Options ▸ Search) — off by
    /// default there and here: reopening shows the previous query.
    @Published var clearSearchOnClose: Bool =
        UserDefaults.standard.bool(forKey: "mv.clearSearchOnClose") {
        didSet { UserDefaults.standard.set(clearSearchOnClose, forKey: "mv.clearSearchOnClose") }
    }

    // Multi-window: the FIRST model (primary) owns the whole index lifecycle — crawl,
    // FSEvents, snapshot, query server, hotkey. A "New Search Window" model attaches to
    // the primary's index + engine (both are concurrency-safe: engine caches are lock-
    // guarded and searches run under the index read lock — QueryServer already drives one
    // engine from concurrent connections), while ALL view state (query, results, sort,
    // chips, layout, selection) stays per-window in each model instance.
    let index: FileIndex
    let engine: SearchEngine
    let isPrimary: Bool
    weak var window: NSWindow?   // this model's own NSWindow (ContentView's WindowAccessor sets it)
    private var escMonitor: Any?   // window-level ESC hook (see installEscMonitor)
    private var keyObserver: NSObjectProtocol?   // secondary: first-become-key focus grant
    private var grantedInitialFocus = false
    /// Posted by whichever model changed state that affects every window's RESULTS
    /// (index contents after a live refresh/crawl, engine-level options). Every OTHER
    /// model re-runs its own search on receipt.
    static let resultsShouldRefresh = Notification.Name("mv.resultsShouldRefresh")
    private var refreshObserver: NSObjectProtocol?
    let resultsStore = ResultsStore()

    private var cancellables = Set<AnyCancellable>()
    private let searchQueue = DispatchQueue(label: "maverything.search", qos: .userInteractive)
    private let indexQueue = DispatchQueue(label: "maverything.index", qos: .userInitiated)
    // `searchSeq` is read/written from BOTH the main actor and the background search queue,
    // always under `seqLock` — so the accessors are `nonisolated` (a lock-guarded shared
    // counter, not actor state). This lets the engine's `@Sendable isStale` closure poll it
    // off-main to abort a superseded scan. `nonisolated(unsafe)` = "I hold the invariant
    // (always via seqLock) that the compiler can't verify."
    private nonisolated(unsafe) var searchSeq = 0
    private let seqLock = NSLock()   // guards searchSeq so the search queue can pre-check staleness
    private nonisolated func nextSearchSeq() -> Int { seqLock.lock(); searchSeq &+= 1; let v = searchSeq; seqLock.unlock(); return v }
    private nonisolated func currentSearchSeq() -> Int { seqLock.lock(); defer { seqLock.unlock() }; return searchSeq }
    private var started = false
    private var currentEnumerator: FileEnumerator?
    private var indexGen = 0
    private var queryServer: QueryServer?   // AF_UNIX server: mvfind/MCP live queries
    private let watcher = FSWatcher()
    private var reconciler: Reconciler?
    private let reconcileQueue = DispatchQueue(label: "maverything.reconcile", qos: .utility)
    private var watchedRoots: [CrawlRoot] = []
    private var volumeRefreshInFlight = false
    private var pendingVolumeRefresh = false

    init() {
        index = FileIndex()
        engine = SearchEngine(index: index)
        isPrimary = true
        resultsStore.index = index
        wireSearchPipelines()
        observeCrossWindowRefresh()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveSnapshot(sync: true)
            AppModel.sharedRunStats.flush()   // persist run history before exit
            self?.queryServer?.stop()         // remove the socket
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumeDidMount(_:)),
            name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumeDidUnmount(_:)),
            name: NSWorkspace.didUnmountNotification, object: nil)
    }

    /// A "New Search Window" model: shares the primary's index + engine, owns its own
    /// query/results/sort/chip state, and skips the entire index lifecycle (crawl, watch,
    /// snapshot, query server, onboarding) — those remain the primary's job.
    init(attachedTo primary: AppModel) {
        index = primary.index
        engine = primary.engine
        isPrimary = false
        resultsStore.index = index
        wireSearchPipelines()
        observeCrossWindowRefresh()

        // Mirror the primary's shared status so this window's overlays/status bar stay live.
        isIndexing = primary.isIndexing
        indexedCount = primary.indexedCount
        statusText = primary.statusText
        hasFullDiskAccess = primary.hasFullDiskAccess
        // Paint INSTANTLY instead of blank: a fresh ⌘N window shares the primary's index +
        // engine, and starts with the same default (empty) query — so when the primary is
        // already showing that same result set, its rows are byte-for-byte what our own first
        // search would return. Seed them now; our own search (below) re-runs and lands the
        // identical set ~0.5s later (a cold whole-disk sort), by which point the list is
        // already on screen. Guarded by the signature so we never flash the primary's
        // *filtered* results into a window that's about to show the full list.
        if primary.resultsSignature == searchSignature, !primary.resultsStore.ids.isEmpty {
            resultsStore.ids = primary.resultsStore.ids
            resultTotal = primary.resultTotal
            resultShown = primary.resultShown
            queryMillis = primary.queryMillis
            resultsSignature = primary.resultsSignature
            resultsVersion &+= 1
        }
        primary.$isIndexing.dropFirst()
            .sink { [weak self] v in
                self?.isIndexing = v
                if !v { self?.runSearch() }   // crawl / snapshot load finished → populate
            }
            .store(in: &cancellables)
        primary.$indexedCount.dropFirst()
            .sink { [weak self] in self?.indexedCount = $0 }.store(in: &cancellables)
        primary.$statusText.dropFirst()
            .sink { [weak self] in self?.statusText = $0 }.store(in: &cancellables)
        primary.$hasFullDiskAccess.dropFirst()
            .sink { [weak self] in self?.hasFullDiskAccess = $0 }.store(in: &cancellables)
        // ESC closes THIS window (the primary instead hides via the app delegate).
        // keyWindow fallback: requestHide only fires from views INSIDE this window, so if
        // `window` hasn't been captured yet the key window IS this window — never a no-op.
        requestHide = { [weak self] in
            let target = self?.window ?? NSApp.keyWindow
            Diag.log("requestHide(secondary): window=\(self?.window?.windowNumber ?? -1) key=\(NSApp.keyWindow?.windowNumber ?? -1) target=\(target?.windowNumber ?? -1)")
            target?.performClose(nil)
        }
        // Initial keyboard focus for a fresh ⌘N window. SwiftUI's onAppear runs before
        // the window is key (focus request dropped), and a view-level onReceive can
        // subscribe AFTER didBecomeKey already fired (missed) — so observe from the
        // MODEL, which exists before the window does. Bumping focusNonce routes through
        // ContentView's onChange, which applies focus AFTER the window is key → sticks.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, !self.grantedInitialFocus,
                  let w = note.object as? NSWindow, w === self.window else { return }
            self.grantedInitialFocus = true
            Diag.log("didBecomeKey(secondary #\(w.windowNumber)) → granting search-field focus")
            self.focusNonce &+= 1
        }
    }

    deinit {
        if let refreshObserver { NotificationCenter.default.removeObserver(refreshObserver) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
    }

    /// Called by ContentView's WindowAccessor the moment its view lands in this window.
    /// Handles BOTH orders of the attach/become-key race: if the window went key before
    /// we learned about it (didBecomeKey observer missed — it matches on `window`),
    /// grant the initial search-field focus right here.
    func attachWindow(_ w: NSWindow) {
        Diag.log("attachWindow: #\(w.windowNumber) primary=\(isPrimary) alreadyKey=\(w.isKeyWindow)")
        window = w
        installEscMonitor()
        w.level = .normal
        w.isMovableByWindowBackground = true
        if isPrimary { AppDelegate.shared?.adoptMainWindow(w) }   // login-item launch: orders it back out (silent start)
        if !isPrimary, !grantedInitialFocus, w.isKeyWindow {
            grantedInitialFocus = true
            Diag.log("attachWindow: already key → granting search-field focus")
            focusNonce &+= 1
        }
    }

    /// Window-level ESC (hide/close — Everything semantics), independent of keyboard focus.
    /// The view-level handlers (onExitCommand / table keyDown) only fire when something is
    /// FOCUSED — but a fresh ⌘N window (or a click on the title band) can leave focus
    /// nowhere, and ESC then silently did nothing (user repro: worked only after Tab).
    /// A local key monitor sees the event before the responder chain, so it always works.
    func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.keyCode == 53,   // ESC
                  let w = self.window, ev.window === w else { return ev }
            // An active IME composition (e.g. Korean jamo) must keep its ESC-to-cancel.
            if let fr = w.firstResponder as? NSTextView, fr.hasMarkedText() { return ev }
            Diag.log("ESC monitor: window #\(w.windowNumber) primary=\(self.isPrimary) syntax=\(self.showSyntax)")
            if self.showSyntax { self.showSyntax = false; return nil }   // 1st ESC closes help
            self.requestHide?()   // primary: hide via delegate · secondary: close the window
            return nil            // consumed
        }
    }

    /// The per-window search plumbing every model needs: debounce the query field and
    /// re-run on any search-input change. (Identical for primary and secondary windows.)
    private func wireSearchPipelines() {
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

        Publishers.Merge8(
            $sortKey.map { _ in () },
            $ascending.map { _ in () },
            $scope.map { _ in () },
            $matchMode.map { _ in () },
            $typeFilter.map { _ in () },
            $scopeRoot.map { _ in () },
            $wholeWord.map { _ in () },
            $matchCase.map { _ in () }
        )
        .dropFirst()
        .sink { [weak self] in self?.queryNonce &+= 1; self?.runSearch() }
        .store(in: &cancellables)
    }

    /// Re-run OUR search when another window changes shared state (index refresh,
    /// engine-level option). The sender skips itself — it already re-searched.
    private func observeCrossWindowRefresh() {
        refreshObserver = NotificationCenter.default.addObserver(
            forName: Self.resultsShouldRefresh, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? AppModel) !== self else { return }
            self.runSearch()
        }
    }

    /// Tell every OTHER window to re-run its search (shared index/engine state changed).
    private func broadcastResultsRefresh() {
        NotificationCenter.default.post(name: Self.resultsShouldRefresh, object: self)
    }

    private var progressTimer: Timer?

    /// An immutable snapshot of the user-editable crawl settings. Captured on the MAIN
    /// actor (via `crawlConfig`) and handed to the background indexQueue, so the crawl
    /// never reads @Published state concurrently with a Settings edit (Codex red-team:
    /// reading Swift String/Array storage off-main while it's mutated is a data race →
    /// undefined behaviour, from wrong config to memory corruption). `Sendable` because
    /// every field is a value type.
    struct CrawlConfig: Sendable {
        var includeCloud: Bool
        var customExcludes: [String]
        var customRoots: [String]
        var filePatterns: [[UInt8]]
        var includeOnly: [[UInt8]]
    }

    /// Capture the live settings. MUST be read on the main actor (it touches @Published).
    var crawlConfig: CrawlConfig {
        CrawlConfig(includeCloud: includeCloud, customExcludes: customExcludes,
                    customRoots: customRoots, filePatterns: parsedFilePatterns,
                    includeOnly: parsedIncludeOnly)
    }

    /// Path prefixes to skip. Cloud File Providers are excluded unless the user opts in;
    /// the autofs home map is always skipped. Pure over a captured config — safe off-main
    /// (only reads process-global `Volumes.*`, no @Published state).
    nonisolated static func exclusions(_ c: CrawlConfig) -> [String] {
        let base = c.includeCloud ? Volumes.alwaysExclusions() : Volumes.defaultExclusions()
        return base + c.customExcludes.map {
            ($0 as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping
        }
    }
    /// Main-actor convenience: snapshot the config and compute exclusions.
    private func currentExclusions() -> [String] { AppModel.exclusions(crawlConfig) }

    /// Every root we WANT indexed: the local volumes plus user-added folders that the
    /// volume scan doesn't reach (network shares/NAS are not MNT_LOCAL, so they only
    /// get in this way). Custom roots already covered by an indexed volume are skipped
    /// (they'd double-index); vanished ones (unreachable share) drop out, which routes
    /// their cleanup through the same volume-sync tombstone path as an unplug.
    /// Pure over a captured config — safe to call from the background crawl.
    nonisolated static func desiredCrawlRoots(_ c: CrawlConfig) -> [CrawlRoot] {
        var roots = Volumes.localCrawlRoots()
        var seen = Set(roots.map(\.displayPath))
        let excl = exclusions(c)
        let mounts = Volumes.allMountPoints()
        // The volume that actually CONTAINS p (crawls never descend into other mounts,
        // so "under /" alone does not mean covered — a NAS at /Volumes/NAS is not).
        func enclosingMount(_ p: String) -> String {
            var best = "/"
            for m in mounts where m != "/" && (p == m || p.hasPrefix(m + "/")) {
                if m.count > best.count { best = m }
            }
            return best
        }
        for raw in c.customRoots {
            let p = (raw as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping
            guard !seen.contains(p), FileManager.default.fileExists(atPath: p) else { continue }
            let coveredByLocal = seen.contains(enclosingMount(p))
            let underExclusion = excl.contains { p == $0 || p.hasPrefix($0 + "/") }
            if coveredByLocal && !underExclusion { continue }   // already indexed via its volume
            roots.append(CrawlRoot(fsPath: p, displayPath: p))
            seen.insert(p)
        }
        return roots
    }
    /// Main-actor convenience: snapshot the config and compute desired roots.
    func desiredCrawlRoots() -> [CrawlRoot] { AppModel.desiredCrawlRoots(crawlConfig) }

    func start() {
        guard !started else { return }
        started = true
        guard isPrimary else {
            // Secondary window: the shared index is already live (or still crawling —
            // the isIndexing mirror re-searches when it finishes). Just populate. (The
            // list is already on screen if init seeded it from the primary; this refreshes
            // it with our own freshly-computed set.)
            runSearch()
            return
        }
        engine.useFolderSizes = indexFolderSizes
        engine.foldersFirst = foldersFirst
        engine.hideHidden = !showHidden
        engine.wholeNameWildcards = wildcardWholeName
        engine.runStats = AppModel.sharedRunStats          // Run Count sort + relevance frecency

        // Live query server for mvfind / a future MCP bridge: same engine over a
        // dedicated instance so socket options never mutate the app's engine. Failure
        // is non-fatal (mvfind falls back to the snapshot).
        let qs = QueryServer(index: index, runStats: AppModel.sharedRunStats,
                             socketPath: QueryServer.defaultSocketPath(),
                             indexing: { AppModel.indexingMirror.withLock { $0 } })
        qs.start()
        queryServer = qs

        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        showOnboarding = !hasFullDiskAccess
        startPeriodicSave()
        startCustomRootRescanTimer()
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
                let roots = self.desiredCrawlRoots()
                // Roots that were in the snapshot but are NO LONGER mounted would otherwise
                // survive forever (the sync only diffs against currently-watched roots) —
                // unless Keep-offline-volumes is ON, where surviving is exactly the feature.
                let mountedNow = Set(roots.map(\.displayPath))
                if !self.keepOfflineVolumes {
                    for rp in self.index.liveRootPaths() where !mountedNow.contains(rp) {
                        let n = self.index.markDeletedSubtree(displayPath: rp)
                        Diag.log("snapshot root '\(rp)' no longer mounted → tombstoned \(n) rows")
                    }
                }
                self.updateOfflineRoots()
                let indexedRoots = roots.filter { self.index.dirIndex(forPath: $0.displayPath) != nil }
                self.startWatching(roots: indexedRoots,
                                   exclude: self.currentExclusions(),
                                   sinceWhen: meta.lastEventId)
                self.refreshMountedVolumes(reason: "snapshot root sync")
                // Correctness guard: FSEvents only retains a few days of history, so if we
                // were offline longer than that, the resume above may have missed changes.
                // Rather than blindly re-index on a timer (like some rivals), re-index ONLY
                // when the snapshot is old enough that the resume can't be trusted.
                let offline = Date().timeIntervalSince1970 - meta.savedAt
                if offline > Self.staleResumeSeconds {
                    Diag.log("snapshot stale by \(Int(offline))s (> trust window) → reindex for correctness")
                    self.beginIndexing()
                }
            }
        }
        return true
    }

    /// Offline gap beyond which a snapshot resume is considered unsafe (FSEvents history
    /// is finite) and we do a fresh crawl on launch to guarantee the index is correct.
    private static let staleResumeSeconds: Double = 3 * 24 * 3600   // 3 days

    /// (Re)start a whole-disk crawl across all local volumes. Safe to call while
    /// a crawl is running: the previous crawl is cancelled and superseded.
    func beginIndexing() {
        indexGen += 1
        let gen = indexGen
        watcher.stop()                  // pause live updates during (re)index
        currentEnumerator?.cancel()     // abort any in-flight crawl fast
        isIndexing = true
        indexedCount = 0
        // A reindex rebuilds the index from scratch, so every row id currently in the
        // result set points at the OLD generation. Invalidate them now so nothing maps
        // stale ids against the cleared/rebuilding arrays (Copy All Paths crash, wrong
        // CSV rows), and bump queryNonce so the post-reindex search is treated as a NEW
        // query — the table then drops the old (now-meaningless) selection instead of
        // re-selecting by numeric id.
        resultsStore.ids = []
        resultShown = 0
        resultTotal = 0
        queryNonce &+= 1
        statusText = "Indexing all local volumes…"

        let roots = self.desiredCrawlRoots()
        let exclude = currentExclusions()
        // Snapshot the user-editable crawl config on the MAIN actor now — reading these
        // @Published/computed properties from the background indexQueue would race a
        // concurrent Settings edit (Codex red-team). Everything the crawl needs is captured
        // here as immutable locals and passed in.
        let filePatterns = parsedFilePatterns
        let includeOnly = parsedIncludeOnly
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
                                 mountPoints: Volumes.allMountPoints(),
                                 excludeFilePatterns: filePatterns,
                                 includeOnlyFiles: includeOnly)
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
                self.updateOfflineRoots()   // a full recrawl only covers mounted volumes
                self.saveSnapshot()   // so the next launch is instant
                if self.pendingVolumeRefresh {
                    self.pendingVolumeRefresh = false
                    self.refreshMountedVolumes(reason: "pending after reindex")
                }
            }
        }
    }

    // MARK: - Real-time watching

    private func startWatching(roots: [CrawlRoot], exclude: [String],
                               sinceWhen: UInt64 = UInt64(kFSEventStreamEventIdSinceNow)) {
        watchedRoots = roots
        let watchPaths = Array(Set(roots.map { $0.displayPath }))
        let rec = Reconciler(index: index, exclude: exclude, mountPoints: Volumes.allMountPoints(),
                             excludeFilePatterns: parsedFilePatterns, includeOnlyFiles: parsedIncludeOnly)
        reconciler = rec
        let q = reconcileQueue
        watcher.start(paths: watchPaths, sinceWhen: sinceWhen) { [weak self] paths, mustScanAll, rootChanged, batchMax in
            guard let self else { return }
            if mustScanAll {
                // FSEvents history gap / dropped events → safest is a full re-crawl.
                Diag.log("FSEvents requested full reindex for roots: \(paths.joined(separator: ", "))")
                DispatchQueue.main.async { self.beginIndexing() }
                return
            }
            if rootChanged {
                // A watched ROOT vanished/moved. The overwhelmingly common cause is a volume
                // unplug (WatchRoot fires when the mount dir disappears) — handle that via the
                // graceful volume sync (tombstone + watcher restart), NOT a multi-minute full
                // reindex. Only when every watched root is still mounted (a true root rename/
                // replace on a live volume) do we fall back to the full re-crawl.
                DispatchQueue.main.async {
                    let mounted = Set(self.desiredCrawlRoots().map(\.displayPath))
                    let unplugged = self.watchedRoots.contains { !mounted.contains($0.displayPath) }
                    if unplugged {
                        self.refreshMountedVolumes(reason: "rootChanged (volume unplugged)")
                    } else {
                        Diag.log("rootChanged with all roots still mounted → full reindex")
                        self.beginIndexing()
                    }
                }
                return
            }
            q.async {
                let r = rec.reconcile(eventPaths: paths)
                // Advance the persisted resume cursor ONLY now that this batch is applied,
                // so a crash/quit can never persist an id ahead of the index.
                self.watcher.markApplied(batchMax)
                guard r.didMutate else { return }
                DispatchQueue.main.async { self.scheduleLiveRefresh() }
            }
        }
        Diag.log("watching: \(watchPaths.joined(separator: ", ")) since=\(sinceWhen)")
    }

    @objc private func volumeDidMount(_ note: Notification) {
        refreshMountedVolumes(reason: "didMount \(volumePath(from: note) ?? "unknown")")
    }

    @objc private func volumeDidUnmount(_ note: Notification) {
        refreshMountedVolumes(reason: "didUnmount \(volumePath(from: note) ?? "unknown")")
    }

    private func volumePath(from note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?
            .path.precomposedStringWithCanonicalMapping
    }

    private func rootsByDisplayPath(_ roots: [CrawlRoot]) -> [String: CrawlRoot] {
        var out: [String: CrawlRoot] = [:]
        for r in roots { out[r.displayPath] = r }
        return out
    }

    private func refreshMountedVolumes(reason: String) {
        guard started else { return }
        guard !isIndexing, !volumeRefreshInFlight else {
            pendingVolumeRefresh = true
            Diag.log("volume sync deferred (\(reason)); indexing=\(isIndexing) inFlight=\(volumeRefreshInFlight)")
            return
        }

        let desiredRoots = self.desiredCrawlRoots()
        let currentByPath = rootsByDisplayPath(watchedRoots)
        let desiredByPath = rootsByDisplayPath(desiredRoots)
        let removals = watchedRoots.filter { desiredByPath[$0.displayPath] == nil }
        let additions = desiredRoots.filter { currentByPath[$0.displayPath] == nil }
        guard !removals.isEmpty || !additions.isEmpty else { return }

        volumeRefreshInFlight = true
        let gen = indexGen
        let config = crawlConfig               // main-actor snapshot for the background crawl
        let exclude = AppModel.exclusions(config)
        let keepOffline = keepOfflineVolumes   // main-actor snapshot (read in the background block)
        let expectedRoots = watchedRoots.filter { desiredByPath[$0.displayPath] != nil } + additions
        let dynamicEnumerator = additions.isEmpty ? nil : FileEnumerator(index: index)
        if let dynamicEnumerator { currentEnumerator = dynamicEnumerator }
        Diag.log("volume sync (\(reason)): +[\(additions.map(\.displayPath).joined(separator: ", "))] -[\(removals.map(\.displayPath).joined(separator: ", "))]")

        indexQueue.async { [weak self] in
            guard let self else { return }
            // Same invariant as beginIndexing: capture the FSEvents cursor BEFORE crawling,
            // so events landing on the NEW volume during the (possibly long) append-crawl
            // are replayed after the watcher restarts. The old stream keeps reconciling old
            // volumes during the crawl and advances appliedEventId past them otherwise —
            // silently and permanently dropping those files.
            let preCrawlId: UInt64? = additions.isEmpty ? nil : FSEventsGetCurrentEventId()
            var removedRows = 0
            // Keep-offline: an unplugged volume's rows STAY in the index (dimmed, searchable);
            // only stop watching it. Re-plugging goes through `additions`, which tombstones
            // the stale copy below before the fresh crawl — so no duplicates either way.
            if !keepOffline {
                for r in removals {
                    removedRows += self.index.markDeletedSubtree(displayPath: r.displayPath)
                }
            }
            // If /Volumes delivered an event before NSWorkspace did, a mount point may
            // already exist as a child stub. Remove it before adding the real root.
            for r in additions {
                removedRows += self.index.markDeletedSubtree(displayPath: r.displayPath)
            }

            var addedRows = 0
            var openErrors = 0
            var seconds = 0.0
            if let en = dynamicEnumerator {
                let stats = en.crawl(roots: additions, restrictToVolume: false, exclude: exclude,
                                     mountPoints: Volumes.allMountPoints(),
                                 excludeFilePatterns: config.filePatterns,
                                 includeOnlyFiles: config.includeOnly)
                if !en.isCancelled {
                    self.index.buildLiveIndexes()
                    // A stale reconciler racing the mount may have indexed the volume AGAIN
                    // as a child subtree of /Volumes (its mount filter predated the mount).
                    // Tombstone any such duplicate stub copy, keeping the appended root.
                    for r in additions {
                        removedRows += self.index.tombstoneChildStubCopies(ofRootPath: r.displayPath)
                    }
                    addedRows = stats.total
                    openErrors = stats.openErrors
                    seconds = stats.seconds
                }
            }

            var finalRoots = expectedRoots
            if dynamicEnumerator?.isCancelled != true {
                // Re-evaluated post-crawl to catch volumes unmounted DURING the crawl: pure
                // over the captured config, so only the live mount state (Volumes.*) varies.
                let stillMounted = Set(AppModel.desiredCrawlRoots(config).map { $0.displayPath })
                if !keepOffline {
                    for r in finalRoots where !stillMounted.contains(r.displayPath) {
                        removedRows += self.index.markDeletedSubtree(displayPath: r.displayPath)
                    }
                }
                finalRoots.removeAll { !stillMounted.contains($0.displayPath) }
            }
            let finalRootKeys = Set(finalRoots.map { $0.displayPath })
            let desiredKeysAfterWork = Set(AppModel.desiredCrawlRoots(config).map { $0.displayPath })
            let needsAnotherPass = finalRootKeys != desiredKeysAfterWork
            let cancelled = dynamicEnumerator?.isCancelled == true

            DispatchQueue.main.async {
                if let en = dynamicEnumerator, self.currentEnumerator === en {
                    self.currentEnumerator = nil
                }
                self.volumeRefreshInFlight = false
                guard !cancelled, gen == self.indexGen else {
                    if self.pendingVolumeRefresh, !self.isIndexing {
                        self.pendingVolumeRefresh = false
                        self.refreshMountedVolumes(reason: "pending after cancelled volume sync")
                    }
                    return
                }

                // Resume from BEFORE the append-crawl when we added a volume (replay is
                // idempotent; resuming earlier is always safe) — appliedEventId alone can
                // have advanced past new-volume events that fired during the crawl.
                let resumeId = preCrawlId.map { min($0, self.watcher.appliedEventId) }
                    ?? self.watcher.appliedEventId
                self.startWatching(roots: finalRoots, exclude: self.currentExclusions(),
                                   sinceWhen: resumeId)
                self.updateOfflineRoots()
                // keepOffline removals mutate nothing, but the rows must repaint dimmed.
                if removedRows > 0 || addedRows > 0 || (keepOffline && !removals.isEmpty) {
                    self.indexedCount = self.index.safeCount()
                    self.scheduleLiveRefresh()
                    self.saveSnapshot()
                    Diag.log("volume sync applied: +\(addedRows) rows -\(removedRows) rows, \(openErrors) open-errors in \(String(format: "%.2f", seconds))s")
                }
                if needsAnotherPass || self.pendingVolumeRefresh {
                    self.pendingVolumeRefresh = false
                    self.refreshMountedVolumes(reason: "pending after volume sync")
                }
            }
        }
    }

    // MARK: - scheduled custom-root rescan (Everything's folder "Update")

    private var rescanTimer: Timer?
    /// Wall-clock time of the last completed custom-root rescan. Initialized to
    /// launch time so the first rescan lands one full interval after startup.
    private var lastCustomRootRescan: TimeInterval = Date().timeIntervalSince1970

    /// Cheap 5-minute heartbeat; the real cadence is `customRootRescanMinutes`.
    /// Same pattern as `startPeriodicSave` — the closure re-reads the live settings
    /// each tick, so changing the interval needs no timer restart.
    private func startCustomRootRescanTimer() {
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            let minutes = self.customRootRescanMinutes
            guard minutes > 0, !self.customRoots.isEmpty, !self.isIndexing,
                  Date().timeIntervalSince1970 - self.lastCustomRootRescan >= Double(minutes) * 60
            else { return }
            self.rescanCustomRoots()
        }
    }

    /// Re-crawl every custom index root in place: tombstone its subtree, append-crawl
    /// it fresh, then restart the watcher over the SAME roots. Custom roots are above
    /// all network shares (non-MNT_LOCAL), which get no reliable FSEvents — without
    /// this they silently drift from reality.
    private func rescanCustomRoots() {
        guard started else { return }
        // Shares refreshMountedVolumes' guards so the two flows can never overlap:
        // while a volume sync is in flight (or a reindex is running) we simply skip —
        // the 5-minute heartbeat retries soon. Conversely, while the rescan holds
        // volumeRefreshInFlight, a concurrent mount/unmount defers itself via
        // pendingVolumeRefresh, which we drain below exactly like the volume sync does.
        guard !isIndexing, !volumeRefreshInFlight else { return }

        // Only roots that are custom (not local volumes) AND currently watched AND
        // still reachable — desiredCrawlRoots() drops vanished shares via its
        // FileManager.fileExists guard, routing their cleanup to the volume sync.
        let localPaths = Set(Volumes.localCrawlRoots().map(\.displayPath))
        let watchedByPath = rootsByDisplayPath(watchedRoots)
        let roots = desiredCrawlRoots().filter {
            !localPaths.contains($0.displayPath) && watchedByPath[$0.displayPath] != nil
        }
        guard !roots.isEmpty else { return }   // e.g. share offline — retry next tick

        volumeRefreshInFlight = true
        let gen = indexGen
        let config = crawlConfig               // main-actor snapshot for the background crawl
        let exclude = AppModel.exclusions(config)
        let en = FileEnumerator(index: index)
        currentEnumerator = en
        Diag.log("custom-root rescan starting: [\(roots.map(\.displayPath).joined(separator: ", "))] (every \(customRootRescanMinutes) min)")

        indexQueue.async { [weak self] in
            guard let self else { return }
            // Same invariant as refreshMountedVolumes: capture the FSEvents cursor
            // BEFORE the re-crawl. The old stream keeps applying events during the
            // (possibly long) NAS crawl and advances appliedEventId past them, so
            // resuming from appliedEventId alone could silently drop changes that
            // landed on these roots mid-crawl.
            let preCrawlId = FSEventsGetCurrentEventId()
            var removedRows = 0
            for r in roots {
                removedRows += self.index.markDeletedSubtree(displayPath: r.displayPath)
            }
            let stats = en.crawl(roots: roots, restrictToVolume: false, exclude: exclude,
                                 mountPoints: Volumes.allMountPoints(),
                                 excludeFilePatterns: config.filePatterns,
                                 includeOnlyFiles: config.includeOnly)
            if !en.isCancelled { self.index.buildLiveIndexes() }
            let cancelled = en.isCancelled

            DispatchQueue.main.async {
                if self.currentEnumerator === en { self.currentEnumerator = nil }
                self.volumeRefreshInFlight = false
                guard !cancelled, gen == self.indexGen else {
                    if self.pendingVolumeRefresh, !self.isIndexing {
                        self.pendingVolumeRefresh = false
                        self.refreshMountedVolumes(reason: "pending after cancelled custom-root rescan")
                    }
                    return
                }
                // Resume from BEFORE the rescan (replay is idempotent; resuming earlier
                // is always safe) with the SAME watched roots — a rescan adds/removes
                // no roots, so the watch set is unchanged.
                let resumeId = min(preCrawlId, self.watcher.appliedEventId)
                self.startWatching(roots: self.watchedRoots, exclude: self.currentExclusions(),
                                   sinceWhen: resumeId)
                self.lastCustomRootRescan = Date().timeIntervalSince1970
                self.indexedCount = self.index.safeCount()
                self.scheduleLiveRefresh()
                self.saveSnapshot()
                Diag.log("custom-root rescan: \(roots.map(\.displayPath).joined(separator: ", ")) → \(stats.total) rows crawled, \(removedRows) tombstoned, \(stats.openErrors) open-errors in \(String(format: "%.2f", stats.seconds))s")
                if self.pendingVolumeRefresh {
                    self.pendingVolumeRefresh = false
                    self.refreshMountedVolumes(reason: "pending after custom-root rescan")
                }
            }
        }
    }

    // Coalesce bursts of filesystem changes into one index refresh so we don't
    // rebuild the sort order (and burn a core) on every individual event.
    private var liveRefreshScheduled = false
    private var pendingLiveRefresh = false
    /// Monotonic time the last live refresh actually ran. Watching all of `/` means macOS's
    /// own constant background writes (logs, caches, Spotlight) stream in events forever; each
    /// refresh re-runs a full ~2M sort (+ folder-size rebuild, ×every window), so under
    /// SUSTAINED churn we must cap the rate or the CPU never idles and the whole UI — ⌘N, ESC,
    /// typing — janks fighting for cores + the index lock. A single isolated change still
    /// reflects in `burstDelay`; only a storm gets throttled to `minRefreshInterval`.
    private var lastLiveRefreshAt: TimeInterval = 0
    /// Timestamp (monotonic) of the last keyboard navigation in the results list.
    /// A live refresh reloads the table, which would reset scroll/selection under an
    /// actively-held arrow key — so we defer it until the user pauses.
    var lastNavAt: TimeInterval = 0
    private func scheduleLiveRefresh() {
        snapshotDirty = true
        // Refresh whenever our window is on screen — even if we're not the frontmost app.
        // Moving/deleting a shown result from Finder (which makes Finder frontmost) must
        // still drop it from the list promptly; only fully defer when our window is hidden,
        // where there's nothing to update and no reason to burn a core on background churn.
        let windowVisible = window?.isVisible
            ?? (AppDelegate.shared?.mainWindow?.isVisible ?? false)
        guard NSApp.isActive || windowVisible else { pendingLiveRefresh = true; return }
        guard !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        // Snappy for an ISOLATED change (feels live); back off hard under SUSTAINED churn so a
        // full re-sort runs at most once per `minInterval` instead of ~3×/s pegging a core.
        let active = NSApp.isActive
        let burstDelay = active ? 0.35 : 0.6      // debounce one burst
        let minInterval = active ? 1.5 : 3.0      // cap the sustained full-refresh rate
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(burstDelay, lastLiveRefreshAt + minInterval - now)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.liveRefreshScheduled = false
            guard !self.isIndexing else { return }
            // Don't yank the list out from under active keyboard navigation.
            if ProcessInfo.processInfo.systemUptime - self.lastNavAt < 0.6 {
                self.scheduleLiveRefresh()   // flag is clear now → reschedules for later
                return
            }
            self.lastLiveRefreshAt = ProcessInfo.processInfo.systemUptime
            self.engine.invalidate()
            self.indexedCount = self.index.safeCount()   // reconciler may still be appending
            self.runSearch()                             // background live refresh (re-runs same inputs → no blink)
            self.broadcastResultsRefresh()               // other search windows show the same index — refresh them
            self.warmCachesInBackground()                // keep type-chip clicks instant
        }
    }

    private let warmQueue = DispatchQueue(label: "maverything.warm", qos: .utility)
    private var warmScheduled = false
    /// Rebuild the gen-keyed sort-order + package caches off the main thread so the next
    /// type-chip click (which issues a fresh query) finds them warm instead of paying a
    /// cold ~170-430ms rebuild. Debounced/coalesced; only warms while the app is active.
    func warmCachesInBackground() {
        guard NSApp.isActive, !isIndexing, !warmScheduled else { return }
        warmScheduled = true
        let engine = self.engine, sk = self.sortKey
        let idx = self.index, wantFolderSizes = self.indexFolderSizes
        warmQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            engine.warmCaches(sortKey: sk)
            // Warm folder subtree totals ONCE off-main after a refresh: the size column shows
            // them for every folder even under a name sort, so otherwise each visible folder
            // cell kicks its own full ~2M `buildFolderSizes()` on the gen bump (a redundant
            // rebuild storm). One warm here → cells hit the cache instead of racing.
            if wantFolderSizes { idx.buildFolderSizes() }
            DispatchQueue.main.async { self?.warmScheduled = false }
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
        let lastEventId = watcher.appliedEventId   // resume cursor = last APPLIED event, never ahead of the index
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

    // Help surfaces (⌘/ syntax, ⇧⌘/ shortcuts) — menu items drive these flags.
    /// Finder's "Show icon preview" for the table: media rows show mini thumbnails.
    @Published var iconPreview: Bool =
        (UserDefaults.standard.object(forKey: "mv.iconPreview") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(iconPreview, forKey: "mv.iconPreview")
            resultsVersion &+= 1                       // repaint visible rows
        }
    }
    /// Icon-grid thumbnail edge (pt) — Everything's Medium/Large/Extra Large Icons.
    @Published var thumbSize: CGFloat =
        CGFloat((UserDefaults.standard.object(forKey: "mv.thumbSize") as? Double) ?? 112) {
        didSet { UserDefaults.standard.set(Double(thumbSize), forKey: "mv.thumbSize") }
    }
    @Published var showSyntax = false
    @Published var showShortcuts = false
    @Published var showAdvancedSearch = false
    /// Set by OpenSettingsBridge with SwiftUI's openSettings environment action —
    /// the sendAction(showSettingsWindow:) path silently no-ops from an NSMenu.
    var openSettingsAction: (() -> Void)?
    func requestOpenSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let a = openSettingsAction { a(); return }
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func openFDASettings() { Permissions.openFullDiskAccessSettings() }

    /// ⌃M: rotate Exact → Fuzzy → Regex → Exact.
    func cycleMatchMode() {
        let modes = MatchMode.uiModes
        let i = modes.firstIndex(of: matchMode) ?? 0
        matchMode = modes[(i + 1) % modes.count]
    }

    /// Finder-faithful Open: a NON-package directory (plain folder, .framework,
    /// .sdk…) navigates INTO the folder; everything else goes through Launch-
    /// Services (launch .app, open file/package with its app). Plain
    /// NSWorkspace.open on a .framework errors — com.apple.framework has no
    /// registered opener even though Finder happily browses it.
    /// Shared run-history store (Everything's Run Count / frecency). Static so the
    /// static `finderOpen` — the single funnel for every open action across all four
    /// layouts — records into it without threading a model reference to each caller.
    static let sharedRunStats: RunStats = {
        let url = Snapshot.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("runstats.json")
        return RunStats(url: url)
    }()

    static func finderOpen(_ path: String) {
        var st = stat()
        let isDir = stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        var opened = false
        if isDir {
            let u = URL(fileURLWithPath: path, isDirectory: true)
            let pkg = (try? u.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            if !pkg {
                opened = NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                if opened { sharedRunStats.record(path: path, now: Date().timeIntervalSince1970) }
                return
            }
        }
        opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        // Record the "run" only when the open actually succeeded (Codex review) — a
        // failed open (missing file, no handler) shouldn't inflate the run count.
        if opened { sharedRunStats.record(path: path, now: Date().timeIntervalSince1970) }
    }

    func reindex() { beginIndexing() }

    /// Wipe Everything-style Run Count history and refresh the current results.
    func clearRunHistory() {
        AppModel.sharedRunStats.clear()
        engine.invalidate()
        runSearch()
        broadcastResultsRefresh()   // run-count sort / relevance boost changed everywhere
    }

    func setIncludeCloud(_ on: Bool) {
        guard on != includeCloud else { return }
        includeCloud = on
        beginIndexing()
    }

    // MARK: - user-managed index folders & exclusions (Everything's folder indexing / excludes)

    func addCustomRoot(_ rawPath: String) {
        let p = (rawPath as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping
        guard !customRoots.contains(p) else { return }
        customRoots.append(p)
        // The volume sync diffs desired vs watched roots → append-crawls just the new
        // root (no full reindex) and restarts the watcher to cover it.
        refreshMountedVolumes(reason: "custom root added: \(p)")
    }

    func removeCustomRoot(_ rawPath: String) {
        customRoots.removeAll { $0 == rawPath }
        refreshMountedVolumes(reason: "custom root removed: \(rawPath)")   // sync tombstones it
    }

    func addCustomExclude(_ rawPath: String) {
        let p = (rawPath as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping
        guard !customExcludes.contains(p) else { return }
        customExcludes.append(p)
        // No full reindex needed for ADDING an exclusion: tombstone the subtree and
        // restart the watcher so the reconciler's exclude list includes it.
        let excludes = currentExclusions()
        indexQueue.async { [weak self] in
            guard let self else { return }
            let n = self.index.markDeletedSubtree(displayPath: p)
            DispatchQueue.main.async {
                self.indexedCount = self.index.safeCount()
                self.startWatching(roots: self.watchedRoots, exclude: excludes,
                                   sinceWhen: self.watcher.appliedEventId)
                self.scheduleLiveRefresh()
                self.saveSnapshot()
                Diag.log("exclude added: \(p) (-\(n) rows)")
            }
        }
    }

    func removeCustomExclude(_ rawPath: String) {
        customExcludes.removeAll { $0 == rawPath }
        beginIndexing()   // re-including a subtree needs a crawl; full reindex is the simple correct path
    }

    func toggleScope() { scope = (scope == .nameOnly) ? .fullPath : .nameOnly }

    /// The user's typed query combined with the active type-filter chip.
    var effectiveQuery: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        let c = typeFilter.clause
        var parts: [String] = []
        if !c.isEmpty { parts.append(c) }
        if !q.isEmpty { parts.append(q) }
        guard !parts.isEmpty else { return "" }
        if matchCase { parts.insert("case:on", at: 0) }   // ⌃I toggle = the case:on filter
        if wholeWord { parts.insert("ww:", at: 0) }       // ⌃B toggle = the ww: filter
        return parts.joined(separator: " ")
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
        let mm = MatchMode(rawValue: s.matchMode) ?? .exact
        matchMode = mm == .wildcard ? .exact : mm   // wildcard mode retired from UI (auto-glob covers it)
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

    // MARK: - updates



    // MARK: - export current results

    /// All current result paths, newline-joined (for "Copy All Paths").
    func allResultPaths() -> String {
        guard !isIndexing else { return "" }   // ids belong to the old generation during a reindex
        return resultsStore.ids.map { index.path(Int($0)) }.joined(separator: "\n")
    }

    /// The current result set as CSV (Name, Path, Size, Date Modified, Date Created).
    func buildResultsCSV() -> String {
        guard !isIndexing else { return "Name,Path,Size,Date Modified,Date Created\n" }
        let ids = resultsStore.ids
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func date(_ ns: Int64) -> String { ns == 0 ? "" : df.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9)) }
        func esc(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r"))
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
        let seq = nextSearchSeq()
        let sig = searchSignature            // stamp the results with the inputs they're for
        let q = effectiveQuery, sk = sortKey, asc = ascending, sc = scope, mm = matchMode
        let root = scopeRoot
        let now = Date().timeIntervalSince1970
        let engine = self.engine
        let idx = self.index
        searchQueue.async { [weak self] in
            guard let self else { return }
            // Superseded by a newer keystroke before our turn on the serial queue → skip
            // the whole scan (typing enqueues many searches; only the latest need run).
            guard self.currentSearchSeq() == seq else { return }
            let rootIdx = root.flatMap { idx.dirIndex(forPath: $0) }
            // A folder scope that can't be resolved (deleted/renamed folder, or the
            // index mid-reindex) must NOT silently degrade into a whole-disk search —
            // return nothing, since the scope chip still says "in <folder>".
            if root != nil, rootIdx == nil {
                DispatchQueue.main.async {
                    guard self.currentSearchSeq() == seq else { return }
                    self.resultsStore.ids = []; self.resultTotal = 0; self.resultShown = 0
                    self.resultsSignature = sig
                    self.resultsVersion &+= 1
                }
                return
            }
            let res = engine.search(q, mode: mm, scope: sc, sortKey: sk, ascending: asc,
                                    now: now, scopeRoot: rootIdx,
                                    isStale: { [weak self] in self?.currentSearchSeq() != seq })
            DispatchQueue.main.async {
                guard self.currentSearchSeq() == seq else { return }   // drop stale
                self.resultsStore.ids = res.ids
                self.resultTotal = res.total
                self.resultShown = res.ids.count
                self.contentIncomplete = res.contentIncomplete
                self.contentSkippedLarge = res.contentSkippedLarge
                self.queryMillis = res.queryMillis
                self.resultsSignature = sig
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
            engine.warmCaches(sortKey: .name)   // also builds packageDirBitmap (file:/folder: chips)
        }
        runSearch()
        broadcastResultsRefresh()   // crawl/snapshot load finished → refresh other windows too
    }

    // Convenience for the table coordinator.
    func path(_ id: Int32) -> String { index.path(Int(id)) }
    func isDir(_ id: Int32) -> Bool { index.isDir(Int(id)) }
    func name(_ id: Int32) -> String { index.name(Int(id)) }
    func directory(_ id: Int32) -> String { index.directory(Int(id)) }
}

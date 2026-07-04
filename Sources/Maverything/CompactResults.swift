import AppKit
import MaverythingCore
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Layout A — a Spotlight/Alfred-style slim results list (top matches only),
/// keyboard-navigable: ↑/↓ move, ⏎ opens, ↑ at top returns to the search field.
struct CompactResults: View {
    @ObservedObject var model: AppModel
    @FocusState private var listFocused: Bool
    private let cap = 300

    private var ids: [Int32] { Array(model.resultsStore.ids.prefix(cap)) }

    var body: some View {
        let ids = self.ids
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ids, id: \.self) { id in
                        Row(model: model, id: id, selected: model.selectedID == id)
                            .id(id)
                            .onTapGesture(count: 2) { open(id) }
                            .onTapGesture { model.selectedID = id; listFocused = true }
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focused($listFocused)
            .onKeyPress(.downArrow) { move(+1, ids, proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, ids, proxy); return .handled }
            .onKeyPress(.return) { if let s = model.selectedID { open(s) }; return .handled }
            .onKeyPress(.space) {                       // Quick Look, same as the table
                guard let s = model.selectedID else { return .ignored }
                GridQL.shared.paths = [model.path(s)]
                GridQL.shared.onKey = { code in          // arrows browse while panel is key
                    switch code {
                    case 125: move(+1, self.ids, proxy); return true   // ↓
                    case 126: move(-1, self.ids, proxy); return true   // ↑
                    case 49:  QLPreviewPanel.shared().orderOut(nil); return true
                    default: return false
                    }
                }
                if let panel = QLPreviewPanel.shared() {
                    panel.dataSource = GridQL.shared
                    panel.delegate = GridQL.shared
                    panel.reloadData()
                    panel.makeKeyAndOrderFront(nil)
                }
                return .handled
            }
            .onKeyPress(.tab) { model.focusNonce &+= 1; return .handled }
            .onKeyPress(phases: .down) { press in
                if press.characters == "/" { model.focusNonce &+= 1; return .handled }
                return .ignored
            }
            .onChange(of: model.focusResultsNonce) {
                listFocused = true
                if model.selectedID == nil, let first = ids.first { model.selectedID = first }
                if let s = model.selectedID { proxy.scrollTo(s, anchor: .center) }
            }
            .onAppear {                       // selection carried over from another layout
                if let s = model.selectedID, ids.contains(s) {
                    proxy.scrollTo(s, anchor: .center)
                    DispatchQueue.main.async { listFocused = true }   // focus lands post-attach
                }
            }
        }
        .id(model.queryNonce)   // only rebuild identity on a NEW query, not on every live refresh
        // (empty / no-results / indexing states are drawn by ContentView's stateOverlay,
        // shared across all three layouts — no local overlay here or they'd double up)
    }

    private func move(_ delta: Int, _ ids: [Int32], _ proxy: ScrollViewProxy) {
        guard !ids.isEmpty else { return }
        let cur = model.selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        let next = cur + delta
        if next < 0 { model.focusNonce &+= 1; return }   // ↑ at top → back to search field
        let clamped = min(max(next, 0), ids.count - 1)
        model.selectedID = ids[clamped]
        proxy.scrollTo(ids[clamped], anchor: .center)
        refreshQLIfOpen(ids[clamped])
    }

    /// Open Quick Look keeps tracking the selection (same panel plumbing as the grid).
    private func refreshQLIfOpen(_ id: Int32) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              QLPreviewPanel.shared().isVisible else { return }
        GridQL.shared.paths = [model.path(id)]
        QLPreviewPanel.shared().reloadData()
    }

    private func open(_ id: Int32) { AppModel.finderOpen(model.path(id)) }

    struct Row: View {
        @ObservedObject var model: AppModel
        let id: Int32
        let selected: Bool
        var body: some View {
            let r = model.index.row(Int(id))
            return HStack(spacing: 8) {
                Image(nsImage: IconCache.icon(for: r.path, isDir: r.isDir))
                    .resizable().frame(width: 16, height: 16)
                Text(r.name).lineLimit(1)
                Spacer(minLength: 12)
                Text(r.directory)
                    .foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
    }
}

/// Caches computed bundle/package sizes (a .app's total, like Finder shows). The
/// subtree sum is done off the main thread; `onReady` fires once it's available.
enum BundleSizeCache {
    private static var cache: [String: Int64] = [:]
    private static var inflight: Set<String> = []
    private static let lock = NSLock()

    static func size(path: String, dirIdx: Int32, index: MaverythingCore.FileIndex,
                     onReady: @escaping () -> Void) -> Int64? {
        lock.lock()
        if let c = cache[path] { lock.unlock(); return c }
        if inflight.contains(path) { lock.unlock(); return nil }
        inflight.insert(path); lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let s = index.subtreeSize(of: dirIdx)
            lock.lock()
            if cache.count < 20_000 { cache[path] = s }
            inflight.remove(path)
            lock.unlock()
            DispatchQueue.main.async { onReady() }
        }
        return nil
    }
}

/// Reads & caches Finder color tags (per path) so the list can show colored dots
/// like Finder's list view. Cache misses are resolved OFF the main thread (the
/// getxattr syscall per fresh row adds up during sustained arrow-hold scrolling);
/// `onReady` fires on main once colors are cached — only when there ARE tags.
enum TagCache {
    private static var cache: [String: [NSColor]] = [:]
    private static var inflight: Set<String> = []
    private static let lock = NSLock()

    /// Cached colors, or nil while unknown (a background fetch is kicked off).
    static func colors(forPath path: String, onReady: (() -> Void)? = nil) -> [NSColor]? {
        lock.lock()
        if let c = cache[path] { lock.unlock(); return c }
        if inflight.contains(path) { lock.unlock(); return nil }
        inflight.insert(path); lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let cols = read(path)
            lock.lock()
            if cache.count < 20_000 { cache[path] = cols }
            inflight.remove(path)
            lock.unlock()
            // Re-render only when the row actually has dots to show.
            if !cols.isEmpty, let onReady { DispatchQueue.main.async { onReady() } }
        }
        return nil
    }

    /// Colored "●" run to append after a filename, or nil if the file has no color tags
    /// (or they're still loading — `onReady` re-renders the row when they arrive).
    static func dots(forPath path: String, onReady: (() -> Void)? = nil) -> NSAttributedString? {
        guard let cols = colors(forPath: path, onReady: onReady), !cols.isEmpty else { return nil }
        let out = NSMutableAttributedString(string: " ")
        for c in cols {
            out.append(NSAttributedString(string: "●",
                attributes: [.foregroundColor: c, .font: NSFont.systemFont(ofSize: 9)]))
        }
        return out
    }

    static func invalidate(_ path: String) { lock.lock(); cache[path] = nil; lock.unlock() }

    private static func read(_ path: String) -> [NSColor] {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let got = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        guard got > 0 else { return [] }
        guard let arr = try? PropertyListSerialization.propertyList(
            from: data.prefix(got), options: [], format: nil) as? [String] else { return [] }
        return arr.compactMap { tagColor($0) }
    }

    // Tag strings are "Name\nColorCode"; map Finder's codes to colors (no code → no dot).
    private static func tagColor(_ s: String) -> NSColor? {
        let parts = s.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
        switch code {
        case 1: return .systemGray;   case 2: return .systemGreen
        case 3: return .systemPurple; case 4: return .systemBlue
        case 5: return .systemYellow; case 6: return .systemRed
        case 7: return .systemOrange; default: return nil
        }
    }
}

/// Tiny icon cache so list/preview rows don't re-fetch NSWorkspace icons.
/// Non-bundle icons are keyed per extension (misses are rare after warm-up), but
/// bundles (.app/.framework…) are keyed PER PATH — those misses hit icon services
/// (XPC, can take ms) so they resolve OFF the main thread behind a placeholder,
/// with `onReady` re-rendering the row when the real icon lands.
enum IconCache {
    private static var cache: [String: NSImage] = [:]   // keyed by extension / "dir" / "file" / bundle path
    private static var inflight: Set<String> = []
    private static let lock = NSLock()

    static func icon(for path: String, isDir: Bool, isLink: Bool = false,
                     onReady: (() -> Void)? = nil) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        // A directory WITH an extension is a bundle/package (.app, .framework, .bundle…)
        // and carries its OWN icon — key it by path so it doesn't collapse onto the shared
        // generic-folder icon. Symlinks are also per-path: NSWorkspace returns the target's
        // icon WITH the alias-arrow badge (matching Finder), which is unique per link.
        // Plain folders + files share a bounded key set (per extension).
        let isBundle = (isDir && !ext.isEmpty) || isLink
        let key = isBundle ? ("\u{1}pkg\u{1}" + path)
                           : (isDir ? "\u{1}dir" : (ext.isEmpty ? "\u{1}file" : ext))
        lock.lock()
        if let c = cache[key] { lock.unlock(); return c }
        lock.unlock()

        if isBundle, let onReady {
            // Placeholder now; real bundle icon off-thread (NSWorkspace is thread-safe here).
            lock.lock()
            let queued = !inflight.insert(key).inserted
            lock.unlock()
            if !queued {
                DispatchQueue.global(qos: .userInitiated).async {
                    // Finder rule: only PACKAGES (.app, most .bundle) get their own icon;
                    // a browsable directory with an extension (.framework, .asset) shows
                    // the plain FOLDER icon. Match it exactly via isFilePackage.
                    let isPkg = isLink || NSWorkspace.shared.isFilePackage(atPath: path)
                    let img = isPkg ? NSWorkspace.shared.icon(forFile: path)
                                    : NSWorkspace.shared.icon(for: .folder)
                    img.size = NSSize(width: 16, height: 16)
                    lock.lock()
                    if cache.count < 5_000 { cache[key] = img }   // cap per-path growth
                    inflight.remove(key)
                    lock.unlock()
                    DispatchQueue.main.async { onReady() }
                }
            }
            return genericIcon(dir: true)        // stable folder placeholder (never a volume icon)
        }

        // Generic dir/file keys must come from a STABLE source: fetching icon(forFile:)
        // for whatever folder renders first can poison the shared key with a VOLUME or
        // custom-icon folder (e.g. "/" → Macintosh HD icon on every plain folder).
        let img: NSImage
        if key == "\u{1}dir" || key == "\u{1}file" {
            img = genericIcon(dir: isDir)
        } else {
            // BY TYPE, never by path: icon(forFile:) here let one mislabeled row
            // (a DIRECTORY passed with isDir=false, e.g. via a localized kind-string
            // check) poison the shared ext key with a FOLDER icon for every jpg.
            img = UTType(filenameExtension: key).map { NSWorkspace.shared.icon(for: $0) }
                  ?? genericIcon(dir: false)
        }
        img.size = NSSize(width: 16, height: 16)
        lock.lock()
        if !isBundle || cache.count < 5_000 { cache[key] = img }
        lock.unlock()
        return img
    }

    /// UTType-based generic icons — identical for every plain folder / extensionless file.
    private static func genericIcon(dir: Bool) -> NSImage {
        let img = NSWorkspace.shared.icon(for: dir ? .folder : .data)
        img.size = NSSize(width: 16, height: 16)
        return img
    }
}

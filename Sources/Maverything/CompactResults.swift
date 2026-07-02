import AppKit
import MaverythingCore
import SwiftUI

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
            .onChange(of: model.focusResultsNonce) {
                listFocused = true
                if model.selectedID == nil, let first = ids.first { model.selectedID = first }
                if let s = model.selectedID { proxy.scrollTo(s, anchor: .center) }
            }
        }
        .id(model.queryNonce)   // only rebuild identity on a NEW query, not on every live refresh
        .overlay {
            if ids.isEmpty {
                Text(model.query.isEmpty ? "Type to search" : "No results")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func move(_ delta: Int, _ ids: [Int32], _ proxy: ScrollViewProxy) {
        guard !ids.isEmpty else { return }
        let cur = model.selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        let next = cur + delta
        if next < 0 { model.focusNonce &+= 1; return }   // ↑ at top → back to search field
        let clamped = min(max(next, 0), ids.count - 1)
        model.selectedID = ids[clamped]
        proxy.scrollTo(ids[clamped], anchor: .center)
    }

    private func open(_ id: Int32) { NSWorkspace.shared.open(URL(fileURLWithPath: model.path(id))) }

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

/// Tiny icon cache so list/preview rows don't re-fetch NSWorkspace icons.
enum IconCache {
    private static var cache: [String: NSImage] = [:]   // keyed by extension / "dir" / "file"
    private static let lock = NSLock()
    static func icon(for path: String, isDir: Bool) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        // A directory WITH an extension is a bundle/package (.app, .framework, .bundle…)
        // and carries its OWN icon — key it by path so it doesn't collapse onto the shared
        // generic-folder icon. Plain folders + files share a bounded key set (per extension).
        let isBundle = isDir && !ext.isEmpty
        let key = isBundle ? ("\u{1}pkg\u{1}" + path)
                           : (isDir ? "\u{1}dir" : (ext.isEmpty ? "\u{1}file" : ext))
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 16, height: 16)
        // Per-path bundle icons could grow unbounded as the user scrolls; cap them.
        if !isBundle || cache.count < 5_000 { cache[key] = img }
        return img
    }
}

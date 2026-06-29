import AppKit
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
        .id(model.resultsVersion)
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
            HStack(spacing: 8) {
                Image(nsImage: IconCache.icon(for: model.path(id)))
                    .resizable().frame(width: 16, height: 16)
                Text(model.name(id)).lineLimit(1)
                Spacer(minLength: 12)
                Text(model.directory(id))
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

/// Tiny icon cache so list/preview rows don't re-fetch NSWorkspace icons.
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()
    static func icon(for path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? path : ext   // by extension when available (cheap + shared)
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 16, height: 16)
        cache[key] = img
        return img
    }
}

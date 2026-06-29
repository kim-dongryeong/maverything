import AppKit
import SwiftUI

/// Layout A — a Spotlight/Alfred-style slim results list (top matches only).
/// Lightweight SwiftUI list capped to a small count, so no NSTableView needed.
struct CompactResults: View {
    @ObservedObject var model: AppModel
    private let cap = 200

    var body: some View {
        let ids = Array(model.resultsStore.ids.prefix(cap))
        ScrollViewReader { _ in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ids, id: \.self) { id in
                        Row(model: model, id: id, selected: model.selectedID == id)
                            .onTapGesture(count: 2) { open(id) }
                            .onTapGesture { model.selectedID = id }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .id(model.resultsVersion)   // rebuild when results change
        .overlay {
            if ids.isEmpty {
                Text(model.query.isEmpty ? "Type to search" : "No results")
                    .foregroundStyle(.secondary)
            }
        }
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

import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI

/// Icon-grid layout (⌘4) — Everything 1.4's Medium/Large/Extra-Large Icons,
/// done the macOS way: Finder-style grid with real QuickLook thumbnails.
/// Photos, designs and PDFs become findable BY EYE, not just by name.
struct GridResults: View {
    @ObservedObject var model: AppModel
    @State private var selected: Int32? = nil
    @FocusState private var focused: Bool
    private let cap = 2_000                      // thumbnails are costly — cap the grid

    private var ids: [Int32] { Array(model.resultsStore.ids.prefix(cap)) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbSize + 28),
                                             spacing: 12)], spacing: 14) {
                    ForEach(ids, id: \.self) { id in
                        cell(id)
                            .id(id)
                            .onTapGesture(count: 2) { AppModel.finderOpen(model.path(id)) }
                            .onTapGesture { select(id) }
                            .contextMenu {
                                Button("Open") { AppModel.finderOpen(model.path(id)) }
                                Button("Reveal in Finder") { reveal(id) }
                                Divider()
                                Button("Quick Look") { quickLook(id) }
                                Button("Copy as Pathname") { copyPath(id) }
                            }
                    }
                }
                .padding(14)
            }
            .onChange(of: selected) { _, sel in
                if let sel { proxy.scrollTo(sel) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear { focused = true; if selected == nil { selected = ids.first } }
        .onChange(of: model.resultsVersion) {
            if let sel = selected, !ids.contains(sel) { selected = ids.first }
        }
    }

    @ViewBuilder private func cell(_ id: Int32) -> some View {
        let isSel = selected == id
        VStack(spacing: 6) {
            ThumbView(path: model.path(id), isDir: model.isDir(id), size: model.thumbSize)
                .frame(width: model.thumbSize, height: model.thumbSize)
            Text(model.name(id))
                .font(.system(size: 11.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(isSel ? Color.white : Color.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(isSel ? Color.accentColor : Color.clear))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isSel ? Color.accentColor.opacity(0.14) : Color.clear))
        .help(model.path(id))
    }

    private func select(_ id: Int32) {
        selected = id
        model.selectedID = id
        model.selectionCount = 1
        model.selectionBytes = 0
    }
    private func reveal(_ id: Int32) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path(id))])
    }
    private func copyPath(_ id: Int32) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.path(id), forType: .string)
    }
    private func quickLook(_ id: Int32) {
        GridQL.shared.paths = [model.path(id)]
        if let panel = QLPreviewPanel.shared() {
            panel.dataSource = GridQL.shared
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let items = ids
        guard !items.isEmpty else { return .ignored }
        let cols = max(1, currentColumns())
        let idx = selected.flatMap { items.firstIndex(of: $0) } ?? 0
        switch press.key {
        case .rightArrow: select(items[min(items.count - 1, idx + 1)]); return .handled
        case .leftArrow:  select(items[max(0, idx - 1)]); return .handled
        case .downArrow:  select(items[min(items.count - 1, idx + cols)]); return .handled
        case .upArrow:
            if idx - cols < 0 { model.focusNonce &+= 1 } else { select(items[idx - cols]) }
            return .handled
        case .space:      if let sel = selected { quickLook(sel) }; return .handled
        case .return:     if let sel = selected { AppModel.finderOpen(model.path(sel)) }; return .handled
        case .tab:        model.focusNonce &+= 1; return .handled
        default:
            if press.characters == "/" { model.focusNonce &+= 1; return .handled }
            return .ignored
        }
    }

    /// Approximate visible column count from the window width (for ↑/↓ moves).
    private func currentColumns() -> Int {
        let w = NSApp.keyWindow?.contentView?.bounds.width ?? 960
        return max(1, Int((w - 28) / (model.thumbSize + 40)))
    }
}

/// Detached QLPreviewPanel data source (the grid is SwiftUI — no NSResponder
/// to take panel control, so we drive the panel directly).
final class GridQL: NSObject, QLPreviewPanelDataSource {
    static let shared = GridQL()
    var paths: [String] = []
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { paths.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        URL(fileURLWithPath: paths[index]) as QLPreviewItem
    }
}

/// Async QuickLook thumbnail over an INDEX-DRIVEN placeholder icon.
/// The placeholder comes from UTType-by-extension (never a disk stat), and the
/// index's own isDir decides folder-ness — so a .jpg can never render as a
/// folder no matter what the disk/TCC says, and plain folders never waste a
/// QL request (their thumbnail IS the folder icon).
struct ThumbView: View {
    let path: String
    let isDir: Bool
    let size: CGFloat
    @State private var image: NSImage? = nil

    private var wantsThumbnail: Bool {
        // files: yes. Dirs: only bundle-ish ones (.app icons, .framework →
        // QL correctly draws the folder). Plain folders: skip, icon is final.
        !isDir || !(path as NSString).pathExtension.isEmpty
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            } else {
                Image(nsImage: GridIcon.icon(ext: (path as NSString).pathExtension, isDir: isDir))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.62, height: size * 0.62)
            }
        }
        .task(id: path + "|\(Int(size))|\(isDir)") {
            guard wantsThumbnail else { image = nil; return }
            image = await ThumbCache.shared.thumbnail(for: path, side: size)
        }
    }
}

/// Big UTType-based icons for the grid (IconCache's 16-pt instances would blur).
/// Bounded: one NSImage per extension + dir/file generics.
enum GridIcon {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()
    static func icon(ext rawExt: String, isDir: Bool) -> NSImage {
        let ext = rawExt.lowercased()
        let key = isDir ? "\u{1}dir" : (ext.isEmpty ? "\u{1}file" : ext)
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let img: NSImage
        if isDir {
            img = NSWorkspace.shared.icon(for: .folder)
        } else if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            img = NSWorkspace.shared.icon(for: ut)
        } else {
            img = NSWorkspace.shared.icon(for: .data)
        }
        let copy = img.copy() as! NSImage          // never mutate NSWorkspace's shared instance
        copy.size = NSSize(width: 128, height: 128)
        if cache.count < 2_000 { cache[key] = copy }
        return copy
    }
}

/// Process-wide thumbnail cache: QLThumbnailGenerator behind an NSCache.
/// Only .thumbnail representations are cached (icons stay the cheap fallback),
/// keyed by path+size so the grid's size picker gets crisp regenerations.
final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 3_000 }

    func thumbnail(for path: String, side: CGFloat) async -> NSImage? {
        let key = "\(path)|\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let req = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
        else { return nil }
        let img = rep.nsImage
        cache.setObject(img, forKey: key)
        return img
    }
}

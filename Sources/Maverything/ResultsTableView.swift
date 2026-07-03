import AppKit
import MaverythingCore
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// NSTableView subclass that adds Finder-style Quick Look (Space) and Return-to-open,
/// while leaving arrow-key navigation to AppKit's native handling.
final class MVTableView: NSTableView {
    weak var qlSource: (QLPreviewPanelDataSource & QLPreviewPanelDelegate)?
    weak var coordinator: ResultsTableView.Coordinator?

    override func keyDown(with event: NSEvent) {
        // Only the real chord modifiers — NOT capsLock/function/numericPad, which are in
        // deviceIndependentFlagsMask and would break the exact `== [.command]` checks below.
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // remember active list navigation so live refreshes don't reload under a held key
        switch event.keyCode {
        case 125, 126, 116, 121, 115, 119:   // ↓ ↑ pgDn pgUp home end
            coordinator?.model.lastNavAt = ProcessInfo.processInfo.systemUptime
            // A HELD key delivers auto-repeats each in its own runloop cycle, so per-cycle
            // coalescing still published once per repeat — a SwiftUI transaction between
            // every native selection step (the residual jank). During a repeat run we stop
            // publishing entirely; keyUp (or a quiet-gap fallback) publishes ONCE at the end.
            if event.isARepeat { coordinator?.beginNavRepeat() }
        default: break
        }
        if event.keyCode == 8 {                                 // C
            if mods == [.command] { coordinator?.copyFile(); return }          // ⌘C  → copy the file(s), Finder-style
            if mods == [.command, .option] { coordinator?.copyPath(); return } // ⌘⌥C → copy pathname
        }
        if mods == [.command], event.keyCode == 15 {           // ⌘R → reveal in Finder
            coordinator?.revealItem(); return
        }
        if mods == [.command], event.keyCode == 51 {           // ⌘⌫ → move to Trash
            coordinator?.moveToTrash(); return
        }
        if mods == [.command], event.keyCode == 34 {           // ⌘I → Get Info (Finder)
            coordinator?.getInfo(); return
        }
        switch event.keyCode {
        case 44 where mods.isEmpty:   // "/" → jump to the search field (vim/GitHub style)
            coordinator?.focusSearch()
        case 48:            // Tab → hand focus back to the search field (Everything-style)
            coordinator?.focusSearch()
        case 120:           // F2 → rename
            coordinator?.beginRename()
        case 49:            // space → toggle Quick Look
            toggleQuickLook()
        case 36, 76:        // return / enter → open (or rename, per setting)
            if coordinator?.model.enterRenames == true { coordinator?.beginRename() }
            else { coordinator?.openItem() }
        case 126:           // up arrow at the top → hand focus back to the search field
            // …but only for direct table nav, not when forwarded from the Quick Look panel
            if selectedRow <= 0, window?.firstResponder === self {
                // A deliberate tap at the top jumps to the search box; a HELD key just
                // parks at row 0 (don't fire focusSearch every auto-repeat → no bounce).
                if !event.isARepeat { coordinator?.focusSearch() }
            } else {
                super.keyDown(with: event)
                if event.isARepeat { alignSelection(toBottom: false) }
            }
        case 125:           // down arrow — at the last row a held key would jump/over-scroll
            if selectedRow >= 0, selectedRow == numberOfRows - 1, event.isARepeat { return }
            super.keyDown(with: event)
            if event.isARepeat { alignSelection(toBottom: true) }
        case 116, 121, 115, 119:   // pgUp / pgDn / home / end
            if coordinator?.model.navKeysMoveSelection == true {
                moveSelectionByPage(keyCode: event.keyCode)   // Everything-style: cursor moves
            } else {
                super.keyDown(with: event)                    // macOS default: scroll only
            }
        default:
            super.keyDown(with: event)   // arrows etc. → native selection movement
        }
    }

    /// Everything-style paging: PgUp/PgDn move the SELECTION by one visible page,
    /// Home/End jump it to the first/last row (macOS default only scrolls).
    private func moveSelectionByPage(keyCode: UInt16) {
        let n = numberOfRows
        guard n > 0 else { return }
        let cur = selectedRow
        let target: Int
        switch keyCode {
        case 115: target = 0                                  // Home
        case 119: target = n - 1                              // End
        default:
            guard let sv = enclosingScrollView else { return }
            let clip = sv.contentView
            let ins = clip.contentInsets
            var vis = clip.documentVisibleRect                // rows actually visible (minus header)
            vis.origin.y += ins.top
            vis.size.height -= ins.top + ins.bottom
            let page = max(1, rows(in: vis).length - 1)       // keep one row of overlap
            let base = max(0, cur)
            target = keyCode == 121 ? min(n - 1, base + page) : max(0, base - page)
        }
        if target != cur {
            selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        }
        scrollRowToVisible(target)                            // snap, edge-aligned
    }

    /// Snap-scroll (NO smooth animation) so the row lands EXACTLY flush with the
    /// viewport edge. AppKit's keyboard nav uses an animated scroll that can't keep
    /// up with fast auto-repeat — successive animations overlap, so the selection
    /// drifts off the bottom edge and leaves flicker/ghosting during a held key.
    /// Accounts for the clip view's content insets: the column header FLOATS over
    /// the inset region, so "top edge" is below the header (not under it).
    override func scrollRowToVisible(_ row: Int) {
        guard row >= 0, row < numberOfRows, let sv = enclosingScrollView else {
            super.scrollRowToVisible(row); return
        }
        let clip = sv.contentView
        let ins = clip.contentInsets                     // effective (incl. floating header)
        let rowRect = rect(ofRow: row)
        let visible = clip.documentVisibleRect
        let topEdge = visible.minY + ins.top             // first y NOT covered by the header
        let bottomEdge = visible.maxY - ins.bottom
        var y = visible.origin.y
        if rowRect.minY < topEdge { y = rowRect.minY - ins.top }                            // flush under the header
        else if rowRect.maxY > bottomEdge { y = rowRect.maxY - visible.height + ins.bottom } // flush to the bottom
        else { return }                                                                      // already fully visible
        let minY = -ins.top
        let maxY = max(minY, bounds.height - visible.height + ins.bottom)
        y = max(minY, min(y, maxY))
        clip.setBoundsOrigin(NSPoint(x: visible.origin.x, y: y))                             // direct = no animation
        sv.reflectScrolledClipView(clip)
        sv.flashScrollers()   // direct clip moves bypass the overlay-scroller reveal — show it like native scrolling
    }

    /// After a repeat step, re-assert the exact edge alignment (an in-flight smooth
    /// scroll from a previous step may have shifted the frame mid-animation).
    private func alignSelection(toBottom: Bool) {
        let row = selectedRow
        guard row >= 0 else { return }
        scrollRowToVisible(row)
        _ = toBottom   // both edges handled inside scrollRowToVisible
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 125, 126, 116, 121, 115, 119:   // nav key released → publish the final selection once
            coordinator?.endNavRepeat()
        default: break
        }
        super.keyUp(with: event)
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible { panel.orderOut(nil) }
        else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = qlSource; panel.delegate = qlSource
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

/// Caches "Kind" strings by extension (UTType lookup is not free).
enum KindCache {
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()
    static func kind(for path: String, isDir: Bool, isLink: Bool = false) -> String {
        if isLink { return "Alias" }
        let ext = (path as NSString).pathExtension.lowercased()
        if isDir {
            // A directory WITH an extension is a typed bundle — report Finder's kind
            // ("Bundle", "Framework", "Application"…) instead of a blanket "Folder".
            guard !ext.isEmpty else { return "Folder" }
            lock.lock(); defer { lock.unlock() }
            if let c = cache["d:" + ext] { return c }
            let k = UTType(filenameExtension: ext, conformingTo: .directory)?.localizedDescription
                ?? UTType(filenameExtension: ext)?.localizedDescription ?? "Folder"
            cache["d:" + ext] = k
            return k
        }
        if ext.isEmpty { return "Document" }
        lock.lock(); defer { lock.unlock() }
        if let c = cache[ext] { return c }
        let k = UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) file"
        cache[ext] = k
        return k
    }
}

/// AppKit view-based NSTableView wrapped for SwiftUI. SwiftUI's own Table/List
/// cannot handle these row counts; NSTableView recycles row views so cost is
/// fixed regardless of 10k vs 10M rows.
struct ResultsTableView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    struct ColumnSpec { let id, title, sortKey: String; let width: CGFloat; let right: Bool; let visible: Bool }
    static let columns: [ColumnSpec] = [
        .init(id: "name",    title: "Name",          sortKey: "name",    width: 260, right: false, visible: true),
        .init(id: "path",    title: "Path",          sortKey: "path",    width: 360, right: false, visible: true),
        .init(id: "ext",     title: "Extension",     sortKey: "name",    width: 90,  right: false, visible: false),
        .init(id: "kind",    title: "Kind",          sortKey: "name",    width: 130, right: false, visible: false),
        .init(id: "size",    title: "Size",          sortKey: "size",    width: 90,  right: true,  visible: true),
        .init(id: "date",    title: "Date Modified", sortKey: "date",    width: 150, right: false, visible: true),
        .init(id: "created", title: "Date Created",  sortKey: "created", width: 150, right: false, visible: false),
    ]
    static func columnVisible(_ id: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: "mv.col.\(id)") as? Bool ?? def
    }
    static func setColumnVisible(_ id: String, _ v: Bool) {
        UserDefaults.standard.set(v, forKey: "mv.col.\(id)")
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = MVTableView()
        table.qlSource = context.coordinator
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.registerForDraggedTypes([.fileURL])   // drop a folder onto the list → scope to it

        for col in Self.columns {
            addColumn(table, id: col.id, title: col.title, width: col.width,
                      sortKey: col.sortKey, right: col.right)
        }
        // apply persisted visibility (default per column)
        for col in Self.columns {
            if let c = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(col.id)) {
                c.isHidden = !Self.columnVisible(col.id, default: col.visible)
            }
        }
        // right-click the header to choose columns (Everything-style)
        table.headerView?.menu = context.coordinator.makeHeaderMenu()

        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        // Context menu (right-click)
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, key: String = "",
                 mask: NSEvent.ModifierFlags = []) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mask
            it.target = context.coordinator
            menu.addItem(it)
        }
        // NOTE: no "\r"/" " key equivalents here — while an NSMenu is open, a key
        // equivalent HIJACKS that key, so pressing Return on a highlighted item would
        // fire "Open" instead of the highlighted command (user-reported bug).
        add("Open", #selector(Coordinator.openItem))
        add("Open Enclosing Folder", #selector(Coordinator.openEnclosing))
        add("Quick Look", #selector(Coordinator.quickLook))
        add("Get Info", #selector(Coordinator.getInfo), key: "i", mask: [.command])
        menu.addItem(.separator())
        add("Search in This Folder", #selector(Coordinator.searchInFolder))
        add("Reveal in Finder", #selector(Coordinator.revealItem), key: "r", mask: [.command])
        // Tags submenu (Finder colors) — writes via URL resource values
        let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        tagsItem.submenu = context.coordinator.makeTagsMenu()
        menu.addItem(tagsItem)
        menu.addItem(.separator())
        add("Copy", #selector(Coordinator.copyFile), key: "c", mask: [.command])
        add("Copy as Pathname", #selector(Coordinator.copyPath), key: "c", mask: [.command, .option])
        add("Copy Name", #selector(Coordinator.copyName))
        menu.addItem(.separator())
        add("Move to Trash", #selector(Coordinator.moveToTrash),
            key: String(UnicodeScalar(NSDeleteCharacter)!), mask: [.command])
        table.menu = menu

        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // Returning from another layout: re-adopt the shared selection so arrows
        // continue from the same file (selection must SURVIVE layout switches).
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.restoreSelectionFromModel()
        }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.model = model
        if let tv = coord.tableView, tv.rowHeight != model.density.rowHeight {
            tv.rowHeight = model.density.rowHeight
            tv.reloadData()
        }
        // keep the header sort arrow in sync when sort is changed via the gear menu
        if let tv = coord.tableView {
            let key = coord.sortColumnKey(model.sortKey)
            let cur = tv.sortDescriptors.first
            if cur?.key != key || (key != nil && cur?.ascending != model.ascending) {
                tv.sortDescriptors = key.map { [NSSortDescriptor(key: $0, ascending: model.ascending)] } ?? []
            }
        }
        // ↓ from the search field moves focus into the list and selects a row
        if coord.lastFocusResultsNonce != model.focusResultsNonce {
            coord.lastFocusResultsNonce = model.focusResultsNonce
            if let tv = coord.tableView, !model.resultsStore.ids.isEmpty {
                tv.window?.makeFirstResponder(tv)
                if tv.selectedRow < 0 { tv.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                tv.scrollRowToVisible(max(0, tv.selectedRow))
            }
        }
        if coord.lastVersion != model.resultsVersion {
            coord.lastVersion = model.resultsVersion
            // Only a genuinely NEW query jumps to the top + drops selection. A live
            // FS refresh of the same query preserves the FULL (multi-)selection &
            // scroll (otherwise multi-select / arrow nav gets yanked away).
            let newQuery = coord.lastQueryNonce != model.queryNonce
            coord.lastQueryNonce = model.queryNonce
            let tv = coord.tableView
            let keep: Set<Int32> = newQuery ? []
                : Set((tv?.selectedRowIndexes ?? []).compactMap {
                    $0 < coord.renderedIDs.count ? coord.renderedIDs[$0] : nil })
            coord.renderedIDs = model.resultsStore.ids   // adopt the new result set
            tv?.reloadData()
            if newQuery {
                tv?.deselectAll(nil)   // reloadData keeps selection by position → drop it on a new query
                model.selectedID = nil; model.selectionCount = 0; model.selectionBytes = 0
                tv?.scrollRowToVisible(0)
            } else if !keep.isEmpty {
                var rows = IndexSet()
                for (i, id) in coord.renderedIDs.enumerated() {
                    if keep.contains(id) { rows.insert(i); if rows.count == keep.count { break } }
                }
                if rows.isEmpty {
                    // every previously-selected row vanished — reloadData would otherwise
                    // keep the OLD indices highlighted (now pointing at different files),
                    // and no selectionDidChange fires to refresh the model. Clear both.
                    tv?.deselectAll(nil)
                    model.selectedID = nil; model.selectionCount = 0; model.selectionBytes = 0
                } else {
                    tv?.selectRowIndexes(rows, byExtendingSelection: false)
                }
            }
            if QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible {
                p.reloadData()
            }
        }
    }

    private func addColumn(_ table: NSTableView, id: String, title: String,
                           width: CGFloat, sortKey: String, right: Bool = false) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = 40
        // Size/date columns sort DESCENDING on first click (Finder/Everything behavior):
        // ascending-first floods the top with 0-byte files and "--" folders, which reads
        // as "sorting is broken". Name/path stay ascending-first.
        let descFirst = ["size", "date", "created"].contains(sortKey)
        col.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: !descFirst)
        table.addTableColumn(col)
    }

    static let previewableExts: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "icns",
        "pdf", "mov", "mp4", "m4v", "avi", "mkv", "webm"]

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                             QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSTextFieldDelegate {
        var model: AppModel
        weak var tableView: NSTableView?
        var lastVersion = -1
        var lastQueryNonce = -1
        var lastFocusResultsNonce = 0

        func focusSearch() { model.focusNonce &+= 1 }
        private let byteFormatter: ByteCountFormatter = {
            let f = ByteCountFormatter(); f.countStyle = .file; return f
        }()
        private let dateFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
        }()

        init(model: AppModel) { self.model = model }

        // The table renders from this snapshot (not the live store) so selection
        // can be remapped across reloads.
        var renderedIDs: [Int32] = []
        private var ids: [Int32] { renderedIDs }

        func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

        // Drag a row out as a file URL → Finder/other apps copy (or move with ⌘).
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < ids.count else { return nil }
            return URL(fileURLWithPath: model.path(ids[row])) as NSURL
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .move]
        }

        // Drop a folder onto the list → scope the search to that folder.
        private func droppedFolder(_ info: NSDraggingInfo) -> String? {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return nil }
            for u in urls where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return u.path
            }
            return nil
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource == nil else { return [] }   // ignore our own row drags
            if droppedFolder(info) != nil { tableView.setDropRow(-1, dropOperation: .on); return .copy }
            return []
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let folder = droppedFolder(info) else { return false }
            model.searchInFolder(path: folder, isDir: true)
            return true
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < ids.count else { return nil }
            let id = ids[row]
            let colID = tableColumn.identifier.rawValue
            let cell = makeCell(tableView, colID: colID)
            let r = model.index.row(Int(id))   // one locked snapshot; never subscript arrays off-lock
            func date(_ ns: Int64) -> String {
                ns == 0 ? "--" : dateFormatter.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9))
            }
            switch colID {
            case "name":
                let hl = highlightedName(name: r.name)
                // Tag dots + bundle/symlink icons resolve off-thread on cache miss (no
                // getxattr / icon-services XPC on the main thread while arrow-hold scrolls
                // new rows); when they land, the coordinator re-renders the row — deferred
                // while a nav key is held so it can't flicker under the moving selection.
                let refreshName: () -> Void = { [weak self] in self?.requestNameRefresh(row: row) }
                let dots = TagCache.dots(forPath: r.path, onReady: refreshName)   // Finder color tags
                if hl == nil, dots == nil {
                    cell.textField?.stringValue = r.name
                } else {
                    let base = NSMutableAttributedString(attributedString: hl ?? NSAttributedString(string: r.name))
                    if let dots { base.append(dots) }
                    cell.textField?.attributedStringValue = base
                }
                // Finder's "Show icon preview": tiny QL thumbnails for media rows
                // (Everything's Details view shows only icons — this one's for Finder
                // muscle memory). Cached sync peek; miss = icon now, refresh when ready.
                var rowIcon = IconCache.icon(for: r.path, isDir: r.isDir,
                                             isLink: r.isLink, onReady: refreshName)
                if model.iconPreview, !r.isDir, ResultsTableView.previewableExts.contains(r.ext.lowercased()) {
                    if let t = ThumbCache.shared.cachedSync(for: r.path, side: 32) {
                        rowIcon = t
                    } else {
                        ThumbCache.shared.prefetch(for: r.path, side: 32, onReady: refreshName)
                    }
                }
                cell.imageView?.image = rowIcon
            case "kind":
                cell.textField?.stringValue = KindCache.kind(for: r.path, isDir: r.isDir, isLink: r.isLink)
                cell.textField?.textColor = .secondaryLabelColor
            case "ext":
                cell.textField?.stringValue = r.ext
                cell.textField?.textColor = .secondaryLabelColor
            case "created":
                cell.textField?.stringValue = date(r.crtime)
                cell.textField?.textColor = .secondaryLabelColor
            case "path":
                if let attr = highlightedDirectory(r.directory) {
                    cell.textField?.attributedStringValue = attr   // path-scope matches emphasized
                } else {
                    cell.textField?.stringValue = r.directory
                    cell.textField?.textColor = .secondaryLabelColor
                }
            case "size":
                if r.isDir {
                    let reloadSize: () -> Void = { [weak tableView] in
                        guard let tv = tableView else { return }
                        let col = tv.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
                        if col >= 0, row < tv.numberOfRows {
                            tv.reloadData(forRowIndexes: IndexSet(integer: row),
                                          columnIndexes: IndexSet(integer: col))
                        }
                    }
                    if model.indexFolderSizes {
                        // Everything 1.5-style: EVERY folder shows its live subtree total,
                        // O(1) from the mutationGen-keyed cache (built off-main on miss).
                        if let bytes = model.index.folderSizeIfReady(Int(id)) {
                            cell.textField?.stringValue = byteFormatter.string(fromByteCount: bytes)
                        } else {
                            cell.textField?.stringValue = "…"
                            let idx = model.index
                            DispatchQueue.global(qos: .utility).async {
                                idx.buildFolderSizes()
                                DispatchQueue.main.async { reloadSize() }
                            }
                        }
                    } else if !r.ext.isEmpty {   // packages only (legacy per-bundle path)
                        if let bytes = BundleSizeCache.size(path: r.path, dirIdx: id, index: model.index,
                                                            onReady: reloadSize) {
                            cell.textField?.stringValue = byteFormatter.string(fromByteCount: bytes)
                        } else {
                            cell.textField?.stringValue = "…"
                        }
                    } else {
                        cell.textField?.stringValue = "--"
                    }
                } else {
                    cell.textField?.stringValue = byteFormatter.string(fromByteCount: r.size)
                }
                cell.textField?.alignment = .right
                cell.textField?.textColor = .secondaryLabelColor
            case "date":
                cell.textField?.stringValue = date(r.mtime)
                cell.textField?.textColor = .secondaryLabelColor
            default:
                cell.textField?.stringValue = ""
            }
            return cell
        }

        /// Terms to emphasize in the Path column: explicit `path:` tokens always, and
        /// plain terms when the global scope is full-path (⌃U). Exact mode only.
        private func pathHighlightTerms() -> [String] {
            guard model.matchMode == .exact else { return [] }
            let q = model.query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return [] }
            var out: [String] = []
            for tRaw in q.replacingOccurrences(of: "\"", with: "").split(separator: " ").map(String.init) {
                if tRaw.hasPrefix("-") || tRaw.hasPrefix("!") { continue }        // negations exclude, don't match
                if tRaw.contains("*") || tRaw.contains("?") || tRaw.isEmpty { continue }
                if tRaw.lowercased().hasPrefix("path:") {
                    let b = String(tRaw.dropFirst(5))
                    if !b.isEmpty { out.append(b) }
                } else if model.scope == .fullPath, !tRaw.contains(":") {
                    out.append(tRaw)
                }
            }
            return out
        }

        /// Accent+bold emphasis of matched terms inside the Path column (same style as
        /// the name highlight, over the secondary-colored path text). nil = plain render.
        private func highlightedDirectory(_ dir: String) -> NSAttributedString? {
            let terms = pathHighlightTerms()
            guard !terms.isEmpty else { return nil }
            let attr = NSMutableAttributedString(string: dir, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12),
            ])
            let hl: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.boldSystemFont(ofSize: 12),
            ]
            var found = false
            for term in terms {
                var range = dir.startIndex..<dir.endIndex
                while let r = dir.range(of: term, options: .caseInsensitive, range: range) {
                    found = true
                    attr.addAttributes(hl, range: NSRange(r, in: dir))
                    range = r.upperBound..<dir.endIndex
                }
            }
            return found ? attr : nil
        }

        /// Highlight the matched part of the filename (exact substring or fuzzy
        /// subsequence). Returns nil to render plain text.
        private func highlightedName(name: String) -> NSAttributedString? {
            let q = model.query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return nil }
            let attr = NSMutableAttributedString(string: name)
            let hl: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.boldSystemFont(ofSize: 12),
            ]
            switch model.matchMode {
            case .exact:
                // Highlight EVERY plain term of a multi-term query (skip filters like ext:,
                // negations, and glob chars) — previously any space/filter disabled it.
                let terms = q.replacingOccurrences(of: "\"", with: "")
                    .split(separator: " ").map(String.init)
                    .filter { !$0.contains(":") && !$0.hasPrefix("-") && !$0.hasPrefix("!")
                              && !$0.contains("*") && !$0.contains("?") && !$0.isEmpty }
                guard !terms.isEmpty else { return nil }
                var found = false
                for term in terms {
                    var range = name.startIndex..<name.endIndex
                    while let r = name.range(of: term, options: .caseInsensitive, range: range) {
                        found = true
                        attr.addAttributes(hl, range: NSRange(r, in: name))
                        range = r.upperBound..<name.endIndex
                    }
                }
                return found ? attr : nil
            case .fuzzy:
                let lowerQ = Array(q.lowercased())
                var qi = 0
                var s = name.startIndex
                while s < name.endIndex && qi < lowerQ.count {
                    if String(name[s]).lowercased().first == lowerQ[qi] {
                        attr.addAttributes(hl, range: NSRange(s..<name.index(after: s), in: name))
                        qi += 1
                    }
                    s = name.index(after: s)
                }
                return qi == lowerQ.count ? attr : nil
            default:
                return nil   // wildcard / regex: no inline highlight
            }
        }

        private func makeCell(_ tableView: NSTableView, colID: String) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier(colID)
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                // reset overridable attrs (incl. any leftover rename-edit state)
                let tf = reused.textField
                tf?.textColor = .labelColor; tf?.alignment = .left
                tf?.isEditable = false; tf?.isSelectable = false
                tf?.isBordered = false; tf?.drawsBackground = false
                return reused
            }
            let cell = NSTableCellView()
            cell.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            if colID == "name" {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(iv); cell.imageView = iv
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 15),
                    iv.heightAnchor.constraint(equalToConstant: 15),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            } else {
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            return cell
        }

        private var pendingBytesWork: DispatchWorkItem?
        private var selectionToken = 0
        private var selectionPublishPending = false
        private var navRepeatActive = false
        private var navRepeatFallback: DispatchWorkItem?
        private var deferredNameRefreshRows = IndexSet()

        /// A nav key is auto-repeating: stop mirroring selection into the model entirely
        /// (each publish is a SwiftUI transaction between native selection steps — the
        /// hold jank). keyUp publishes once; a quiet-gap fallback covers a lost keyUp
        /// (e.g. focus change mid-hold).
        func beginNavRepeat() {
            navRepeatActive = true
            navRepeatFallback?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.endNavRepeat() }
            navRepeatFallback = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        }

        func endNavRepeat() {
            navRepeatFallback?.cancel(); navRepeatFallback = nil
            guard navRepeatActive else { return }
            navRepeatActive = false
            if let tv = tableView {
                flushDeferredNameRefreshes(tv)
                publishSelection(tv)
            }
        }

        /// Async cell payloads (tag dots, bundle/symlink icons) request a row re-render
        /// when they land. Mid-hold, those single-row reloads read as flicker under the
        /// moving selection — so during a repeat run they're queued and flushed once the
        /// key is released.
        func requestNameRefresh(row: Int) {
            if navRepeatActive { deferredNameRefreshRows.insert(row); return }
            guard let tv = tableView else { return }
            reloadNameColumn(tv, rows: IndexSet(integer: row))
        }

        private func flushDeferredNameRefreshes(_ tv: NSTableView) {
            guard !deferredNameRefreshRows.isEmpty else { return }
            let valid = IndexSet(deferredNameRefreshRows.filter { $0 < tv.numberOfRows })
            deferredNameRefreshRows.removeAll()
            reloadNameColumn(tv, rows: valid)
        }

        private func reloadNameColumn(_ tv: NSTableView, rows: IndexSet) {
            guard !rows.isEmpty else { return }
            let col = tv.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            if col >= 0 { tv.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: col)) }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            // AppKit calls this SYNCHRONOUSLY inside keyDown. During a held-key repeat run
            // we suppress publishing wholesale (see beginNavRepeat) — the visible selection
            // is native NSTableView state and needs no model mirror to move smoothly.
            if navRepeatActive { return }
            // Otherwise coalesce to one publish per runloop tick (mouse drags, programmatic
            // multi-select changes) so a burst still collapses.
            if selectionPublishPending { return }
            selectionPublishPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let tv = self.tableView else { return }
                self.selectionPublishPending = false
                self.publishSelection(tv)
            }
        }

        /// Mirror the table's current selection into the model (coalesced — reads the
        /// LATEST selection when it runs, so a burst of arrow repeats collapses to one).
        private func publishSelection(_ tv: NSTableView) {
            let row = tv.selectedRow
            model.selectedID = (row >= 0 && row < ids.count) ? ids[row] : nil
            let rows = tv.selectedRowIndexes
            model.selectionCount = rows.count
            // Byte total (shown only for multi-selection) is summed off the main thread,
            // token-guarded so a slower older sum can't overwrite a newer selection.
            pendingBytesWork?.cancel()
            selectionToken &+= 1
            let token = selectionToken
            if rows.count > 1 {
                let idSnapshot = rows.compactMap { $0 < ids.count ? ids[$0] : nil }
                let index = model.index
                let work = DispatchWorkItem { [weak self] in
                    let bytes = index.totalSize(of: idSnapshot)
                    DispatchQueue.main.async {
                        guard let self, self.selectionToken == token else { return }
                        self.model.selectionBytes = bytes
                    }
                }
                pendingBytesWork = work
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1, execute: work)
            } else {
                model.selectionBytes = 0
            }
            if QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible {
                p.reloadData()
            }
        }

        // MARK: - column chooser (right-click the header)

        func makeHeaderMenu() -> NSMenu {
            let menu = NSMenu()
            for col in ResultsTableView.columns where col.id != "name" {   // Name always shown
                let item = NSMenuItem(title: col.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = col.id
                item.state = ResultsTableView.columnVisible(col.id, default: col.visible) ? .on : .off
                menu.addItem(item)
            }
            return menu
        }

        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let tv = tableView,
                  let c = tv.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
            let nowVisible = c.isHidden          // was hidden → make visible
            c.isHidden = !nowVisible
            ResultsTableView.setColumnVisible(id, nowVisible)
            sender.state = nowVisible ? .on : .off
        }

        func rowForID(_ id: Int32) -> Int? {
            let arr = ids
            for i in 0..<arr.count where arr[i] == id { return i }
            return nil
        }

        // MARK: - Quick Look (Space)

        private func selectedURLs() -> [URL] {
            guard let tv = tableView else { return [] }
            var rows = tv.selectedRowIndexes
            if rows.isEmpty, tv.clickedRow >= 0 { rows = IndexSet(integer: tv.clickedRow) }
            return rows.compactMap { $0 < ids.count ? URL(fileURLWithPath: model.path(ids[$0])) : nil }
        }

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs().count }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            let urls = selectedURLs()
            return index < urls.count ? urls[index] as NSURL : nil
        }
        // forward arrow keys to the table so selection (and the preview) moves while QL is open
        func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
            if event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) {
                tableView?.keyDown(with: event)
                return true
            }
            return false
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let sd = tableView.sortDescriptors.first, let key = sd.key else { return }
            let mapped: SortKey
            switch key {
            case "name": mapped = .name
            case "path": mapped = .path
            case "size": mapped = .size
            case "date": mapped = .dateModified
            case "created": mapped = .dateCreated
            default: mapped = .name
            }
            // guard prevents a feedback loop when we set sortDescriptors programmatically below
            if model.sortKey != mapped { model.sortKey = mapped }
            if model.ascending != sd.ascending { model.ascending = sd.ascending }
        }

        /// Column identifier that shows the sort arrow for a given SortKey (nil = none, e.g. relevance).
        func sortColumnKey(_ k: SortKey) -> String? {
            switch k {
            case .name: return "name";  case .path: return "path";  case .size: return "size"
            case .dateModified: return "date"; case .dateCreated: return "created"; case .relevance: return nil
            }
        }

        // MARK: - Actions

        func restoreSelectionFromModel() {
            guard let tv = tableView, let sel = model.selectedID,
                  let row = ids.firstIndex(of: sel) else { return }
            tv.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tv.scrollRowToVisible(row)
            tv.window?.makeFirstResponder(tv)   // arrows work immediately
        }

        private func selectedPaths() -> [String] {
            guard let tv = tableView else { return [] }
            var rows = tv.selectedRowIndexes
            if rows.isEmpty, tv.clickedRow >= 0 { rows = IndexSet(integer: tv.clickedRow) }
            return rows.compactMap { $0 < ids.count ? model.path(ids[$0]) : nil }
        }

        @objc func doubleClicked() { openItem() }

        @objc func openItem() {
            let paths = selectedPaths()
            if !paths.isEmpty { model.recordRecentQuery(model.query) }
            for p in paths { AppModel.finderOpen(p) }
        }

        @objc func revealItem() {
            let urls = selectedPaths().map { URL(fileURLWithPath: $0) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        @objc func copyPath() {
            let joined = selectedPaths().joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
        }

        @objc func copyName() {
            let names = selectedPaths().map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names, forType: .string)
        }

        @objc func copyFile() {   // copy the actual file(s) so they can be pasted in Finder
            let urls = selectedPaths().map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls)
        }

        @objc func openEnclosing() {
            // Open the parent folder WITH the file selected (Finder semantics) —
            // just opening the folder leaves the user hunting for the row's file.
            let urls = selectedPaths().map { URL(fileURLWithPath: $0) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        @objc func searchInFolder() {
            guard let tv = tableView, tv.selectedRow >= 0, tv.selectedRow < ids.count else { return }
            let r = model.index.row(Int(ids[tv.selectedRow]))
            model.searchInFolder(path: r.path, isDir: r.isDir)
        }

        /// ⌘I → open Finder's Get Info window(s) for the selection (same as Finder,
        /// so bundle size, tags, permissions all show natively). Uses Apple Events.
        @objc func getInfo() {
            let paths = selectedPaths()
            guard !paths.isEmpty else { return }
            let refs = paths.map { p -> String in
                let esc = p.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                return "POSIX file \"\(esc)\""
            }.joined(separator: ", ")
            let src = """
            tell application "Finder"
              activate
              repeat with theItem in {\(refs)}
                open information window of (theItem as alias)
              end repeat
            end tell
            """
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if let err { NSSound.beep(); NSLog("Get Info failed: \(err)") }
        }

        // MARK: - Finder tags

        private static let tagColors: [(String, String?)] = [   // (title, tag name / nil = clear)
            ("None", nil), ("Red", "Red"), ("Orange", "Orange"), ("Yellow", "Yellow"),
            ("Green", "Green"), ("Blue", "Blue"), ("Purple", "Purple"), ("Gray", "Gray"),
        ]

        /// Finder-identical Tags submenu: each color item carries a filled color-dot
        /// image, the items show LIVE checkmarks for the clicked file's current tags,
        /// and clicking TOGGLES that tag (multi-tag capable) — exactly like Finder.
        func makeTagsMenu() -> NSMenu {
            let m = NSMenu()
            m.autoenablesItems = false
            m.delegate = self          // rebuilt on open so checkmarks reflect the file
            return m
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let current = selectedPaths().first.map { Set(SearchEngine.xattrTagNames(path: $0)) } ?? []
            for (title, tag) in Self.tagColors where tag != nil {
                let it = NSMenuItem(title: title, action: #selector(toggleTagItem(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = tag
                it.image = Self.tagDotImage(for: title)
                it.state = current.contains(title.lowercased()) ? .on : .off
                menu.addItem(it)
            }
            menu.addItem(.separator())
            let none = NSMenuItem(title: "Remove All Tags", action: #selector(removeAllTags(_:)), keyEquivalent: "")
            none.target = self
            none.image = Self.tagDotImage(for: nil)
            menu.addItem(none)
        }

        /// Finder-style 14pt color swatch: filled circle with a hairline ring;
        /// nil = the empty "no tag" outline circle.
        static func tagDotImage(for title: String?) -> NSImage {
            let d: CGFloat = 14
            let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
                let inset = rect.insetBy(dx: 1.5, dy: 1.5)
                let path = NSBezierPath(ovalIn: inset)
                if let title, let c = Self.tagNSColor(title) {
                    c.setFill(); path.fill()
                    NSColor.black.withAlphaComponent(0.15).setStroke()
                } else {
                    NSColor.tertiaryLabelColor.setStroke()
                }
                path.lineWidth = 1; path.stroke()
                return true
            }
            img.isTemplate = false
            return img
        }

        static func tagNSColor(_ title: String) -> NSColor? {
            switch title {
            case "Red": return .systemRed;       case "Orange": return .systemOrange
            case "Yellow": return .systemYellow; case "Green": return .systemGreen
            case "Blue": return .systemBlue;     case "Purple": return .systemPurple
            case "Gray": return .systemGray;     default: return nil
            }
        }

        // Finder's standard tag color codes (as stored in _kMDItemUserTags: "Name\nCode").
        private func colorCode(_ tag: String) -> String? {
            switch tag {
            case "Gray": return "1"; case "Green": return "2"; case "Purple": return "3"
            case "Blue": return "4"; case "Yellow": return "5"; case "Red": return "6"
            case "Orange": return "7"; default: return nil
            }
        }

        @objc private func toggleTagItem(_ sender: NSMenuItem) {
            guard let tag = sender.representedObject as? String else { return }
            for p in selectedPaths() { toggleTag(tag, at: p); TagCache.invalidate(p) }
            refreshNameCells()
        }

        @objc private func removeAllTags(_ sender: NSMenuItem) {
            let name = "com.apple.metadata:_kMDItemUserTags"
            for p in selectedPaths() { removexattr(p, name, 0); TagCache.invalidate(p) }
            refreshNameCells()
        }

        private func refreshNameCells() {
            guard let tv = tableView else { return }
            let col = tv.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            if col >= 0 {
                tv.reloadData(forRowIndexes: tv.selectedRowIndexes, columnIndexes: IndexSet(integer: col))
            }
        }

        /// Add the tag if absent, remove it if present (Finder semantics), preserving
        /// the file's OTHER tags. Writes the full "Name\nCode" array back to the xattr.
        private func toggleTag(_ tag: String, at path: String) {
            let name = "com.apple.metadata:_kMDItemUserTags"
            var tags = SearchEngine.xattrTagNames(path: path)   // lowercased names
            let want = tag.lowercased()
            if tags.contains(want) { tags.removeAll { $0 == want } }
            else { tags.append(want) }
            if tags.isEmpty { removexattr(path, name, 0); return }
            // rebuild with canonical capitalization + color codes where known
            let values: [String] = tags.map { t in
                let cap = t.prefix(1).uppercased() + t.dropFirst()
                return colorCode(cap).map { "\(cap)\n\($0)" } ?? cap
            }
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: values, format: .binary, options: 0) else { return }
            if data.withUnsafeBytes({ setxattr(path, name, $0.baseAddress, $0.count, 0, 0) }) != 0 {
                NSSound.beep()
            }
        }

        @objc func quickLook() { (tableView as? MVTableView)?.toggleQuickLook() }

        // MARK: - inline rename (F2 / configurable Enter)

        private var renamingID: Int32?
        func beginRename() {
            guard let tv = tableView, tv.selectedRow >= 0, tv.selectedRow < ids.count else { return }
            let row = tv.selectedRow
            let col = tv.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            guard col >= 0,
                  let cell = tv.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let tf = cell.textField else { return }
            renamingID = ids[row]
            tf.stringValue = model.name(ids[row])   // drop any match-highlight so the editor shows plain text
            tf.textColor = .labelColor; tf.font = .systemFont(ofSize: 12)
            tf.isEditable = true; tf.isSelectable = true; tf.isBordered = true
            tf.drawsBackground = true; tf.backgroundColor = .textBackgroundColor
            tf.delegate = self
            tv.window?.makeFirstResponder(tf)
            if let editor = tf.currentEditor() {   // select basename (like Finder)
                let base = (tf.stringValue as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField, let id = renamingID else { return }
            renamingID = nil
            tf.isEditable = false; tf.isSelectable = false; tf.isBordered = false; tf.drawsBackground = false
            let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldPath = model.path(Int32(id))
            let oldName = (oldPath as NSString).lastPathComponent
            guard !newName.isEmpty, newName != oldName, !newName.contains("/") else {
                tf.stringValue = oldName; return
            }
            let newPath = ((oldPath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(newName)
            do { try FileManager.default.moveItem(atPath: oldPath, toPath: newPath) }
            catch { NSSound.beep(); tf.stringValue = oldName }
            // the FSEvents watcher reconciles the rename into the index shortly
        }

        @objc func moveToTrash() {
            for p in selectedPaths() {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
            }
            // FSEvents will reconcile the removals into the index shortly.
        }
    }
}

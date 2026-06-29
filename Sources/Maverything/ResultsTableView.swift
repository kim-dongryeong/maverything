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
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.command, .option], event.keyCode == 8 {   // ⌘⌥C → copy path
            coordinator?.copyPath(); return
        }
        if mods == [.command], event.keyCode == 15 {           // ⌘R → reveal in Finder
            coordinator?.revealItem(); return
        }
        switch event.keyCode {
        case 49:            // space → toggle Quick Look
            toggleQuickLook()
        case 36, 76:        // return / enter → open
            coordinator?.openItem()
        case 126:           // up arrow at the top → hand focus back to the search field
            if selectedRow <= 0 { coordinator?.focusSearch() } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)   // arrows etc. → native selection movement
        }
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
    static func kind(for path: String, isDir: Bool) -> String {
        if isDir { return "Folder" }
        let ext = (path as NSString).pathExtension.lowercased()
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
        add("Open", #selector(Coordinator.openItem), key: "\r")
        add("Open Enclosing Folder", #selector(Coordinator.openEnclosing))
        add("Quick Look", #selector(Coordinator.quickLook), key: " ")
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(Coordinator.revealItem), key: "r", mask: [.command])
        menu.addItem(.separator())
        add("Copy Path", #selector(Coordinator.copyPath), key: "c", mask: [.command, .option])
        add("Copy Name", #selector(Coordinator.copyName))
        add("Copy File", #selector(Coordinator.copyFile))
        table.menu = menu

        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.model = model
        if let tv = coord.tableView, tv.rowHeight != model.density.rowHeight {
            tv.rowHeight = model.density.rowHeight
            tv.reloadData()
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
            // FS refresh of the same query preserves the user's selection & scroll
            // (otherwise arrow-key navigation gets yanked back to the top).
            let newQuery = coord.lastQueryNonce != model.queryNonce
            coord.lastQueryNonce = model.queryNonce
            let keepID: Int32? = newQuery ? nil : model.selectedID
            coord.tableView?.reloadData()
            if newQuery {
                coord.tableView?.scrollRowToVisible(0)
            } else if let kid = keepID, let row = coord.rowForID(kid) {
                coord.tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
        col.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true)
        table.addTableColumn(col)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                             QLPreviewPanelDataSource, QLPreviewPanelDelegate {
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

        private var ids: [Int32] { model.resultsStore.ids }

        func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < ids.count else { return nil }
            let id = ids[row]
            let colID = tableColumn.identifier.rawValue
            let cell = makeCell(tableView, colID: colID)
            switch colID {
            case "name":
                cell.textField?.stringValue = model.name(id)
                cell.imageView?.image = IconCache.icon(for: model.path(id))
            case "kind":
                cell.textField?.stringValue = KindCache.kind(for: model.path(id),
                                                              isDir: model.index.isDir(Int(id)))
                cell.textField?.textColor = .secondaryLabelColor
            case "ext":
                cell.textField?.stringValue = (model.name(id) as NSString).pathExtension
                cell.textField?.textColor = .secondaryLabelColor
            case "created":
                let ns = model.index.crtime[Int(id)]
                cell.textField?.stringValue = ns == 0 ? "--"
                    : dateFormatter.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9))
                cell.textField?.textColor = .secondaryLabelColor
            case "path":
                cell.textField?.stringValue = model.directory(id)
                cell.textField?.textColor = .secondaryLabelColor
            case "size":
                let i = Int(id)
                cell.textField?.stringValue = model.index.isDir(i)
                    ? "--" : byteFormatter.string(fromByteCount: model.index.size[i])
                cell.textField?.alignment = .right
                cell.textField?.textColor = .secondaryLabelColor
            case "date":
                let ns = model.index.mtime[Int(id)]
                cell.textField?.stringValue = ns == 0 ? "--"
                    : dateFormatter.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9))
                cell.textField?.textColor = .secondaryLabelColor
            default:
                cell.textField?.stringValue = ""
            }
            return cell
        }

        private func makeCell(_ tableView: NSTableView, colID: String) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier(colID)
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                // reset overridable attrs
                reused.textField?.textColor = .labelColor
                reused.textField?.alignment = .left
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

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = tableView else { return }
            let row = tv.selectedRow
            model.selectedID = (row >= 0 && row < ids.count) ? ids[row] : nil
            // keep an open Quick Look in sync as the selection moves (Finder-style)
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
            model.sortKey = mapped
            model.ascending = sd.ascending
        }

        // MARK: - Actions

        private func selectedPaths() -> [String] {
            guard let tv = tableView else { return [] }
            var rows = tv.selectedRowIndexes
            if rows.isEmpty, tv.clickedRow >= 0 { rows = IndexSet(integer: tv.clickedRow) }
            return rows.compactMap { $0 < ids.count ? model.path(ids[$0]) : nil }
        }

        @objc func doubleClicked() { openItem() }

        @objc func openItem() {
            for p in selectedPaths() { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
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
            let dirs = Set(selectedPaths().map { ($0 as NSString).deletingLastPathComponent })
            for d in dirs { NSWorkspace.shared.open(URL(fileURLWithPath: d)) }
        }

        @objc func quickLook() { (tableView as? MVTableView)?.toggleQuickLook() }
    }
}

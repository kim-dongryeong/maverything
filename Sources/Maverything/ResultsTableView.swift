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

        addColumn(table, id: "name", title: "Name", width: 280, sortKey: "name")
        addColumn(table, id: "path", title: "Path", width: 380, sortKey: "path")
        addColumn(table, id: "kind", title: "Kind", width: 130, sortKey: "name")
        addColumn(table, id: "size", title: "Size", width: 90, sortKey: "size", right: true)
        addColumn(table, id: "date", title: "Date Modified", width: 160, sortKey: "date")

        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        // Context menu
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(Coordinator.openItem), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(Coordinator.revealItem), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path", action: #selector(Coordinator.copyPath), keyEquivalent: "")
        menu.items.forEach { $0.target = context.coordinator }
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
    }
}

import AppKit
import MaverythingCore
import SwiftUI

/// AppKit view-based NSTableView wrapped for SwiftUI. SwiftUI's own Table/List
/// cannot handle these row counts; NSTableView recycles row views so cost is
/// fixed regardless of 10k vs 10M rows.
struct ResultsTableView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
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
        addColumn(table, id: "path", title: "Path", width: 420, sortKey: "path")
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
        if coord.lastVersion != model.resultsVersion {
            coord.lastVersion = model.resultsVersion
            coord.tableView?.reloadData()
            coord.tableView?.scrollRowToVisible(0)
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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: AppModel
        weak var tableView: NSTableView?
        var lastVersion = -1
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
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = tableView else { return }
            let row = tv.selectedRow
            model.selectedID = (row >= 0 && row < ids.count) ? ids[row] : nil
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

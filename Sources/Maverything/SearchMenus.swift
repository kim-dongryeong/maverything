import SwiftUI

/// Clock button: recent searches the user committed (Enter / opened a result).
struct HistoryMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu {
            if model.recentQueries.isEmpty {
                Text("No recent searches")
            } else {
                ForEach(model.recentQueries, id: \.self) { q in
                    Button(q) { model.applyQuery(q) }
                }
                Divider()
                Button("Clear History") { model.clearRecents() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent searches")
    }
}

/// Bookmark button: save the current query+filters, recall or delete saved ones.
struct BookmarksMenu: View {
    @ObservedObject var model: AppModel
    @State private var showSave = false
    @State private var newName = ""

    private var canSave: Bool {
        !model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.typeFilter != .all
    }

    var body: some View {
        Menu {
            Button("Save Current Search…") { newName = defaultName(); showSave = true }
                .disabled(!canSave)
            if !model.savedSearches.isEmpty {
                Divider()
                ForEach(model.savedSearches) { s in
                    Button { model.applySaved(s) } label: { Text(s.name) }
                }
                Divider()
                Menu("Delete") {
                    ForEach(model.savedSearches) { s in
                        Button(s.name) { model.deleteSaved(s) }
                    }
                }
            }
        } label: {
            Image(systemName: model.savedSearches.isEmpty ? "bookmark" : "bookmark.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Saved searches")
        .alert("Save Search", isPresented: $showSave) {
            TextField("Name", text: $newName)
            Button("Save") { model.saveCurrentSearch(name: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save the current query and filters as a named search.")
        }
    }

    private func defaultName() -> String {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.typeFilter.label : q
    }
}

/// A "?" button that pops a compact cheat-sheet of the query syntax.
struct SyntaxHelpButton: View {
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Search syntax")
        .popover(isPresented: $show, arrowEdge: .bottom) { SyntaxHelpView() }
    }
}

struct SyntaxHelpView: View {
    private let rows: [(String, String)] = [
        ("report",           "substring match on the name"),
        ("app swift",        "AND — both terms must match"),
        ("report -png",      "exclude terms with - (or !)"),
        ("\"exact phrase\"", "quote to keep spaces together"),
        ("ext:png,jpg",      "one of these extensions"),
        ("size:>10mb",       "size >, <, >=, <= (kb/mb/gb)"),
        ("dm:today",         "modified: today / week / month / 2026-01-31"),
        ("folder:  /  file:", "only folders / only files"),
        ("path:src",         "match against the full path"),
        ("name:data",        "match the name even in path mode"),
        ("case:on",          "make the whole query case-sensitive"),
        ("ww:",              "match whole words only (report ≠ reporting)"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search syntax").font(.headline)
            Text("Combine freely — e.g. \(Text("photo ext:jpg dm:week size:>1mb").font(.system(.caption, design: .monospaced)))")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(rows, id: \.0) { r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(r.0)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 150, alignment: .leading)
                    Text(r.1).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Tip: ⌃U toggles searching the whole path. Use the chips above for quick type filters.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 430)
    }
}

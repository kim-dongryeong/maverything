import MaverythingCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            layoutBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .background(shortcuts)
        .preferredColorScheme(model.appearance.colorScheme)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusNonce) { searchFocused = true }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView().environmentObject(model)
        }
    }

    @ViewBuilder private var layoutBody: some View {
        switch model.layout {
        case .table:
            ResultsTableView(model: model)
        case .twoPane:
            HSplitView {
                ResultsTableView(model: model).frame(minWidth: 360)
                PreviewPane(model: model).frame(minWidth: 240, idealWidth: 320)
            }
        case .compact:
            CompactResults(model: model)
        }
    }

    // hidden keyboard shortcuts: ⌃U scope toggle, ⌘1/2/3 layout switch
    private var shortcuts: some View {
        Group {
            Button("") { model.toggleScope() }.keyboardShortcut("u", modifiers: .control)
            Button("") { model.layout = .table }.keyboardShortcut("1", modifiers: .command)
            Button("") { model.layout = .compact }.keyboardShortcut("2", modifiers: .command)
            Button("") { model.layout = .twoPane }.keyboardShortcut("3", modifiers: .command)
        }.hidden()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)

            TextField("Search every file…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
                .onExitCommand {                         // ESC: clear, then dismiss
                    if model.query.isEmpty { model.requestHide?() } else { model.query = "" }
                }

            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }

            Picker("", selection: $model.matchMode) {
                ForEach(MatchMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .help("Matching mode — build-all-variants: Exact / Fuzzy / Wildcard")

            gearMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var gearMenu: some View {
        Menu {
            Picker("Layout", selection: $model.layout) {
                ForEach(UILayout.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            Picker("Appearance", selection: $model.appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            Picker("Density", selection: $model.density) {
                ForEach(RowDensity.allCases) { Text($0.label).tag($0) }
            }
            Picker("Scope", selection: $model.scope) {
                Text("Name only").tag(SearchScope.nameOnly)
                Text("Full path  (⌃U)").tag(SearchScope.fullPath)
            }
            Picker("Sort by", selection: $model.sortKey) {
                Text("Name").tag(SortKey.name)
                Text("Path").tag(SortKey.path)
                Text("Size").tag(SortKey.size)
                Text("Date Modified").tag(SortKey.dateModified)
                Text("Relevance").tag(SortKey.relevance)
            }
            Toggle("Ascending", isOn: $model.ascending)
            Divider()
            Toggle("Include cloud storage (Google Drive, iCloud…)", isOn: Binding(
                get: { model.includeCloud },
                set: { model.setIncludeCloud($0) }))
            Button("Reindex Now") { model.reindex() }
            Divider()
            if model.hasFullDiskAccess {
                Label("Full Disk Access granted", systemImage: "checkmark.seal")
            } else {
                Button("Grant Full Disk Access…") { model.showOnboarding = true }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isIndexing {
                ProgressView().controlSize(.small)
                Text(model.statusText)
            } else {
                Text("\(model.resultTotal.formatted()) results")
                Text("·").foregroundStyle(.tertiary)
                Text("\(model.indexedCount.formatted()) indexed").foregroundStyle(.secondary)
                if !model.hasFullDiskAccess {
                    Text("· limited (no Full Disk Access)").foregroundStyle(.orange)
                }
            }
            Spacer()
            if !model.isIndexing {
                Text(String(format: "%.1f ms", model.queryMillis))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

import MaverythingCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            FilterBar(model: model)
            Divider()
            layoutBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
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

    // (⌃U/⌃B/⌃I/⌃R and ⌘1/2/3 now live in the REAL menu bar — SearchCommands /
    // ViewCommands in MaverythingApp — the canonical macOS home for shortcuts.)

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)

            TextField("Search every file…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .frame(maxWidth: .infinity)           // absorb slack so controls don't overlap
                .focused($searchFocused)
                .onKeyPress(phases: .down) { press in     // ⌘↑/⌘↓ cycle history; plain ↓ enters results
                    if press.modifiers.contains(.command) {
                        if press.key == .upArrow { model.cycleHistory(older: true); return .handled }
                        if press.key == .downArrow { model.cycleHistory(older: false); return .handled }
                        return .ignored
                    }
                    if press.key == .downArrow { model.focusResultsNonce &+= 1; return .handled }
                    return .ignored
                }
                .onSubmit {                               // Enter: remember the query, jump to results
                    model.recordRecentQuery(model.query)
                    model.focusResultsNonce &+= 1
                }
                .onExitCommand {                         // ESC: clear, then dismiss
                    if model.query.isEmpty { model.requestHide?() } else { model.query = "" }
                }

            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }

            HistoryMenu(model: model)
            BookmarksMenu(model: model)

            Picker("", selection: $model.matchMode) {
                ForEach(MatchMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()                              // size to its 4 segments; no overlap
            .help("Matching mode: Exact / Fuzzy / Wildcard / Regex")

            // ⌃U scope — always-visible state (lit = matching the FULL PATH, not just names).
            // Shortcut discoverability follows macOS convention: tooltip + the gear menu's
            // Scope submenu, not glyphs inside the button.
            Toggle(isOn: Binding(get: { model.scope == .fullPath },
                                 set: { model.scope = $0 ? .fullPath : .nameOnly })) {
                Text("Path")
            }
            .toggleStyle(.button)
            .help("Match against the full path instead of just the file name (⌃U)")

            OptionsButton(model: model)
                .frame(width: 22, height: 22)
                .help("Options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isIndexing {
                ProgressView().controlSize(.small)
                Text(model.statusText)
            } else if model.selectionCount > 1 {
                Text("\(model.selectionCount.formatted()) selected")
                Text("·").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: model.selectionBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("\(model.resultTotal.formatted()) results").foregroundStyle(.secondary)
            } else {
                if model.resultShown < model.resultTotal {
                    Text("showing \(model.resultShown.formatted()) of \(model.resultTotal.formatted()) results")
                } else {
                    Text("\(model.resultTotal.formatted()) results")
                }
                Text("·").foregroundStyle(.tertiary)
                Text("\(model.indexedCount.formatted()) indexed").foregroundStyle(.secondary)
                if let root = model.scopeRoot {
                    Text("· in \((root as NSString).lastPathComponent)")
                        .foregroundStyle(Color.accentColor)
                }
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

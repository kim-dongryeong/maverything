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
            // ZStack keeps the table mounted underneath the state overlays, so
            // selection/scroll state survives indexing and empty moments.
            ZStack {
                layoutBody
                stateOverlay
            }
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
        .sheet(isPresented: $model.showShortcuts) { ShortcutsSheet() }
        .background(OpenSettingsBridge(model: model))
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

    /// Centered friendly states drawn over the (still-mounted) results area:
    /// indexing progress, the first-run "Search everything" hero, and no-results.
    @ViewBuilder private var stateOverlay: some View {
        if model.isIndexing {
            VStack(spacing: 10) {
                ProgressView()
                Text("Indexing your Mac…")
                    .font(.title3.weight(.semibold))
                Text(model.indexedCount > 0
                     ? "\(model.indexedCount.formatted()) items"
                     : model.statusText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
        } else if model.resultsStore.ids.isEmpty {
            if model.query.isEmpty, model.typeFilter == .all, model.scopeRoot == nil,
               model.indexedCount == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 46, weight: .thin))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    Text("Search everything")
                        .font(.title2.weight(.semibold))
                    (Text("Every file on your Mac — including hidden and system files. Try ")
                        + Text("ext:pdf dm:today").font(.caption.monospaced())
                        + Text(", or press ? for syntax."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                .allowsHitTesting(false)
            } else if !model.query.isEmpty || model.typeFilter != .all || model.scopeRoot != nil {
                VStack(spacing: 6) {
                    Text("No Results")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Nothing matches — try fewer terms, or check the filters and syntax.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            // The field itself lives in a rounded container that lights up with the
            // accent color while focused (the native "find field" look).
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)

                TextField("Search every file on your Mac", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
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
                    }
                    .buttonStyle(.plain)
                    .help("Clear (⎋)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.55)))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(searchFocused ? Color.accentColor
                                                : Color(nsColor: .separatorColor),
                                  lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: searchFocused)

            HistoryMenu(model: model)
            BookmarksMenu(model: model)

            // Match mode + toggles consolidated into ONE compact menu (the segmented
            // control + Path button crowded the bar; Everything keeps these in menus
            // too). The label always shows the live state, e.g. "Exact · Path".
            Menu {
                Picker("Match Mode", selection: $model.matchMode) {
                    Text("Exact  (⌃E)").tag(MatchMode.exact)
                    Text("Fuzzy  (⌃F)").tag(MatchMode.fuzzy)
                    Text("Regex  (⌃R)").tag(MatchMode.regex)
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Match Path  (⌃U)", isOn: Binding(get: { model.scope == .fullPath },
                                                         set: { model.scope = $0 ? .fullPath : .nameOnly }))
                Toggle("Match Case  (⌃I)", isOn: $model.matchCase)
                Toggle("Match Whole Word  (⌃B)", isOn: $model.wholeWord)
                Divider()
                Toggle("Wildcards Match Whole Name", isOn: $model.wildcardWholeName)
            } label: {
                HStack(spacing: 3) {
                    Text(modeSummary).font(.system(size: 12))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Mode: Exact ⌃E · Fuzzy ⌃F · Regex ⌃R · cycle ⌃M — Path ⌃U · Case ⌃I · Whole Word ⌃B")

            OptionsButton(model: model)
                .frame(width: 22, height: 22)
                .help("Options")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Live one-glance summary for the match menu label: mode + active toggles.
    private var modeSummary: String {
        var s = model.matchMode.label
        if model.scope == .fullPath { s += " · Path" }
        if model.matchCase { s += " · Aa" }
        if model.wholeWord { s += " · W" }
        return s
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isIndexing {
                ProgressView().controlSize(.small)
                Text(model.statusText).monospacedDigit()
            } else if model.selectionCount > 1 {
                Text("\(model.selectionCount.formatted()) selected").monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: model.selectionBytes, countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("\(model.resultTotal.formatted()) results")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Group {
                    if model.resultShown < model.resultTotal {
                        Text("showing \(model.resultShown.formatted()) of \(model.resultTotal.formatted()) results")
                    } else {
                        Text("\(model.resultTotal.formatted()) results")
                    }
                }
                .monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text("\(model.indexedCount.formatted()) indexed")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let root = model.scopeRoot {
                    scopeChip(root)
                }
                if !model.hasFullDiskAccess {
                    Text("· limited (no Full Disk Access)").foregroundStyle(.orange)
                }
            }
            Spacer()
            if !model.isIndexing {
                Text(String(format: "%.1f ms", model.queryMillis))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    /// Small accent-tinted token showing the active folder scope.
    private func scopeChip(_ root: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "folder.fill").font(.system(size: 8))
            Text((root as NSString).lastPathComponent).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .foregroundStyle(Color.accentColor)
        .help("Searching in \(root)")
    }
}

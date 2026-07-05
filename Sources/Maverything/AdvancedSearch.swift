import MaverythingCore
import SwiftUI

/// Everything-style **Advanced Search**: a form whose fields assemble the app's own
/// query syntax (`ext:` `path:` `size:>=` `dm:` `file:`/`folder:` `case:on`) and drop
/// it into the search field. The backend already parses this syntax — this is purely a
/// GUI builder so users don't have to memorize the grammar.
struct AdvancedSearchSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum TypeChoice: String, CaseIterable, Identifiable {
        case any, files, folders
        var id: String { rawValue }
        var label: String { self == .any ? "Any" : (self == .files ? "Files only" : "Folders only") }
    }
    enum WhenChoice: String, CaseIterable, Identifiable {
        case any, today, yesterday, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Any time"; case .today: return "Today"; case .yesterday: return "Yesterday"
            case .week: return "This week"; case .month: return "This month"
            }
        }
        var token: String? { self == .any ? nil : "dm:\(rawValue)" }
    }
    enum SizeUnit: String, CaseIterable, Identifiable {
        case kb, mb, gb
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    @State private var name = ""
    @State private var ext = ""
    @State private var path = ""
    @State private var sizeMin = ""
    @State private var sizeMax = ""
    @State private var sizeUnit: SizeUnit = .mb
    @State private var type: TypeChoice = .any
    @State private var modified: WhenChoice = .any
    @State private var matchCase = false

    /// Assemble the fields into the app's query grammar.
    private func buildQuery() -> String {
        var parts: [String] = []
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { parts.append(n.contains(" ") ? "\"\(n)\"" : n) }

        let e = ext.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        if !e.isEmpty { parts.append("ext:\(e)") }

        let p = path.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { parts.append(p.contains(" ") ? "path:\"\(p)\"" : "path:\(p)") }

        let mn = sizeMin.trimmingCharacters(in: .whitespaces)
        if !mn.isEmpty, Double(mn) != nil { parts.append("size:>=\(mn)\(sizeUnit.rawValue)") }
        let mx = sizeMax.trimmingCharacters(in: .whitespaces)
        if !mx.isEmpty, Double(mx) != nil { parts.append("size:<=\(mx)\(sizeUnit.rawValue)") }

        switch type { case .files: parts.append("file:"); case .folders: parts.append("folder:"); case .any: break }
        if let t = modified.token { parts.append(t) }
        if matchCase { parts.append("case:on") }
        return parts.joined(separator: " ")
    }

    private var preview: String { buildQuery() }

    var body: some View {
        VStack(spacing: 0) {
            Text("Advanced Search")
                .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 16)
            Form {
                Section("Name & Location") {
                    TextField("Name contains", text: $name, prompt: Text("e.g. report"))
                    TextField("Extension (comma-separated)", text: $ext, prompt: Text("e.g. pdf,jpg"))
                    TextField("Path contains", text: $path, prompt: Text("e.g. Documents"))
                }
                Section("Size, Kind & Date") {
                    HStack {
                        TextField("Min", text: $sizeMin).frame(width: 70)
                        Text("–")
                        TextField("Max", text: $sizeMax).frame(width: 70)
                        Picker("", selection: $sizeUnit) {
                            ForEach(SizeUnit.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(width: 80)
                        Spacer()
                    }
                    Picker("Kind", selection: $type) {
                        ForEach(TypeChoice.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Modified", selection: $modified) {
                        ForEach(WhenChoice.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Match case", isOn: $matchCase)
                }
                Section("Generated query") {
                    Text(preview.isEmpty ? "(enter conditions above)" : preview)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(preview.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Reset") {
                    name = ""; ext = ""; path = ""; sizeMin = ""; sizeMax = ""
                    type = .any; modified = .any; matchCase = false
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Search") {
                    model.query = buildQuery()
                    model.focusNonce &+= 1
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
    }
}

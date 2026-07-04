import AppKit
import MaverythingCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Layout C's right pane — QuickLook thumbnail + metadata for the selected row.
struct PreviewPane: View {
    @ObservedObject var model: AppModel
    @State private var thumb: NSImage?
    @State private var info: FileInfo?

    var body: some View {
        Group {
            if let id = model.selectedID {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        thumbnail
                        if let info {
                            Text(info.name).font(.headline).textSelection(.enabled)
                            Grid(alignment: .leadingFirstTextBaseline,
                                 horizontalSpacing: 10, verticalSpacing: 5) {
                                metaRow("Kind", info.kind)
                                metaRow("Size", info.size)
                                metaRow("Modified", info.modified)
                                metaRow("Created", info.created)
                            }
                            Divider()
                            Text("Path").font(.caption).foregroundStyle(.secondary)
                            Text(info.path).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button("Open") { AppModel.finderOpen(info.path) }
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: info.path)])
                                }
                            }
                            .controlSize(.regular)
                            .padding(.top, 4)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(id)
                .onAppear { load(id) }
                .onChange(of: model.selectedID) { if let s = model.selectedID { load(s) } }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Select a result").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
            if let thumb {
                Image(nsImage: thumb).resizable().scaledToFit().padding(8)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            } else if let info {
                Image(nsImage: IconCache.icon(for: info.path,
                                              isDir: model.selectedID.map { model.isDir($0) } ?? false))
                    .resizable().scaledToFit().frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
        }
        .frame(height: 180)
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private func load(_ id: Int32) {
        let r = model.index.row(Int(id))
        let path = r.path
        info = FileInfo(r)
        thumb = nil
        Task {
            let t = await ThumbCache.shared.thumbnail(for: path, side: 320)
            if let t, model.selectedID == id { thumb = t }   // ignore stale
        }
    }
}

struct FileInfo {
    let name: String, path: String, kind: String, size: String, modified: String, created: String
    init(_ r: FileIndex.RowInfo) {
        name = r.name
        path = r.path
        size = r.isDir ? "Folder" : ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)
        kind = UTType(filenameExtension: r.ext)?.localizedDescription ?? (r.isDir ? "Folder" : "Document")
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        func fmt(_ ns: Int64) -> String {
            ns == 0 ? "—" : df.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9))
        }
        modified = fmt(r.mtime)
        created = fmt(r.crtime)   // was hardcoded "—"
    }
}

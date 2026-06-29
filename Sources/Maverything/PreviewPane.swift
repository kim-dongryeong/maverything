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
                            metaRow("Kind", info.kind)
                            metaRow("Size", info.size)
                            metaRow("Modified", info.modified)
                            metaRow("Created", info.created)
                            Divider()
                            Text("Path").font(.caption).foregroundStyle(.secondary)
                            Text(info.path).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).foregroundStyle(.secondary)
                            HStack {
                                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: info.path)) }
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: info.path)])
                                }
                            }.padding(.top, 4)
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
                VStack { Image(systemName: "doc.text.magnifyingglass").font(.largeTitle)
                    Text("Select a result").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
            if let thumb { Image(nsImage: thumb).resizable().scaledToFit().padding(8) }
            else if let id = model.selectedID {
                Image(nsImage: IconCache.icon(for: model.path(id))).resizable().scaledToFit()
                    .frame(width: 64, height: 64)
            }
        }
        .frame(height: 180)
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(v).textSelection(.enabled)
        }.font(.callout)
    }

    private func load(_ id: Int32) {
        let path = model.path(id)
        info = FileInfo(path: path, index: model.index, id: Int(id))
        thumb = nil
        let url = URL(fileURLWithPath: path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 240),
                                               scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                if model.selectedID == id { thumb = rep.nsImage }   // ignore stale
            }
        }
    }
}

struct FileInfo {
    let name: String, path: String, kind: String, size: String, modified: String, created: String
    init(path: String, index: FileIndex, id: Int) {
        name = (path as NSString).lastPathComponent
        self.path = path
        let isDir = index.isDir(id)
        size = isDir ? "Folder" : ByteCountFormatter.string(fromByteCount: index.size[id], countStyle: .file)
        let ut = UTType(filenameExtension: (path as NSString).pathExtension)
        kind = ut?.localizedDescription ?? (isDir ? "Folder" : "Document")
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let mt = index.mtime[id]
        modified = mt == 0 ? "—" : df.string(from: Date(timeIntervalSince1970: Double(mt) / 1e9))
        created = "—"
    }
}

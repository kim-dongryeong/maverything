import SwiftUI

/// Everything-style quick type-filter chips shown under the search field.
/// Selecting a chip AND-s its clause (folder: / ext:…) with the typed query.
struct FilterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if let root = model.scopeRoot {
                scopeToken(root)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TypeFilter.allCases) { chip($0) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)

            SyntaxHelpButton()
                .padding(.trailing, 12)
                .padding(.leading, 4)
        }
    }

    /// Pinned "In: <folder> ✕" token shown when a folder scope is active.
    private func scopeToken(_ root: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill").font(.system(size: 10))
            Text((root as NSString).lastPathComponent)
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button { model.scopeRoot = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .help("Searching in \(root) — click ✕ to clear")
    }

    private func chip(_ f: TypeFilter) -> some View {
        let active = model.typeFilter == f
        return Button {
            // click the active chip (other than All) to clear back to All
            model.typeFilter = (active && f != .all) ? .all : f
        } label: {
            HStack(spacing: 4) {
                Image(systemName: f.symbol).font(.system(size: 11))
                Text(f.label).font(.system(size: 12, weight: active ? .semibold : .regular))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(active ? Color.accentColor.opacity(0.18)
                                      : Color.secondary.opacity(0.10))
            )
            .overlay(
                Capsule().strokeBorder(active ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
            )
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show only \(f.label.lowercased())")
    }
}

import AppKit
import SwiftUI

/// Everything-style quick type-filter chips shown under the search field.
/// Selecting a chip AND-s its clause (folder: / ext:…) with the typed query.
/// (No divider here — ContentView already draws one right below the bar.)
struct FilterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if let root = model.scopeRoot {
                scopeToken(root)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TypeFilter.allCases) { Chip(model: model, filter: $0) }
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

    /// Pinned "In: <folder> ✕" token shown when a folder scope is active —
    /// styled like an active chip so the bar reads as one family.
    private func scopeToken(_ root: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill").font(.system(size: 10))
            Text((root as NSString).lastPathComponent)
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Button { model.scopeRoot = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Clear folder scope")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .help("Searching in \(root) — click ✕ to clear")
    }

    /// One filter chip. Hover state lives here so only the hovered chip re-renders.
    private struct Chip: View {
        @ObservedObject var model: AppModel
        let filter: TypeFilter
        @State private var hovering = false

        var body: some View {
            let active = model.typeFilter == filter
            Button {
                // click the active chip (other than All) to clear back to All; assigning the
                // SAME value would still fire the (dedupe-less) pipeline and reset scroll/selection.
                let target: TypeFilter = (active && filter != .all) ? .all : filter
                if target != model.typeFilter { model.typeFilter = target }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: filter.symbol).font(.system(size: 11))
                    Text(filter.label)
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(fill(active: active)))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(filter == .all ? "Show all types" : "Show only \(filter.label.lowercased())")
        }

        private func fill(active: Bool) -> AnyShapeStyle {
            if active { return AnyShapeStyle(Color.accentColor.opacity(0.16)) }
            if hovering { return AnyShapeStyle(Color.primary.opacity(0.12)) }
            return AnyShapeStyle(.quaternary)
        }
    }
}

import Foundation
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

enum RowDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var rowHeight: CGFloat { self == .compact ? 17 : 22 }
}

/// The window layouts the user can switch between live (the "build every option"
/// rule). Persisted in UserDefaults.
enum UILayout: String, CaseIterable, Identifiable {
    case table       // B: full-window NSTableView grid (the original)
    case compact     // A: Spotlight/Alfred-style narrow bar + slim results
    case twoPane     // C: results + QuickLook preview/metadata pane
    case grid        // D: Finder-style icon grid with QuickLook thumbnails

    var id: String { rawValue }
    var label: String {
        switch self {
        case .table: return "Table"
        case .compact: return "Compact bar"
        case .twoPane: return "Preview pane"
        case .grid: return "Icon Grid"
        }
    }
    var symbol: String {
        switch self {
        case .table: return "tablecells"
        case .compact: return "magnifyingglass"
        case .twoPane: return "sidebar.right"
        case .grid: return "square.grid.2x2"
        }
    }
}

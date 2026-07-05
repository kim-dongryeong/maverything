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

/// Chrome/VS Code-style title-bar accent — the app's visual identity. The user can
/// switch live to compare and settle on one. Persisted in UserDefaults.
enum TitleBarTintStyle: String, CaseIterable, Identifiable {
    case off       // no tint (system default)
    case strip     // Chrome-style: a thin accent bar across the very top
    case full      // VS Code-style: the whole search bar washed in the accent

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:   return "Off"
        case .strip: return "Title bar band (Chrome)"
        case .full:  return "Full tint (VS Code)"
        }
    }
}

extension Color {
    /// Maverything's emerald brand accent — matches the app icon (#10B981).
    static let mvAccent = Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0)
}

extension NSColor {
    /// The emerald title-bar/header band — brand accent blended toward the window
    /// background so it reads as a tinted chrome band, not a neon block. Recomputed
    /// per call so it tracks the current light/dark appearance.
    static var mvBand: NSColor {
        NSColor(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0, alpha: 1)
            .blended(withFraction: 0.35, of: .windowBackgroundColor) ?? .windowBackgroundColor
    }
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

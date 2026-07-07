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

/// Title-bar accent style — the app's visual identity. Always on (no "off": the emerald
/// band is part of who we are); the user only chooses how far it reaches. Persisted in
/// UserDefaults; defaults to `.full`.
enum TitleBarTintStyle: String, CaseIterable, Identifiable {
    case strip     // a thin accent band across the very top
    case full      // the whole search bar washed in the accent

    var id: String { rawValue }
    var label: String {
        switch self {
        case .strip: return "Title bar band"
        case .full:  return "Full tint"
        }
    }
}

extension Color {
    /// Maverything's emerald brand accent — matches the app icon (#10B981).
    static let mvAccent = Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0)
}

extension NSColor {
    /// The emerald title-bar/header band. It renders as a real accessory view ABOVE the
    /// title-bar material, so it must be a BOLD color (a light blend gets visually lost).
    /// Kept mostly-solid emerald (matches the app icon #10B981), only slightly grounded.
    static var mvBand: NSColor {
        NSColor(srgbRed: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0, alpha: 1)
            .blended(withFraction: 0.08, of: .windowBackgroundColor) ?? NSColor(srgbRed: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0, alpha: 1)
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

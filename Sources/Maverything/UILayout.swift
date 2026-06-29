import Foundation

/// The window layouts the user can switch between live (the "build every option"
/// rule). Persisted in UserDefaults.
enum UILayout: String, CaseIterable, Identifiable {
    case table       // B: full-window NSTableView grid (the original)
    case compact     // A: Spotlight/Alfred-style narrow bar + slim results
    case twoPane     // C: results + QuickLook preview/metadata pane

    var id: String { rawValue }
    var label: String {
        switch self {
        case .table: return "Table"
        case .compact: return "Compact bar"
        case .twoPane: return "Preview pane"
        }
    }
    var symbol: String {
        switch self {
        case .table: return "tablecells"
        case .compact: return "magnifyingglass"
        case .twoPane: return "sidebar.right"
        }
    }
}

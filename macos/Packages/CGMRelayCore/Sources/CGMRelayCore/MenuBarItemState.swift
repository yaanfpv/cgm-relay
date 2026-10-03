import Foundation

/// TrendArrow maps the engine's Nightscout direction names to the arrows
/// shown beside a reading.
public enum TrendArrow {
    /// all is every arrow that can appear, so a view can size for the
    /// widest one.
    public static let all = ["⇈", "↑", "↗", "→", "↘", "↓", "⇊"]

    /// symbol is nil for an absent, unknown or uncomputed direction, so no
    /// arrow is ever shown for a trend the device did not report.
    public static func symbol(forDirection direction: String?) -> String? {
        switch direction {
        case "DoubleUp": return "⇈"
        case "SingleUp": return "↑"
        case "FortyFiveUp": return "↗"
        case "Flat": return "→"
        case "FortyFiveDown": return "↘"
        case "SingleDown": return "↓"
        case "DoubleDown": return "⇊"
        default: return nil
        }
    }
}

/// MenuBarItemState is what the menu bar item itself shows: a mark, an
/// optional reading beside it, and the words that say the state for anyone
/// who cannot see its colour.
public struct MenuBarItemState: Sendable, Equatable {
    /// Tint is how the mark is drawn: `plain` is the system's own template
    /// rendering, which follows the menu bar's appearance; every other case
    /// is a fixed colour that says something is off.
    public enum Tint: Sendable, Equatable {
        case plain, amber, red, grey
    }

    public var tint: Tint
    public var accessibilityLabel: String
    /// title is the reading and its trend arrow to show beside the mark, or
    /// nil for the mark alone.
    public var title: String?
    /// showsUpdateMark is whether a small dot joins the mark to say a newer
    /// version is waiting. It never changes the mark's tint, which only ever
    /// says something is wrong.
    public var showsUpdateMark: Bool

    public init(tint: Tint, accessibilityLabel: String, title: String? = nil, showsUpdateMark: Bool = false) {
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.title = title
        self.showsUpdateMark = showsUpdateMark
    }

    /// make decides the menu bar item from the displayed menu state.
    /// While setup is unfinished and nothing is wrong the mark is grey and
    /// says so; a problem (late readings, a stopped engine, failing
    /// sign-in) shows and is named whether or not setup is finished. The
    /// reading is shown only when asked for and only while it is current: a
    /// stale or unreachable value is never shown as if it were live. A
    /// pending update adds the dot and a sentence to the spoken label, and
    /// nothing else.
    public static func make(menu: MenuDisplayState, needsSetup: Bool, showReading: Bool, update: PendingUpdate = .none) -> MenuBarItemState {
        var state = base(menu: menu, needsSetup: needsSetup, showReading: showReading)
        if let note = update.accessibilityNote {
            state.accessibilityLabel += ". \(note)"
            state.showsUpdateMark = true
        }
        return state
    }

    private static func base(menu: MenuDisplayState, needsSetup: Bool, showReading: Bool) -> MenuBarItemState {
        if needsSetup && !menu.hasProblem {
            return MenuBarItemState(tint: .grey, accessibilityLabel: "CGM Relay: Finish setup")
        }
        let label = "CGM Relay: \(menu.shortStatus)"
        switch menu.dot {
        case .green:
            var title: String?
            if showReading, let value = menu.readingValue {
                title = [value, menu.readingTrendArrow].compactMap { $0 }.joined(separator: " ")
            }
            return MenuBarItemState(tint: .plain, accessibilityLabel: label, title: title)
        case .amber:
            return MenuBarItemState(tint: .amber, accessibilityLabel: label)
        case .red:
            return MenuBarItemState(tint: .red, accessibilityLabel: label)
        case .grey:
            return MenuBarItemState(tint: .grey, accessibilityLabel: label)
        }
    }
}

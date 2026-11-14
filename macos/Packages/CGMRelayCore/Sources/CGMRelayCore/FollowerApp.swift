import Foundation

/// FollowerApp is a phone app that follows this relay, in the order the
/// Connect pane offers them.
public enum FollowerApp: String, CaseIterable, Sendable, Identifiable, Codable {
    case xDrip4iOS
    case xDripPlus
    case loopFollow
    case nightguard
    case sweetDreams
    case zukka

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .xDrip4iOS: return "xDrip4iOS"
        case .xDripPlus: return "xDrip+"
        case .loopFollow: return "LoopFollow"
        case .nightguard: return "Nightguard"
        case .sweetDreams: return "Sweet Dreams"
        case .zukka: return "Zukka"
        }
    }
}

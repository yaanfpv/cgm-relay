import CGMRelayCore
import SwiftUI

/// SafetyNoticeText is the safety notice's one rendering, shared by setup and
/// Settings > About so the two can never word it differently.
struct SafetyNoticeText: View {
    let font: Font

    var body: some View {
        Text(SafetyNotice.text)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
    }
}

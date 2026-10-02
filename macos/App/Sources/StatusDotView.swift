import AppKit
import CGMRelayCore
import SwiftUI

/// StatusDotView renders a StatusDot as a small filled circle: the status
/// row inside the open menu.
struct StatusDotView: View {
    let dot: StatusDot

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch dot {
        case .green: .green
        case .amber: .orange
        case .red: .red
        case .grey: .gray
        }
    }
}

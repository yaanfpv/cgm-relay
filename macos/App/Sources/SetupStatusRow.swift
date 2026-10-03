import SwiftUI

/// SetupStatusRow is one thing setup checks or sets, drawn the same way
/// wherever it appears: a title, a one-line caption, and a right-hand slot
/// of fixed size that shows checking, done, or the one action needed. The
/// row and its slot never change size between states, so nothing beside or
/// below it moves when a state changes.
struct SetupStatusRow: View {
    enum Slot {
        case checking
        case done(String)
        /// A done state that also keeps its one way back, in the same slot.
        case doneWithAction(String, actionLabel: String, accessibleName: String? = nil, run: () -> Void)
        case action(String, accessibleName: String? = nil, style: CGMButtonStyle = .secondary, run: () -> Void)
        case unavailable(String)
    }

    static let height: CGFloat = 44
    static let slotWidth: CGFloat = 170

    /// name identifies the row for assistive technology and for walks that
    /// read its frame back.
    let name: String
    let title: String
    let caption: String
    var captionIsMonospaced = false
    var captionIsError = false
    let slot: Slot

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(captionIsMonospaced ? .system(.caption, design: .monospaced) : .caption)
                    .foregroundStyle(captionIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            slotView
                .frame(width: Self.slotWidth, alignment: .trailing)
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-row-\(name)")
    }

    @ViewBuilder
    private var slotView: some View {
        switch slot {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .done(let text):
            HStack(spacing: 6) {
                Text(text).foregroundStyle(.secondary)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Done")
            }
        case .doneWithAction(let text, let label, let accessibleName, let run):
            HStack(spacing: 8) {
                Text(text).foregroundStyle(.secondary)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Done")
                AccessibleButton(label, accessibleName: accessibleName, action: run)
            }
        case .action(let label, let accessibleName, let style, let run):
            AccessibleButton(label, accessibleName: accessibleName, style: style, action: run)
        case .unavailable(let text):
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// SetupInfoRow is a statement in setup with nothing to check or set: a
/// symbol, a title and one line of caption.
struct SetupInfoRow: View {
    let symbol: String
    let title: String
    let caption: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: SetupStatusRow.height)
        .accessibilityElement(children: .combine)
    }
}

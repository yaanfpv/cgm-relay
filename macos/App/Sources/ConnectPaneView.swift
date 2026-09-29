import AppKit
import CGMRelayCore
import SwiftUI

/// ConnectPaneView shows a follower app everything it needs to connect:
/// the address, the bearer token, and a QR code encoding both together.
/// It never offers an address the engine is not actually listening on or a
/// phone could never reach (model.connectPaneAddressState's own contract),
/// and shows a plain reason instead of a guess whenever there is none
/// right now. Setup's last step is this same view, laid out more compactly,
/// with its own way out of the blocked state and its own trailing sections.
/// The token is read from the Keychain once when the view appears and again
/// after a rotation, and held in state.
struct ConnectPaneView<Extra: View>: View {
    @ObservedObject var model: AppModel
    let blockedSecondary: String
    /// blockedAction is the button offered when this Mac cannot be reached
    /// yet, or nil where the surrounding window already has a way out.
    let blockedAction: (label: String, run: () -> Void)?
    let showsTokenRotation: Bool
    /// isCompact puts the QR code beside the address and token and drops
    /// the section header, for a window that must not scroll.
    let isCompact: Bool
    let extra: (_ token: String) -> Extra

    init(
        model: AppModel,
        blockedSecondary: String,
        blockedAction: (label: String, run: () -> Void)?,
        showsTokenRotation: Bool,
        isCompact: Bool,
        @ViewBuilder extra: @escaping (_ token: String) -> Extra
    ) {
        self.model = model
        self.blockedSecondary = blockedSecondary
        self.blockedAction = blockedAction
        self.showsTokenRotation = showsTokenRotation
        self.isCompact = isCompact
        self.extra = extra
    }

    @State private var token = ""
    @State private var tokenRevealed = false
    @State private var isConfirmingRotate = false
    @State private var isRotating = false
    @State private var rotateErrorMessage: String?

    var body: some View {
        Form {
            switch model.connectPaneAddressState {
            case .thisMacOnly:
                blockedSection(
                    symbol: "laptopcomputer",
                    message: "A follower app on your phone can't reach this Mac yet.",
                    secondary: blockedSecondary,
                    actionLabel: blockedAction?.label,
                    action: blockedAction?.run
                )
            case .unavailable(let reason):
                blockedSection(symbol: "clock", message: reason, secondary: nil, actionLabel: nil, action: nil)
            case .ready(let address):
                readySection(address: address)
                extra(token)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            token = model.currentToken() ?? ""
            model.refreshNetworkAddresses()
            if model.settings.tailscaleHTTPSEnabled {
                Task { await model.refreshTailscale() }
            }
        }
    }

    /// blockedSection is every state a follower app cannot yet connect
    /// in, rendered the same calm way: a symbol, one sentence, an
    /// optional second sentence naming the next step, and its action
    /// when there is one worth offering from this pane -- an
    /// unavailable reach reason (waiting for Tailscale, a network, or a
    /// setting to finish applying, or the engine not running at all) has
    /// no pane-local action, since starting the engine lives in the menu,
    /// not here.
    private func blockedSection(
        symbol: String,
        message: String,
        secondary: String?,
        actionLabel: String?,
        action: (() -> Void)?
    ) -> some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let secondary {
                    Text(secondary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let actionLabel, let action {
                    AccessibleButton(actionLabel, style: .primary, action: action)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func readySection(address: String) -> some View {
        if isCompact {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    qrTile(address: address)
                    VStack(alignment: .leading, spacing: 10) {
                        addressRow(address: address)
                        Divider()
                        tokenRow
                    }
                }
            }
        } else {
            standardReadySection(address: address)
        }
    }

    private func standardReadySection(address: String) -> some View {
        Section {
            qrTile(address: address)
            addressRow(address: address)
            tokenRow
        } header: {
            Text("Point a follower app (xDrip4iOS, LoopFollow, Nightguard) at this address.")
        } footer: {
            if showsTokenRotation {
                VStack(alignment: .leading, spacing: 8) {
                    rotateButton
                    if let rotateErrorMessage {
                        Text(rotateErrorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    /// addressRow gives the address its own line rather than squeezing it
    /// into a labelled row's value column beside a Copy button: a
    /// Tailscale or local-network address is long enough that column
    /// truncates it, and it is exactly the string a person has to read
    /// and retype on their phone.
    private func addressRow(address: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(address)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                Spacer(minLength: 12)
                AccessibleButton("Copy", accessibleName: "Copy Address") { copy(address) }
            }
        }
    }

    /// tokenRow mirrors addressRow's own layout (a label above a value row
    /// with its buttons trailing) so the two rows' Copy buttons share one
    /// trailing edge, and gives the hidden token's dots a fixed size so
    /// they render whole rather than truncating under the trailing
    /// buttons.
    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(tokenRevealed ? token : String(repeating: "•", count: 12))
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                AccessibleButton(tokenRevealed ? "Hide" : "Show") { tokenRevealed.toggle() }
                AccessibleButton("Copy", accessibleName: "Copy Token") { copy(token) }
                if isRotating {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    /// qrTile puts the QR code on its own white rounded tile: the code
    /// stays scannable in dark mode, where a transparent or dark surround
    /// would fight its own black-on-white contrast. The tile is the one
    /// deliberate exception to the system doing the chrome -- a QR code's
    /// own contrast is a functional requirement, not a decoration.
    private func qrTile(address: String) -> some View {
        HStack {
            if !isCompact { Spacer() }
            if !token.isEmpty, let qrImage = try? QRCodeGenerator.nsImage(for: "\(address)/?token=\(token)") {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white)
                    )
                    .accessibleImageName("QR code: scan with a follower app to connect using this address and token")
            }
            if !isCompact { Spacer() }
        }
        .padding(.vertical, 4)
    }

    private var rotateButton: some View {
        AccessibleButton("Make a New Token…") {
            isConfirmingRotate = true
        }
        .confirmationDialog(
            "Make a New Token?",
            isPresented: $isConfirmingRotate,
            titleVisibility: .visible
        ) {
            Button("Make a New Token", role: .destructive) {
                confirmRotate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every follower app using the current token will stop reading until you give it the new one.")
        }
    }

    /// confirmRotate is the token-rotation confirmation's own destructive
    /// action: it asks the model for a new token and reports a plain
    /// error if that fails.
    private func confirmRotate() {
        Task {
            isRotating = true
            rotateErrorMessage = nil
            if let newToken = await model.rotateToken() {
                token = newToken
            } else {
                rotateErrorMessage = "Couldn't create a new token. Try again."
            }
            isRotating = false
        }
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

extension ConnectPaneView where Extra == EmptyView {
    /// The Settings window's Connect pane: the blocked state points at
    /// Advanced, and there is nothing after the address card.
    init(model: AppModel, openAdvancedPane: @escaping () -> Void) {
        self.init(
            model: model,
            blockedSecondary: "Switch to My tailnet or My local network in Advanced to change that.",
            blockedAction: ("Open Advanced…", openAdvancedPane),
            showsTokenRotation: true,
            isCompact: false,
            extra: { _ in EmptyView() }
        )
    }
}

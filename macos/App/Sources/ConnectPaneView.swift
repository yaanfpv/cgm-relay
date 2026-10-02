import AppKit
import CGMRelayCore
import SwiftUI

/// qrPixelsPerModule is the scale every QR code is drawn at.
private let qrPixelsPerModule: CGFloat = 10

/// ConnectPaneView shows a follower app everything it needs to connect:
/// the address, the bearer token, and a QR code for the follower app chosen
/// above it. Where an app can import settings from a QR code, the code sets
/// it up; otherwise it opens a page the relay serves for a few minutes, from
/// which each value is copied (the token is never in that address).
/// It never offers an address the engine is not actually listening on or a
/// phone could never reach (model.connectPaneAddressState's own contract),
/// and shows a plain reason instead of a guess whenever there is none
/// right now. Setup's connect step is this same view, laid out more compactly,
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
    /// isCompact puts a smaller QR code beside the address and token and
    /// drops the section header, for a window that must not scroll.
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
    @State private var pairingCode: PairingCode?
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
                if !isCompact { stepsSection(address: address) }
                extra(token)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .task(id: pairingKey) {
            if let readyAddress { await keepPairingCodeFresh(address: readyAddress) }
        }
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

    private var readyAddress: String? {
        if case .ready(let address) = model.connectPaneAddressState { return address }
        return nil
    }

    /// pairingKey changes whenever a code already minted could stop working:
    /// a new address, or the engine (which holds the codes) starting again,
    /// as it does after a new token.
    private var pairingKey: String {
        "\(readyAddress ?? "")|\(token)|\(String(describing: model.engineState))"
    }

    private var followerApp: FollowerApp { model.settings.connectFollowerApp }

    /// keepPairingCodeFresh mints a pairing code when the pane appears and
    /// again each time the current one expires while the pane is shown,
    /// retrying quietly while the engine is not answering yet. It ends when
    /// the pane goes away.
    private func keepPairingCodeFresh(address: String) async {
        while !Task.isCancelled {
            if let code = await model.mintPairingCode(address: address) {
                pairingCode = code
                try? await Task.sleep(for: .seconds(max(1, code.expiresAt.timeIntervalSinceNow)))
            } else {
                pairingCode = nil
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var currentQR: FollowerQR? {
        guard let address = readyAddress else { return nil }
        return FollowerQRPlanner.qr(for: followerApp, address: address, token: token, pairingCode: pairingCode?.code)
    }

    @ViewBuilder
    private func readySection(address: String) -> some View {
        if isCompact {
            Section {
                appPicker
                HStack(alignment: .center, spacing: 16) {
                    qrTile
                    VStack(alignment: .leading, spacing: 10) {
                        addressRow(address: address)
                        Divider()
                        tokenRow
                        qrCaption
                    }
                }
                stepsBlock(address: address)
            }
        } else {
            standardReadySection(address: address)
        }
    }

    private func standardReadySection(address: String) -> some View {
        Section {
            appPicker
            qrTile
            qrCaption
            addressRow(address: address)
            tokenRow
            if showsTokenRotation { newTokenRow }
        } header: {
            Text("Choose your follower app, then scan its code.")
        }
    }

    private var appPicker: some View {
        Picker("Follower app", selection: Binding(get: { followerApp }, set: { model.updateConnectFollowerApp($0) })) {
            ForEach(FollowerApp.allCases) { app in
                Text(app.displayName).tag(app)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Follower app")
    }

    /// stepsSection is where the chosen app keeps its fields, in its own
    /// names, and the one-tap copy for an app that takes a single address.
    private func stepsSection(address: String) -> some View {
        Section {
            stepsBlock(address: address)
        } header: {
            Text("In \(followerApp.displayName)")
        }
    }

    private func stepsBlock(address: String) -> some View {
        let instructions = FollowerAppEntry.instructions(for: followerApp, address: address)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(instructions.steps.enumerated()), id: \.offset) { _, step in
                Text(step)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let single = singleValueField(instructions) {
                singleValueRow(single)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// singleValueField is the one address an app takes its address and
    /// token in together (xDrip+ and Nightguard), which gets its own Copy.
    private func singleValueField(_ instructions: FollowerAppEntry.Instructions) -> FollowerAppEntry.Field? {
        switch followerApp {
        case .xDripPlus, .nightguard: instructions.fields.first
        case .xDrip4iOS, .loopFollow: nil
        }
    }

    /// singleValueRow is a label with its Copy in the trailing slot, like
    /// the address and token rows.
    private func singleValueRow(_ field: FollowerAppEntry.Field) -> some View {
        HStack {
            Text(field.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            AccessibleButton("Copy", accessibleName: "Copy \(field.label)") {
                copy(field.value.replacingOccurrences(of: FollowerAppEntry.tokenPlaceholder, with: token))
            }
        }
    }

    /// addressRow keeps the address on one line, shrinking a long name a
    /// little before ever truncating it: it is exactly the string a person
    /// has to read and retype on their phone, so it never breaks inside a
    /// hostname.
    private func addressRow(address: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(address)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                AccessibleButton("Copy", accessibleName: "Copy Address") { copy(address) }
            }
        }
    }

    /// tokenRow mirrors addressRow's own layout (a label above a value row
    /// with its buttons trailing) so the two rows' Copy buttons share one
    /// trailing edge. The buttons always keep their own size; the token
    /// wraps inside the space they leave.
    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(tokenRevealed ? token : String(repeating: "•", count: 12))
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    AccessibleButton(tokenRevealed ? "Hide" : "Show") { tokenRevealed.toggle() }
                    AccessibleButton("Copy", accessibleName: "Copy Token") { copy(token) }
                    if isRotating {
                        ProgressView().controlSize(.small)
                    }
                }
                .fixedSize()
                .layoutPriority(1)
            }
        }
    }

    /// qrTile puts the QR code on its own white rounded tile: the code
    /// stays scannable in dark mode, where a transparent or dark surround
    /// would fight its own black-on-white contrast. The tile is the one
    /// deliberate exception to the system doing the chrome -- a QR code's
    /// own contrast is a functional requirement, not a decoration. A code
    /// that holds the token stays hidden until the token is shown.
    private var qrTile: some View {
        let image = qrImage
        let side = qrSide(for: image)
        return HStack {
            if !isCompact { Spacer() }
            qrContent(image: image)
                .frame(width: side, height: side)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(qrIsHidden || image == nil ? Color(nsColor: .quaternarySystemFill) : Color.white)
                )
            if !isCompact { Spacer() }
        }
        .padding(.vertical, 4)
    }

    /// qrImage is drawn at one scale for every payload, so a denser code
    /// (a settings import holds more than a link does) gets a larger tile
    /// rather than smaller modules; a scanner needs the modules, not the
    /// tile, to be big enough.
    private var qrImage: NSImage? {
        guard let qr = currentQR else { return nil }
        return try? QRCodeGenerator.nsImage(for: qr.payload, scale: qrPixelsPerModule, correctionLevel: "L")
    }

    private func qrSide(for image: NSImage?) -> CGFloat {
        let base: CGFloat = isCompact ? 116 : 140
        guard let image else { return base }
        let modules = image.size.width / qrPixelsPerModule
        return max(base, modules * (isCompact ? 2.8 : 3.6))
    }

    private var qrIsHidden: Bool {
        (currentQR?.carriesToken ?? false) && !tokenRevealed
    }

    @ViewBuilder
    private func qrContent(image: NSImage?) -> some View {
        if qrIsHidden {
            VStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                AccessibleButton("Show Code", accessibleName: "Show \(followerApp.displayName) Code") { tokenRevealed = true }
            }
            .accessibilityElement(children: .contain)
        } else if let image {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .accessibleImageName("QR code for \(followerApp.displayName): \(currentQR?.carriesToken == true ? "scan it inside the app to set it up" : "scan it with the iPhone camera to open a page of values to copy")")
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Making a code…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qrCaption: some View {
        Text(currentQR?.caption ?? "")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(isCompact ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(currentQR == nil ? 0 : 1)
    }

    /// newTokenRow is the token's own row: what making a new one does, with
    /// its button in the trailing slot.
    private var newTokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Every follower app stops reading until you give it the new token.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                AccessibleButton("Make a New Token…") {
                    isConfirmingRotate = true
                }
                .fixedSize()
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
            if let rotateErrorMessage {
                Text(rotateErrorMessage)
                    .foregroundStyle(.red)
            }
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

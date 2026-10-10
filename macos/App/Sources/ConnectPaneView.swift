import AppKit
import CGMRelayCore
import SwiftUI

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
/// On the local network route, until a phone has CGM Relay's certificate,
/// it offers the certificate stepper instead, as a sheet on this pane, and
/// afterwards leads with the same step for each further phone.
/// The token is read from the Keychain when the view appears, after a
/// rotation and when the certificate step changes, and held in state.
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
    /// isPresentingCertificateStep is whether this pane opened the stepper,
    /// so only the window the person pressed the button in shows it.
    @State private var isPresentingCertificateStep = false

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
            case .certificateStepNeeded:
                blockedSection(
                    symbol: "lock.shield",
                    message: "Your phone needs CGM Relay's certificate before it can connect over your Wi-Fi.",
                    secondary: nil,
                    actionLabel: "Set Up HTTPS on Your Phone",
                    action: openCertificateStep
                )
            case .ready(let address):
                if !isCompact, model.localRoute != nil { addPhoneSection }
                readySection(address: address)
                if !isCompact { stepsSection(address: address) }
                extra(token)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .task(id: pairingKey) {
            // The engine keeps one pairing code, so while this pane's stepper
            // shows Connect itself, only that inner pane makes codes; this one
            // makes a fresh code once the stepper closes. The inner pane's
            // code replaces this one's, so this one is dropped meanwhile.
            if let readyAddress, !isPresentingCertificateStep {
                await keepPairingCodeFresh(address: readyAddress)
            } else {
                pairingCode = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { isPresentingCertificateStep && model.isCertificateStepPresented },
            set: { presented in
                if !presented {
                    isPresentingCertificateStep = false
                    model.closeCertificateStep()
                }
            }
        )) {
            CertificateStepView(model: model)
        }
        .onChange(of: model.isCertificateStepPresented) { _, presented in
            if !presented { isPresentingCertificateStep = false }
        }
        .onChange(of: model.settings.needsCertificateStep) {
            token = model.currentToken() ?? ""
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

    private func openCertificateStep() {
        isPresentingCertificateStep = true
        model.beginCertificateStep()
    }

    /// addPhoneSection leads the local network route once a phone has the
    /// certificate: the app cannot tell phones apart, so every further phone
    /// is offered the same step, and nothing here claims which phones have it.
    private var addPhoneSection: some View {
        Section {
            HStack {
                Text("Each phone needs CGM Relay's certificate once before it can connect over your Wi-Fi.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                AccessibleButton("Set Up HTTPS on a Phone…", action: openCertificateStep)
                    .fixedSize()
            }
        }
    }

    private var readyAddress: String? {
        if case .ready(let address) = model.connectPaneAddressState { return address }
        return nil
    }

    /// pairingKey changes whenever a code already minted could stop working:
    /// a new address, the engine (which holds the codes) starting again, as
    /// it does after a new token, or this pane's stepper opening or closing.
    private var pairingKey: String {
        "\(readyAddress ?? "")|\(token)|\(String(describing: model.engineState))|\(isPresentingCertificateStep)"
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
        return FollowerQRPlanner.qr(
            for: followerApp,
            address: model.followerAddress(for: followerApp, readyAddress: address),
            token: token,
            pairingCode: pairingCode?.code
        )
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
        let instructions = FollowerAppEntry.instructions(for: followerApp, address: model.followerAddress(for: followerApp, readyAddress: address))
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

    /// singleValueField is the one value an app takes its address and token
    /// in together (xDrip+), which gets its own Copy, introduced by the
    /// app's own step above it.
    private func singleValueField(_ instructions: FollowerAppEntry.Instructions) -> FollowerAppEntry.Field? {
        switch followerApp {
        case .xDripPlus: instructions.fields.first
        case .xDrip4iOS, .loopFollow, .nightguard: nil
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
                copy(field.value(withToken: token))
            }
        }
    }

    /// addressRow keeps the address on one line, shrinking a long name a
    /// little before ever truncating it: it is exactly the string a person
    /// has to read and retype on their phone, so it never breaks inside a
    /// hostname.
    private func addressRow(address readyAddress: String) -> some View {
        let address = model.followerAddress(for: followerApp, readyAddress: readyAddress)
        return VStack(alignment: .leading, spacing: 6) {
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
    /// wraps inside the space they leave, between any two characters and
    /// never with a hyphen, since it is typed exactly as shown.
    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ExactWrappingText(text: tokenRevealed ? token : String(repeating: "•", count: 12))
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
    /// own contrast is a functional requirement, not a decoration. Its side
    /// is fixed for each layout, whichever follower app is chosen.
    private var qrTile: some View {
        let image = qrImage
        let side = isCompact ? QRCodeGenerator.compactTileSide : QRCodeGenerator.standardTileSide
        return HStack {
            if !isCompact { Spacer() }
            qrContent(image: image)
                .frame(width: side, height: side)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(image == nil ? Color(nsColor: .quaternarySystemFill) : Color.white)
                )
            if !isCompact { Spacer() }
        }
        .padding(.vertical, 4)
    }

    private var qrImage: NSImage? {
        guard let qr = currentQR else { return nil }
        let side = isCompact ? QRCodeGenerator.compactTileSide : QRCodeGenerator.standardTileSide
        return try? QRCodeGenerator.nsImage(for: qr.payload, tileSide: side)
    }

    @ViewBuilder
    private func qrContent(image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .interpolation(.high)
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

    /// qrCaption holds room for the longest caption of any app, so the rows
    /// that follow it (Address first) sit at the same place whichever app is
    /// chosen and whatever the window's width wraps each caption to.
    private var qrCaption: some View {
        ZStack(alignment: isCompact ? .topLeading : .top) {
            ForEach(FollowerApp.allCases) { app in
                captionText(FollowerQRPlanner.caption(for: app)).hidden()
            }
            captionText(currentQR?.caption ?? "")
                .opacity(currentQR == nil ? 0 : 1)
        }
    }

    private func captionText(_ caption: String) -> some View {
        Text(caption)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(isCompact ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
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
        if !token.isEmpty, value.contains(token) {
            pasteboard.setString("", forType: concealedPasteboardType)
        }
    }
}

/// ExactWrappingText shows a value a person may type by hand: selectable,
/// monospaced, and wrapped between characters with no hyphen added, which
/// SwiftUI's Text can insert at a line break.
private struct ExactWrappingText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.hyphenationFactor = 0
        paragraph.usesDefaultHyphenation = false
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        field.preferredMaxLayoutWidth = width
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0
        return CGSize(width: width, height: ceil(height))
    }
}

/// concealedPasteboardType is the community convention (nspasteboard.org)
/// clipboard managers and history tools honour by not recording the item.
/// It lives outside ConnectPaneView because a generic type cannot hold a
/// static stored property.
private let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

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

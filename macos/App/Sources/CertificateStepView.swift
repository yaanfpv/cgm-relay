import AppKit
import CGMRelayCore
import SwiftUI

/// CertificateStepView walks a person through giving one phone CGM Relay's
/// certificate, so a follower app can reach this Mac over https on the
/// local network: which phone, a code to scan, the phone's own install
/// screens in its own words, iPhone's trust switch, then Connect itself with
/// a live check that says when an app has actually fetched readings over the
/// encrypted address. The step is recorded finished when the person moves
/// past the install screens, since a follower app needs the token Connect
/// withholds until then; the check confirms, it never decides.
struct CertificateStepView: View {
    enum Phone: Hashable {
        case iPhone, android

        var format: CertificateDownloadFormat {
            switch self {
            case .iPhone: .iPhone
            case .android: .android
            }
        }
    }

    enum Screen: Int, CaseIterable {
        case whichPhone, scan, install, trust, check
    }

    /// LinkState is the download code's life as the person sees it.
    enum LinkState: Equatable {
        case making
        case live(URL)
        case ended
        case failed(String)
    }

    @ObservedObject var model: AppModel
    @State private var phone: Phone?
    @State private var screen: Screen = .whichPhone
    @State private var link: LinkState = .making
    @State private var linkGeneration = 0
    /// startedAt is when this stepper opened; only a fetch at or after it
    /// counts for the check.
    @State private var startedAt = Date()

    private var screens: [Screen] {
        phone == .android ? Screen.allCases.filter { $0 != .trust } : Screen.allCases
    }

    private var stepNumber: Int { (screens.firstIndex(of: screen) ?? 0) + 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .frame(width: SettingsView.paneWidth)
        .cgmWindowBackground()
        .onAppear { startedAt = Date() }
        .onChange(of: model.settings.needsCertificateStep) { _, needed in
            // Tailscale HTTPS turned on from the first screen, or the reach
            // changed elsewhere: this phone no longer needs the step here.
            if !needed, !model.settings.localCertificateStepFinished { model.closeCertificateStep() }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Step \(stepNumber) of \(screens.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch screen {
        case .whichPhone: "Set Up HTTPS on Your Phone"
        case .scan: "Scan This Code with Your Phone"
        case .install: phone == .android ? "Install the Certificate" : "Install the Profile"
        case .trust: "Turn On Full Trust"
        case .check: "Check Your Follower App"
        }
    }

    private var subtitle: String? {
        switch screen {
        case .whichPhone: "Your follower app will reach this Mac over an encrypted address on your Wi-Fi."
        case .scan:
            phone == .android
                ? "Use the Camera app or Google Lens, then open the link."
                : "Use the Camera app, then tap the link it shows."
        case .install, .trust: nil
        case .check: "Set up your follower app with its code or the address and token. CGM Relay shows below when it fetches readings over the encrypted address."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .whichPhone: whichPhoneScreen
        case .scan: scanScreen
        case .install: installScreen
        case .trust: trustScreen
        case .check: checkScreen
        }
    }

    // MARK: - Which phone

    private var whichPhoneScreen: some View {
        Form {
            Section {
                Picker("Phone", selection: $phone) {
                    Text("iPhone").tag(Phone?.some(.iPhone))
                    Text("Android").tag(Phone?.some(.android))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Phone")
            }
            Section {
                SetupInfoRow(
                    symbol: "lock.shield",
                    title: "What this does",
                    caption: "Your phone installs a certificate from this Mac, so readings travel encrypted between them.",
                    wrapsCaption: true
                )
                SetupInfoRow(
                    symbol: "checkmark.seal",
                    title: "Why the phone says \u{201C}Not Verified\u{201D}",
                    caption: "The certificate comes from this Mac, not from a company your phone already knows. That's expected.",
                    wrapsCaption: true
                )
                SetupInfoRow(
                    symbol: "hand.raised",
                    title: "What it can't do",
                    caption: "It only works for this Mac's own name and your home network's addresses, never for websites.",
                    wrapsCaption: true
                )
                SetupInfoRow(symbol: "trash", title: "Removing it later", caption: removalCaption, wrapsCaption: true)
            } footer: {
                Text("On a shared or public Wi-Fi, use Tailscale instead: it's encrypted end to end.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .running = model.tailscaleStatus {
                Section {
                    TailscaleHTTPSControl(model: model, part: .statusRow)
                } footer: {
                    TailscaleHTTPSControl(model: model, part: .notes)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshTailscale() }
    }

    private var removalCaption: String {
        switch phone {
        case .android:
            "Settings, Security & privacy, More security & privacy, Encryption & credentials, Trusted credentials, User, CGM Relay, Remove."
        case .iPhone, nil:
            "Settings, General, VPN & Device Management, CGM Relay, Remove Profile."
        }
    }

    // MARK: - Scan

    private var scanScreen: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    codeTile
                    linkLine
                    AccessibleButton("Make a New Code") { linkGeneration += 1 }
                    Text("The code works once, for two minutes. It only hands over the certificate; it never carries your readings or token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .task(id: linkGeneration) { await makeLink() }
    }

    private var codeTile: some View {
        let side = QRCodeGenerator.compactTileSide
        return ZStack {
            switch link {
            case .live(let url):
                if let image = try? QRCodeGenerator.nsImage(for: url.absoluteString, tileSide: side) {
                    Image(nsImage: image)
                        .interpolation(.high)
                        .resizable()
                        .accessibleImageName("Code that opens the certificate download on your phone")
                }
            case .ended:
                Text("This code has ended.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .failed(let reason):
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .making:
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: side, height: side)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isLive ? Color.white : Color(nsColor: .quaternarySystemFill))
        )
    }

    private var isLive: Bool {
        if case .live = link { return true }
        return false
    }

    @ViewBuilder
    private var linkLine: some View {
        if case .live(let url) = link {
            HStack {
                Text(url.absoluteString)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                AccessibleButton("Copy", accessibleName: "Copy Link") { copy(url.absoluteString) }
            }
        }
    }

    /// makeLink mints a fresh link for the chosen phone and marks it ended
    /// once its lifetime has passed; a download ends it sooner on the
    /// server, which the person sees as the phone's own install screen.
    private func makeLink() async {
        guard let phone else { return }
        link = .making
        do {
            let url = try await model.mintCertificateLink(format: phone.format)
            link = .live(url)
            try? await Task.sleep(for: CertificateDownloadServer.defaultLifetime)
            if !Task.isCancelled { link = .ended }
        } catch is CancellationError {
            // The step was closed while the code was being made.
            return
        } catch {
            link = .failed("Couldn't make a code. Check that this Mac is on your Wi-Fi, then make a new code.")
        }
    }

    // MARK: - Install and trust

    private var installScreen: some View {
        numberedSection(phone == .android ? androidInstallSteps : iPhoneInstallSteps)
    }

    private var iPhoneInstallSteps: [Text] {
        [
            Text("If your iPhone asks ") + bold("\u{201C}Choose a Device\u{201D}") + Text(", tap ") + bold("iPhone") + Text("."),
            Text("Safari says ") + bold("\u{201C}Profile Downloaded. Review the profile in the Settings app if you want to install it.\u{201D}") + Text(" Tap ") + bold("Close") + Text("."),
            Text("Open ") + bold("Settings") + Text(". Tap ") + bold("Profile Downloaded") + Text(" near the top (or General, VPN & Device Management, CGM Relay)."),
            Text("Tap ") + bold("Install") + Text(", enter your passcode, then ") + bold("Install") + Text(" again on ") + bold("\u{201C}Installing this profile will change settings on your iPhone\u{201D}") + Text(". That warning is expected for any certificate you add yourself."),
            Text("Tap ") + bold("Done") + Text("."),
        ]
    }

    private var androidInstallSteps: [Text] {
        [
            Text("Open ") + bold("Settings") + Text(", then ") + bold("Security & privacy") + Text("."),
            Text("Scroll to ") + bold("More security & privacy") + Text(", then ") + bold("Encryption & credentials") + Text("."),
            Text("Tap ") + bold("Install a certificate") + Text(", then ") + bold("CA certificate") + Text("."),
            Text("On ") + bold("\u{201C}Your data won't be private\u{201D}") + Text(", tap ") + bold("Install anyway") + Text(". That warning is expected for any certificate you add yourself."),
            Text("Pick ") + bold("CGM Relay.crt") + Text(" from Downloads."),
        ]
    }

    private var trustScreen: some View {
        numberedSection(
            [
                Text("Open ") + bold("Settings") + Text(", ") + bold("General") + Text(", ") + bold("About") + Text(", then ") + bold("Certificate Trust Settings") + Text(" at the bottom."),
                Text("Turn on ") + bold("CGM Relay") + Text(", then tap ") + bold("Continue") + Text("."),
            ],
            footer: "Without this switch, your iPhone installs the certificate but won't use it."
        )
    }

    private func bold(_ text: String) -> Text { Text(text).bold() }

    private func numberedSection(_ steps: [Text], footer: String? = nil) -> some View {
        Form {
            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        step
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                if let footer { Text(footer) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Check

    /// checkScreen is Connect itself, now showing the token and the chosen
    /// app's own code, with the live check beneath it, so the person sets
    /// up their app here and watches it connect.
    private var checkScreen: some View {
        ConnectPaneView(
            model: model,
            blockedSecondary: "Choose My local network in Advanced to use this step.",
            blockedAction: nil,
            showsTokenRotation: false,
            isCompact: true
        ) { _ in
            Section {
                checkRow
            }
        }
    }

    private var fetch: (userAgent: String, at: Date)? {
        model.lanReadingFetch(since: startedAt)
    }

    @ViewBuilder
    private var checkRow: some View {
        if let fetch {
            SetupStatusRow(
                name: "certificate-check",
                title: "Readings fetched",
                caption: "An app reporting itself as \(fetch.userAgent) fetched readings over the encrypted address.",
                wrapsCaption: true,
                slot: .done("Working")
            )
        } else {
            SetupStatusRow(
                name: "certificate-check",
                title: "Waiting for your app",
                caption: "Nothing has fetched readings over the encrypted address since you started.",
                wrapsCaption: true,
                slot: .checking
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if screen != .check {
                AccessibleButton("Cancel") { model.closeCertificateStep() }
                    .keyboardShortcut(.cancelAction)
            }
            if screen != .whichPhone {
                AccessibleButton("Back") { move(by: -1) }
            }
            Spacer()
            if screen == .check {
                AccessibleButton("Done", style: .primary) { model.closeCertificateStep() }
                    .keyboardShortcut(.defaultAction)
            } else {
                AccessibleButton("Continue", style: .primary) { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phone == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    /// advance moves to the next screen; leaving the last install screen is
    /// the person saying their phone has the certificate, which is when the
    /// step is recorded finished and Connect shows the token.
    private func advance() {
        // Finished first, so Connect on the next screen already shows the
        // token rather than the step it replaces.
        if screen == screens[screens.count - 2] { model.finishCertificateStep() }
        move(by: 1)
    }

    private func move(by offset: Int) {
        guard let index = screens.firstIndex(of: screen) else { return }
        let next = screens.index(index, offsetBy: offset, limitedBy: offset < 0 ? screens.startIndex : screens.index(before: screens.endIndex))
        if let next { screen = screens[next] }
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

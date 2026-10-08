import CGMRelayCore
import SwiftUI

/// SignInForm is the sign-in fields and their checking state, held apart
/// from the pane so setup's footer button and the pane's own Return key
/// drive the same form.
@MainActor
final class SignInForm: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?
    /// emailLeft is set once the email field has lost focus, the moment a
    /// malformed address starts to be pointed out.
    @Published var emailLeft = false

    var emailIsValid: Bool { AccountEmail.trimmedIfValid(email) != nil }

    /// emailPrompt is the line under the email field: only for a
    /// malformed address, and only after the person has left the field.
    var emailPrompt: String? {
        emailLeft && !emailIsValid ? AccountEmail.prompt : nil
    }

    var canSubmit: Bool { !isChecking && emailIsValid && !password.isEmpty }

    /// submit checks the account against LibreLinkUp; the password is
    /// dropped once it has been accepted.
    func submit(model: AppModel) async {
        guard canSubmit else { return }
        isChecking = true
        message = nil
        let outcome = await model.signIn(email: email, password: password)
        isChecking = false
        if outcome == .signedIn {
            password = ""
        } else {
            message = outcome.message
        }
    }

    func reset() {
        email = ""
        password = ""
        message = nil
        emailLeft = false
    }
}

/// AccountPaneView signs in to LibreLinkUp, checked against the account
/// before anything is saved, and signs back out. In setup, a signed-in
/// account reads as status rows like every other thing setup checks, and
/// signing in is the footer's one primary button (SetupView).
struct AccountPaneView: View {
    /// Presentation is where the pane is shown: the Settings window, or
    /// first-launch setup.
    enum Presentation {
        case settings, setup
    }

    @ObservedObject var model: AppModel
    var presentation: Presentation = .settings
    /// externalForm is the form a hosting window drives itself; without one
    /// the pane keeps its own.
    var externalForm: SignInForm?
    @StateObject private var ownForm = SignInForm()
    @State private var isConfirmingSignOut = false
    @State private var signOutMessage: String?

    private var form: SignInForm { externalForm ?? ownForm }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.credentialsConfigured, let signedInEmail = model.accountEmail {
                    switch presentation {
                    case .settings: signedInSection(signedInEmail: signedInEmail)
                    case .setup: setupSignedInSection(signedInEmail: signedInEmail)
                    }
                } else {
                    SignInSection(form: form, model: model)
                }
            }
            .formStyle(.grouped)
            if presentation == .settings, !(model.credentialsConfigured && model.accountEmail != nil) {
                signInButtonRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// signInButtonRow is Settings' Sign In, below the grouped fields and
    /// right-aligned, where a Mac puts a form's default button. Setup has
    /// the same button in its footer.
    private var signInButtonRow: some View {
        HStack(spacing: 8) {
            Spacer()
            if form.isChecking {
                ProgressView().controlSize(.small)
            }
            AccessibleButton(form.isChecking ? "Checking…" : "Sign In", style: .primary) {
                Task { await form.submit(model: model) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!form.canSubmit)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var signOutDialogMessage: some View {
        Text("Every follower app stops getting readings until you sign in again.")
    }

    /// setupSignedInSection is the signed-in account as setup shows it: the
    /// account with its Sign Out in the row's own slot, then the first
    /// reading arriving.
    private func setupSignedInSection(signedInEmail: String) -> some View {
        Section {
            SetupStatusRow(
                name: "account",
                title: "LibreLinkUp account",
                caption: signedInEmail,
                slot: .doneWithAction("Signed in", actionLabel: "Sign Out", accessibleName: "Sign Out") { isConfirmingSignOut = true }
            )
            .confirmationDialog("Sign Out?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { confirmSignOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                signOutDialogMessage
            }
            SetupStatusRow(name: "reading", title: "Latest reading", caption: "Checked every minute.", slot: readingSlot)
        } footer: {
            signOutFailure
        }
    }

    private var readingSlot: SetupStatusRow.Slot {
        if let value = model.menuState.readingValue {
            return .done([value, model.menuState.readingUnit].compactMap { $0 }.joined(separator: " "))
        }
        switch model.engineState {
        case .starting, .running, .waitingToRestart:
            return .checking
        case .stopped, .failed:
            return .unavailable("Not running")
        }
    }

    private func signedInSection(signedInEmail: String) -> some View {
        Section {
            LabeledContent("Signed in as") {
                HStack(spacing: 12) {
                    Text(signedInEmail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    AccessibleButton("Sign Out") { isConfirmingSignOut = true }
                        .confirmationDialog("Sign Out?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive) { confirmSignOut() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            signOutDialogMessage
                        }
                }
            }
            LabeledContent("Last reading") {
                Text(model.menuState.readingLine)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("This account is checked every minute for new readings. Sign out to switch accounts.")
                signOutFailure
            }
        }
    }

    @ViewBuilder
    private var signOutFailure: some View {
        if let signOutMessage {
            Text(signOutMessage)
                .foregroundStyle(.red)
        }
    }

    /// confirmSignOut is the Sign Out confirmation's own destructive
    /// action: it signs out, then clears the email and password fields on
    /// success so a new sign-in starts from empty ones.
    private func confirmSignOut() {
        Task {
            signOutMessage = nil
            let succeeded = await model.signOut()
            if succeeded {
                form.reset()
            } else {
                signOutMessage = "Couldn't sign out. Try again."
            }
        }
    }
}

/// SignInSection is the email and password fields. Each label is the
/// field's own placeholder, so typing replaces it; Return in either field
/// presses the hosting window's default Sign In button, which sits outside
/// this group (below it in Settings, in the footer in setup).
private struct SignInSection: View {
    @ObservedObject var form: SignInForm
    let model: AppModel
    @FocusState private var emailFocused: Bool

    var body: some View {
        Section {
            TextField("Email", text: $form.email, prompt: Text("Email"))
                .labelsHidden()
                .disableAutocorrection(true)
                .accessibilityLabel("Email")
                .focused($emailFocused)
                .onChange(of: emailFocused) { _, focused in
                    if !focused { form.emailLeft = true }
                }
                .onSubmit { submit() }
            if let prompt = form.emailPrompt {
                Text(prompt)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            SecureField("Password", text: $form.password, prompt: Text("Password"))
                .labelsHidden()
                .accessibilityLabel("Password")
                .onSubmit { submit() }
        } header: {
            Text("Sign in with your LibreLinkUp email and password.")
        } footer: {
            if let message = form.message {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }

    private func submit() {
        Task { await form.submit(model: model) }
    }
}

import CGMRelayCore
import SwiftUI

/// AccountPaneView signs in to LibreLinkUp, checked against the account
/// before anything is saved, and signs back out.
struct AccountPaneView: View {
    @ObservedObject var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var isChecking = false
    @State private var message: String?
    @State private var isConfirmingSignOut = false

    var body: some View {
        Form {
            if model.credentialsConfigured, let signedInEmail = model.accountEmail {
                signedInSection(signedInEmail: signedInEmail)
            } else {
                signInSection
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func signedInSection(signedInEmail: String) -> some View {
        Section {
            LabeledContent("Signed in as") {
                Text(signedInEmail)
            }
            LabeledContent("Last reading") {
                Text(model.menuState.readingLine)
            }
            HStack {
                Spacer()
                AccessibleButton("Sign Out") {
                    isConfirmingSignOut = true
                }
                .confirmationDialog(
                    "Sign Out?",
                    isPresented: $isConfirmingSignOut,
                    titleVisibility: .visible
                ) {
                    Button("Sign Out", role: .destructive) {
                        confirmSignOut()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every follower app stops getting readings until you sign in again.")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("This account is checked every minute for new readings. Sign out to switch accounts.")
                if let message {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var signInSection: some View {
        Section {
            TextField("Email", text: $email)
                .disableAutocorrection(true)
            SecureField("Password", text: $password)
        } header: {
            Text("Sign in with your LibreLinkUp email and password.")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let message {
                    Text(message)
                        .foregroundStyle(.red)
                }
                HStack {
                    AccessibleButton(isChecking ? "Checking…" : "Sign In", style: .primary) {
                        Task { await signIn() }
                    }
                    .disabled(isChecking || email.isEmpty || password.isEmpty)
                    if isChecking {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    /// confirmSignOut is the Sign Out confirmation's own destructive
    /// action: it signs out, then clears the email and password fields on
    /// success so a new sign-in starts from empty ones.
    private func confirmSignOut() {
        Task {
            message = nil
            let succeeded = await model.signOut()
            if succeeded {
                email = ""
                password = ""
            } else {
                message = "Couldn't sign out. Try again."
            }
        }
    }

    private func signIn() async {
        isChecking = true
        message = nil
        let outcome = await model.signIn(email: email, password: password)
        isChecking = false
        if outcome != .signedIn {
            message = outcome.message
        } else {
            password = ""
        }
    }
}

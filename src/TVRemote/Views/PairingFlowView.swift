import SwiftUI

public struct PairingFlowView: View {
    @Bindable var appState: AppState
    let session: PairingSessionState
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isPinFocused: Bool

    private var glassInk: Color {
        colorScheme == .dark ? .white.opacity(0.94) : .black.opacity(0.86)
    }

    public init(appState: AppState, session: PairingSessionState, namespace: Namespace.ID) {
        self.appState = appState
        self.session = session
        self.namespace = namespace
    }

    public var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        let cardContent = VStack(spacing: 14) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(glassInk)
                .padding(.top, 4)

            VStack(spacing: 4) {
                Text("Pair with \(session.device.name)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(glassInk)
                    .multilineTextAlignment(.center)

                Text(session.stepSummary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(glassInk.opacity(0.72))

                Text("Enter the 4-digit PIN shown on your Apple TV screen. Credentials are stored securely in macOS Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(glassInk.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.awaitingPin {
                TextField("0000", text: $appState.pairingPinInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: 136)
                    .focused($isPinFocused)
                    .disabled(session.isSubmitting)
                    .onChange(of: appState.pairingPinInput) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(4))
                        if filtered != newValue {
                            appState.pairingPinInput = filtered
                        }
                    }
                    .onSubmit {
                        submitIfValid()
                    }
                    .onAppear {
                        appState.pairingPinInput = ""
                        isPinFocused = true
                    }
                    .accessibilityLabel("Four-digit Apple TV PIN")
            } else if let cooldown = session.cooldownSeconds, cooldown > 0 {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cooldown — showing PIN in \(cooldown)s…")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(glassInk.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            } else if session.errorMessage == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Requesting PIN on TV…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(glassInk.opacity(0.75))
                }
                .padding(.vertical, 8)
            }

            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        appState.pairingPinInput = ""
                        Task { await appState.service.cancelPairing() }
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(glassInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Cancel Pairing")

                    if !session.awaitingPin && session.cooldownSeconds == nil && session.errorMessage != nil {
                        Button {
                            appState.pairingPinInput = ""
                            Task { await appState.service.retryPairingStep() }
                        } label: {
                            Text("Retry")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel("Retry showing PIN on Apple TV")
                    } else {
                        Button {
                            submitIfValid()
                        } label: {
                            HStack(spacing: 6) {
                                if session.isSubmitting {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                                Text(session.isSubmitting ? "Verifying…" : "Pair")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(appState.pairingPinInput.count == 4 && session.awaitingPin ? 1.0 : 0.5))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(appState.pairingPinInput.count != 4 || session.isSubmitting || !session.awaitingPin)
                        .accessibilityLabel("Submit PIN")
                    }
                }
            }

            if session.canSkipCurrentStep {
                Button {
                    Task { await appState.service.skipOptionalPairingStep() }
                } label: {
                    Text("Skip AirPlay (Use Companion Remote Only)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(glassInk.opacity(0.68))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .onChange(of: session.currentIndex) { _, _ in
            appState.pairingPinInput = ""
            isPinFocused = true
        }
        .onChange(of: session.awaitingPin) { _, ready in
            if ready {
                isPinFocused = true
            }
        }

        if reduceTransparency {
            cardContent
                .background(
                    cardShape
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(cardShape.strokeBorder(.primary.opacity(0.16), lineWidth: 1))
                )
        } else {
            cardContent
                .glassEffect(.regular, in: cardShape)
                .glassEffectID("pairing-card", in: namespace)
                .glassEffectTransition(.materialize)
        }
    }

    private func submitIfValid() {
        guard appState.pairingPinInput.count == 4, !session.isSubmitting else { return }
        let code = appState.pairingPinInput
        Task {
            await appState.service.submitPairingPIN(code)
        }
    }
}

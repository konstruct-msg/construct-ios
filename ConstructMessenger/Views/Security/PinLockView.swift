//
//  PinLockView.swift
//  Construct Messenger
//
//  Created by Codex on 06.02.2026.
//

import SwiftUI

struct PinLockView: View {
    @EnvironmentObject var securityViewModel: SecurityViewModel

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var showPinEntry = false
    @State private var didAttemptBiometrics = false
    @FocusState private var isPinFocused: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                
                Image("KonstructLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                
                Spacer()

                if showPinEntry || !isBiometricMode {
                    VStack(spacing: 12) {
                        Text("enter_pin_code")
                            .font(.headline)

                        SecureField("pin_code", text: $pin)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.plain)
                            .onChange(of: pin) { newValue in
                                let normalized = normalizePin(newValue)
                                if normalized != newValue {
                                    pin = normalized
                                    return
                                }
                                handlePinInput()
                            }
                            .focused($isPinFocused)
                    }
                    .padding(.horizontal, 32)
                } else {
                    Button {
                        authenticateWithBiometrics()
                    } label: {
                        Text(String(format: NSLocalizedString("use_biometric", comment: ""), securityViewModel.biometricDisplayName))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 32)

                    Button("use_pin_code") {
                        withAnimation {
                            showPinEntry = true
                            errorMessage = nil
                        }
                    }
                    .padding(.top, 4)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
        }
        .onAppear {
            if isBiometricMode {
                showPinEntry = false
                authenticateIfNeeded()
            } else {
                showPinEntry = true
            }
            if showPinEntry {
                isPinFocused = true
            }
        }
        .onChange(of: showPinEntry) { isVisible in
            if isVisible {
                isPinFocused = true
            }
        }
    }

    private var isBiometricMode: Bool {
        securityViewModel.isBiometricEnabled && securityViewModel.isBiometricAvailable
    }

    private var expectedPinLength: Int? {
        securityViewModel.pinLength
    }

    private func authenticateIfNeeded() {
        guard !didAttemptBiometrics else { return }
        didAttemptBiometrics = true
        authenticateWithBiometrics()
    }

    private func authenticateWithBiometrics() {
        errorMessage = nil
        securityViewModel.authenticateWithBiometrics(reason: NSLocalizedString("unlock", comment: "")) { success, errorMessage in
            if success {
                securityViewModel.isUnlocked = true
            } else if let errorMessage {
                self.errorMessage = errorMessage
            } else {
                self.errorMessage = NSLocalizedString("wrong_pin_code", comment: "")
            }
        }
    }

    private func unlockWithPin() {
        errorMessage = nil
        if securityViewModel.verifyPin(pin) {
            securityViewModel.isUnlocked = true
        } else {
            errorMessage = NSLocalizedString("wrong_pin_code", comment: "")
        }
    }

    private func handlePinInput() {
        if !pin.isEmpty {
            errorMessage = nil
        }

        let length = pin.count
        guard length >= 6 && length <= 12 else { return }

        if securityViewModel.verifyPin(pin) {
            securityViewModel.isUnlocked = true
            return
        }

        if let expected = expectedPinLength, length == expected {
            errorMessage = NSLocalizedString("wrong_pin_code", comment: "")
            pin = ""
        } else if expectedPinLength == nil && length == 12 {
            errorMessage = NSLocalizedString("wrong_pin_code", comment: "")
            pin = ""
        }
    }

    private func normalizePin(_ value: String) -> String {
        let digits = value.filter { $0.isNumber }
        if digits.count > 12 {
            return String(digits.prefix(12))
        }
        return digits
    }
}

#Preview {
    PinLockView()
        .environmentObject(SecurityViewModel())
}

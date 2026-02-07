//
//  PinSetupView.swift
//  Construct Messenger
//
//  Created by Codex on 06.02.2026.
//

import SwiftUI

struct PinSetupView: View {
    @EnvironmentObject var securityViewModel: SecurityViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case currentPin
        case enterPin
        case confirmPin
        case biometric
    }

    @State private var step: Step
    @State private var currentPin = ""
    @State private var newPin = ""
    @State private var confirmPin = ""
    @State private var errorKey: String?
    @State private var enableBiometrics = false
    @FocusState private var focusedField: FocusField?

    private let isChanging: Bool

    init(isChanging: Bool) {
        self.isChanging = isChanging
        _step = State(initialValue: isChanging ? .currentPin : .enterPin)
    }
    
    private enum FocusField {
        case current
        case new
        case confirm
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer()
                    
                    content
                        .frame(maxWidth: .infinity)

                    if let errorKey {
                        Text(LocalizedStringKey(errorKey))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
            }
            .navigationTitle(titleKey)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                enableBiometrics = securityViewModel.isBiometricEnabled
                focusForCurrentStep()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(primaryActionTitle) {
                        handlePrimaryAction()
                    }
                    .disabled(!canProceed)
                }
            }
        }
    }

    private var titleKey: LocalizedStringKey {
        switch step {
        case .currentPin:
            return "enter_pin_code"
        case .enterPin:
            return "create_pin_code"
        case .confirmPin:
            return "confirm_pin_code"
        case .biometric:
            return "security"
        }
    }

    private var primaryActionTitle: LocalizedStringKey {
        return "continue"
    }

    private var canProceed: Bool {
        switch step {
        case .currentPin:
            return !currentPin.isEmpty
        case .enterPin:
            return !newPin.isEmpty
        case .confirmPin:
            return !confirmPin.isEmpty
        case .biometric:
            return true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .currentPin:
            VStack(spacing: 12) {
                Text("enter_pin_code")
                    .font(.headline)
                SecureField("current_pin_code", text: $currentPin)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .onChange(of: currentPin) { currentPin = normalizePin($0) }
                    .focused($focusedField, equals: .current)
            }
        case .enterPin:
            VStack(spacing: 12) {
                Text("enter_pin_code")
                    .font(.headline)
                SecureField("pin_code", text: $newPin)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .onChange(of: newPin) { newPin = normalizePin($0) }
                    .focused($focusedField, equals: .new)
                Text("pin_code_length")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .confirmPin:
            VStack(spacing: 12) {
                Text("confirm_pin_code")
                    .font(.headline)
                SecureField("confirm_pin_code", text: $confirmPin)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .onChange(of: confirmPin) { confirmPin = normalizePin($0) }
                    .focused($focusedField, equals: .confirm)
            }
        case .biometric:
            VStack(spacing: 16) {
                if securityViewModel.isBiometricAvailable {
                    let label = String(format: NSLocalizedString("enable_biometric", comment: ""), securityViewModel.biometricDisplayName)
                    Text(label)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Toggle(isOn: $enableBiometrics) {
                        Text(String(format: NSLocalizedString("use_biometric", comment: ""), securityViewModel.biometricDisplayName))
                    }
                    .toggleStyle(.switch)

                    Button("not_now") {
                        enableBiometrics = false
                        handlePrimaryAction()
                    }
                    .padding(.top, 8)
                } else {
                    Text("biometric_unavailable")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func handlePrimaryAction() {
        errorKey = nil

        switch step {
        case .currentPin:
            guard securityViewModel.verifyPin(currentPin) else {
                errorKey = "wrong_pin_code"
                return
            }
            step = .enterPin
            focusForCurrentStep()
        case .enterPin:
            guard isValidLength(newPin) else {
                errorKey = "pin_code_length"
                return
            }
            step = .confirmPin
            focusForCurrentStep()
        case .confirmPin:
            guard newPin == confirmPin else {
                errorKey = "pin_codes_dont_match"
                return
            }
            step = .biometric
            focusedField = nil
        case .biometric:
            securityViewModel.setPin(newPin)
            securityViewModel.isBiometricEnabled = enableBiometrics
            dismiss()
        }
    }
    
    private func focusForCurrentStep() {
        switch step {
        case .currentPin:
            focusedField = .current
        case .enterPin:
            focusedField = .new
        case .confirmPin:
            focusedField = .confirm
        case .biometric:
            focusedField = nil
        }
    }

    private func isValidLength(_ pin: String) -> Bool {
        pin.count >= 6 && pin.count <= 12
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
    PinSetupView(isChanging: false)
        .environmentObject(SecurityViewModel())
}

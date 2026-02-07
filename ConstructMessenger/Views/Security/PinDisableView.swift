//
//  PinDisableView.swift
//  Construct Messenger
//
//  Created by Codex on 06.02.2026.
//

import SwiftUI

struct PinDisableView: View {
    @EnvironmentObject var securityViewModel: SecurityViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var errorKey: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                
                Spacer()
                
                VStack(spacing: 20) {
                    Text("enter_pin_code")
                        .font(.headline)

                    SecureField("pin_code", text: $pin)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: pin) { pin = normalizePin($0) }

                    if let errorKey {
                        Text(LocalizedStringKey(errorKey))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button("disable") {
                        disablePin()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.isEmpty)
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
            }
            .navigationTitle("disable_pin_code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func disablePin() {
        errorKey = nil
        if securityViewModel.verifyPin(pin) {
            securityViewModel.disablePin()
            dismiss()
        } else {
            errorKey = "wrong_pin_code"
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
    PinDisableView()
        .environmentObject(SecurityViewModel())
}

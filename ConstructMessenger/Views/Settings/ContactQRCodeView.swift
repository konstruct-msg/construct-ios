//
//  ContactQRCodeView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//  Updated for Dynamic Invites on 30.01.2026.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct ContactQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    let userId: String
    let username: String
    
    @State private var qrPayload: String?
    @State private var timeRemaining: TimeInterval = 180 // 3 minutes
    @State private var generationError: String?
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let generator = InviteGenerator()

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 24) {
                    Text("my_qr_code")
                        .font(.title2)
                        .fontWeight(.semibold)

                    // QR Code
                    if let payload = qrPayload, let qrImage = generateQRCode(from: payload) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: QRCodeSize.standard, height: QRCodeSize.standard)
                            .padding(QRCodeSize.padding)
                            .background(Color.white)
                            .cornerRadius(QRCodeSize.cornerRadius)
                            .shadow(radius: QRCodeSize.shadowRadius)
                    } else if let error = generationError {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: QRCodeSize.standard, height: QRCodeSize.standard)
                            .cornerRadius(QRCodeSize.cornerRadius)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.largeTitle)
                                        .foregroundColor(.orange)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                }
                            }
                    } else {
                        ProgressView()
                            .frame(width: QRCodeSize.standard, height: QRCodeSize.standard)
                    }

                    VStack(spacing: 8) {
                        Text("@\(username)")
                            .font(.headline)
                            .foregroundColor(.primary)

                        // Countdown timer
                        if timeRemaining > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.caption)
                                Text("Expires in \(formatTime(timeRemaining))")
                                    .font(.caption)
                            }
                            .foregroundColor(timeRemaining < 60 ? .orange : .secondary)
                        } else {
                            Text("Code expired")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        Text("show_this_code_to_someone_nearby")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }

                Spacer()

                // Regenerate button if expired
                if timeRemaining <= 0 {
                    Button {
                        regenerateQRCode()
                    } label: {
                        Label("Generate New Code", systemImage: "arrow.clockwise")
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 32)
                }
                
                // Hint text
                Text("scan_with_camera_or_screenshot")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                generateInitialQRCode()
            }
            .onReceive(timer) { _ in
                if timeRemaining > 0 {
                    timeRemaining -= 1
                }
            }
        }
    }

    // MARK: - QR Code Generation
    
    private func generateInitialQRCode() {
        do {
            // ✅ FIX: Use generateDeepLink to get full URL, not just payload
            let deepLink = try generator.generateDeepLink(userId: userId, useHTTPS: false)
            qrPayload = deepLink
            timeRemaining = 180 // Reset to 3 minutes
            generationError = nil
            Log.info("✅ Generated QR code for \(username): \(deepLink.prefix(50))...", category: "ContactQRCodeView")
        } catch {
            generationError = "Failed to generate code"
            Log.error("❌ Failed to generate QR: \(error)", category: "ContactQRCodeView")
        }
    }
    
    private func regenerateQRCode() {
        qrPayload = nil
        generationError = nil
        generateInitialQRCode()
    }
    
    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        if let outputImage = filter.outputImage {
            // Scale up the QR code
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)

            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                return UIImage(cgImage: cgImage)
            }
        }

        return nil
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

#Preview {
    ContactQRCodeView(
        userId: "user123",
        username: "john_doe"
    )
}

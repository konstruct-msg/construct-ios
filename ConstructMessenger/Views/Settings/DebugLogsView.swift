//
//  DebugLogsView.swift
//  Construct Messenger
//
//  View for managing and exporting debug logs
//  Created on 31.01.2026
//

import SwiftUI

struct DebugLogsView: View {
    @StateObject private var developerMode = DeveloperMode.shared
    @State private var isLoggingEnabled = LogCollector.shared.isEnabled
    @State private var logSize: Int64 = 0
    @State private var showingShareSheet = false
    @State private var showingClearConfirm = false
    @State private var logFileURL: URL?
    @State private var isExporting = false
    @State private var exportError: String?
    
    var body: some View {
        List {
            // MARK: - Developer Mode Warning
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Developer Mode")
                            .font(.headline)
                    }
                    
                    Text("Log collection is ONLY available in DEBUG builds with Developer Mode enabled. Completely disabled in production for security.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // MARK: - Status Section
            Section {
                HStack {
                    Text("Logging Status")
                    Spacer()
                    Text(isLoggingEnabled ? "Enabled" : "Disabled")
                        .foregroundColor(isLoggingEnabled ? .green : .secondary)
                }
                
                HStack {
                    Text("Total Log Size")
                    Spacer()
                    Text(formatBytes(logSize))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Status")
            }
            
            // MARK: - Control Section
            Section {
                Toggle("Enable Log Collection", isOn: $isLoggingEnabled)
                    .disabled(!developerMode.canEnableLogCollection)
                    .onChange(of: isLoggingEnabled) { newValue in
                        LogCollector.shared.isEnabled = newValue
                        updateLogSize()
                    }
            } header: {
                Text("Settings")
            } footer: {
                Text("When enabled, all app logs are saved to a file. This helps diagnose issues but uses disk space.")
            }
            
            // MARK: - Actions Section
            Section {
                Button {
                    exportLogs()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export Logs")
                        Spacer()
                        if isExporting {
                            ProgressView()
                        }
                    }
                }
                .disabled(!isLoggingEnabled || isExporting)
                
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear All Logs")
                    }
                }
                .disabled(!isLoggingEnabled)
            } header: {
                Text("Actions")
            } footer: {
                if let error = exportError {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                }
            }
            
            // MARK: - Info Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About Log Collection")
                        .font(.headline)
                    
                    Text("Logs help diagnose issues with message delivery, session initialization, and other features.")
                    
                    Text("What's collected:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.top, 4)
                    
                    bulletPoint("App version and build number")
                    bulletPoint("iOS version and device model")
                    bulletPoint("Network requests and responses")
                    bulletPoint("Crypto operations (no private keys)")
                    bulletPoint("Message flow (no content)")
                    bulletPoint("Error messages and stack traces")
                    
                    Text("What's NOT collected:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.top, 4)
                    
                    bulletPoint("Message content")
                    bulletPoint("Private keys or passwords")
                    bulletPoint("Personal information")
                    
                    Text("Logs are stored locally and never sent automatically. You choose when to share them.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .font(.caption)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            updateLogSize()
        }
        .sheet(isPresented: $showingShareSheet) {
            if let url = logFileURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Clear All Logs?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                clearLogs()
            }
        } message: {
            Text("This will permanently delete all collected logs. This action cannot be undone.")
        }
    }
    
    // MARK: - Helper Views
    
    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•")
            Text(text)
        }
    }
    
    // MARK: - Actions
    
    private func updateLogSize() {
        logSize = LogCollector.shared.getTotalLogSize()
    }
    
    private func exportLogs() {
        isExporting = true
        exportError = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try LogCollector.shared.createLogArchive()
                
                DispatchQueue.main.async {
                    self.logFileURL = url
                    self.isExporting = false
                    self.showingShareSheet = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.exportError = error.localizedDescription
                    self.isExporting = false
                }
            }
        }
    }
    
    private func clearLogs() {
        LogCollector.shared.clearLogs()
        updateLogSize()
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DebugLogsView()
    }
}

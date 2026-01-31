//
//  SettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var connectionStatus = ConnectionStatusManager.shared
    @State private var showingQRCode = false
    @State private var linkCopied = false
    
    private let inviteGenerator = InviteGenerator()

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Account Section
                Section {
                    NavigationLink(destination: AccountSettingsView().environmentObject(authViewModel)) {
                        Label {
                            Text("account")
                        } icon: {
                            Image(systemName: "person.circle")
                                .foregroundColor(.blue)
                        }
                    }
                } header: {
                    Text("user")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("@\(viewModel.username)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: - Security Section
                Section {
                    Button(role: .destructive) {
                        viewModel.showResetAllSessionsConfirm = true
                    } label: {
                        Label {
                            Text("Reset All Sessions")
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath.circle")
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("This will reset all encrypted sessions with your contacts. Use if you suspect your encryption keys are compromised.")
                }

                // TODO: Add more Security options:
                // - PIN code protection (6-10 digits)
                // - Biometric authentication (Face ID / Touch ID)
                // - Auto-lock timeout settings
                // See: TODO.md for detailed requirements

                // MARK: - Share Contact Section
                Section {
                    Button {
                        showingQRCode = true
                    } label: {
                        Label {
                            Text("show_my_qr_code")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "qrcode")
                                .foregroundColor(.blue)
                        }
                    }

                    Button {
                        copyContactLink()
                    } label: {
                        Label {
                            Text(linkCopied ? "link_copied" : "copy_contact_link")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: linkCopied ? "checkmark.circle.fill" : "link")
                                .foregroundColor(linkCopied ? .green : .green)
                        }
                    }
                    .disabled(linkCopied)
                } header: {
                    Text("share_contact")
                }

                // MARK: - Preferences Section
                Section {
                    NavigationLink(destination: NetworkSettingsView()) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("network")
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(connectionStatus.isConnected ? Color.green : Color.red)
                                        .frame(width: 6, height: 6)
                                    Text(connectionStatus.connectionStatus.localizedKey)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "network")
                                .foregroundColor(.green)
                        }
                    }

                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label {
                            Text("appearance")
                        } icon: {
                            Image(systemName: "paintbrush.fill")
                                .foregroundColor(.purple)
                        }
                    }
                    NavigationLink(destination: NotificationsSettingsView()) {
                        Label {
                            Text("notifications")
                        } icon: {
                            Image(systemName: "bell")
                                .foregroundColor(.blue)
                        }
                    }
                    NavigationLink(destination: BackgroundFetchSettingsView()) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("background_fetch")
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(BackgroundFetchConfig.shouldBeEnabled ? Color.green : Color.gray)
                                        .frame(width: 6, height: 6)
                                    Text(BackgroundFetchConfig.shouldBeEnabled ? "background_fetch_enabled" : "background_fetch_disabled")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "arrow.clockwise.circle")
                                .foregroundColor(.orange)
                        }
                    }
                } header: {
                    Text("preferences")
                }

                // MARK: - Debug Section (Developer Mode Only)
                #if DEBUG
                if DeveloperMode.shared.showDebugLogsSection {
                    Section {
                        NavigationLink(destination: DebugLogsView()) {
                            Label {
                                Text("Debug Logs")
                            } icon: {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .foregroundColor(.gray)
                            }
                        }
                    } header: {
                        Text("Developer")
                    } footer: {
                        Text("Debug build only - Export logs for troubleshooting")
                    }
                }
                #endif

                // MARK: - About Section
                Section {
                    HStack {
                        Label {
                            Text("version")
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Text("Construct v\(AppConstants.appVersion)")
                            .foregroundColor(.secondary)
                            .onTapGesture {
                                // Secret: tap 10 times to enable developer mode
                                DeveloperMode.shared.registerVersionTap()
                            }
                    }
                } header: {
                    Text("about")
                }
            }
            .navigationTitle("settings")
            .onAppear {
                viewModel.setContext(viewContext)
                viewModel.loadUserInfo(from: authViewModel)
            }
            .sheet(isPresented: $showingQRCode) {
                ContactQRCodeView(
                    userId: viewModel.userId,
                    username: viewModel.username
                )
            }
            .confirmationDialog(
                "Reset All Sessions?",
                isPresented: $viewModel.showResetAllSessionsConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset All", role: .destructive) {
                    Task {
                        await ChatsViewModel().sendEndSessionToAllContacts(
                            reason: "user_requested_reset_all"
                        )
                        Log.info("✅ All sessions reset by user", category: "SettingsView")
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will reset encrypted sessions with all your contacts. They will need to send you a message to re-establish encryption.")
            }
        }
    }

    // MARK: - Contact Link
    private var contactLink: String {
        guard let userId = authViewModel.currentUserId,
              !authViewModel.currentUsername.isEmpty else {
            return ""
        }
        
        // ✅ Generate Dynamic Invite deep link (HTTPS format for sharing)
        do {
            return try inviteGenerator.generateDeepLink(userId: userId, useHTTPS: true)
        } catch {
            // ❌ Fallback to legacy format if generation fails
            let username = authViewModel.currentUsername
            let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
            return "https://konstruct.cc/c/\(userId)?username=\(encodedUsername)"
        }
    }

    private func copyContactLink() {
        UIPasteboard.general.string = contactLink
        print("Contact link copied: \(contactLink)")

        // Show visual feedback
        withAnimation {
            linkCopied = true
        }

        // Reset after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                linkCopied = false
            }
        }
    }
}

#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth()

    return SettingsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(authViewModel)
}
#endif

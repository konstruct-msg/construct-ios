//
//  AccountSettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//

import SwiftUI

struct AccountSettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var viewModel = SettingsViewModel()
    
    // Profile Picture
    @State private var showingImagePicker = false
    
    @State private var showingDeleteAccountWarning = false
    @State private var showingDeleteAccountConfirmation = false
    @State private var showingResetSessionsWarning = false
    @State private var showingDeleteKeysWarning = false
    @State private var deleteAccountPassword = ""
    @State private var deleteAccountError: String?
    
    var body: some View {
        List {
            // MARK: - Profile Picture Section
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        if let image = viewModel.profileImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 100, height: 100)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 100, height: 100)
                                .overlay {
                                    Text(viewModel.displayName.prefix(1).uppercased())
                                        .font(.system(size: 40, weight: .semibold))
                                        .foregroundColor(.blue)
                                }
                        }
                    }
                    .onTapGesture {
                        showingImagePicker = true
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            
            if !viewModel.username.isEmpty {
                Text("@\(viewModel.username)")
                    .fontWeight(.medium)
                    .foregroundColor(.gray)
            } else {
                Text(DisplayNameGenerator.generate(from: viewModel.userId))
                    .fontWeight(.medium)
                    .foregroundColor(.gray)
            }
            
            // MARK: - Account Information Section
            Section {
                TextField("display_name", text: $viewModel.displayName)
                    .onChange(of: viewModel.displayName) { newValue in
                        viewModel.saveDisplayName(newValue, authViewModel: authViewModel)
                    }
                
            } header: {
                Text("account_information")
            }
            
            
            // MARK: - Danger Zone
            Section {
                // Delete All Sessions
                Button(role: .destructive) {
                    showingResetSessionsWarning = true
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.orange)
                            Text("Reset All Sessions")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        
                        Text("Reset encrypted sessions with all contacts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 4)
                }
                
                // Delete Device Keys
                Button(role: .destructive) {
                    showingDeleteKeysWarning = true
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "key.slash.fill")
                                .foregroundColor(.orange)
                            Text("Delete Device Keys")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        
                        Text("Remove device registration and return to onboarding")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 4)
                }
                
                // Delete Account
                Button(role: .destructive) {
                    showingDeleteAccountWarning = true
                } label: {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("delete_my_account")
                                .fontWeight(.bold)
                            Spacer()
                        }
                        
                        HStack {
                            Text("delete_account_warning")
                                .font(.caption)
                                .foregroundColor(.red.opacity(0.8))
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("DANGER_ZONE")
                    .foregroundColor(.red)
            } footer: {
                Text("These actions cannot be undone. Use with caution.")
                    .font(.caption)
            }
        }
        .navigationTitle("account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.setContext(viewContext)
            viewModel.loadUserInfo(from: authViewModel)
        }
        // MARK: - Reset Sessions Dialog
        .confirmationDialog(
            "Reset All Sessions?",
            isPresented: $showingResetSessionsWarning,
            titleVisibility: .visible
        ) {
            Button("Reset All", role: .destructive) {
                Task {
                    await ChatsViewModel().sendEndSessionToAllContacts(
                        reason: "user_requested_reset_all"
                    )
                    Log.info("✅ All sessions reset by user", category: "AccountSettings")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset encrypted sessions with all your contacts. They will need to send you a message to re-establish encryption.")
        }
        // MARK: - Delete Device Keys Dialog
        .confirmationDialog(
            "Delete Device Keys?",
            isPresented: $showingDeleteKeysWarning,
            titleVisibility: .visible
        ) {
            Button("Delete Keys", role: .destructive) {
                KeychainManager.shared.deleteDeviceKeys()
                SessionManager.shared.clearSession()
                Log.info("🗑️ Device keys deleted - returning to onboarding", category: "AccountSettings")
                // Force re-check in ContentView
                NotificationCenter.default.post(name: NSNotification.Name("DeviceKeysDeleted"), object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete your device keys and session. You will need to register again. Your server account will remain active.")
        }
        // MARK: - Delete Account Dialog
        .alert("delete_account_warning_title", isPresented: $showingDeleteAccountWarning) {
            Button("cancel", role: .cancel) { }
            Button("continue", role: .destructive) {
                showingDeleteAccountWarning = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showingDeleteAccountConfirmation = true
                }
            }
        } message: {
            Text("delete_account_warning_message")
        }
        .sheet(isPresented: $showingDeleteAccountConfirmation) {
            DeleteAccountConfirmationView(
                password: $deleteAccountPassword,
                error: $deleteAccountError,
                isDeleting: authViewModel.isLoading,
                onDelete: {
                    guard !deleteAccountPassword.isEmpty else {
                        deleteAccountError = NSLocalizedString("password_required", comment: "")
                        return
                    }
                    deleteAccountError = nil
                    authViewModel.deleteAccount(password: deleteAccountPassword)
                },
                onCancel: {
                    showingDeleteAccountConfirmation = false
                    deleteAccountPassword = ""
                    deleteAccountError = nil
                }
            )
        }
        .onChange(of: authViewModel.errorMessage) { errorMessage in
            if let error = errorMessage, showingDeleteAccountConfirmation {
                deleteAccountError = error
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AccountDeleted"))) { _ in
            showingDeleteAccountConfirmation = false
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(onImagePicked: { image in
                viewModel.saveAvatar(image, authViewModel: authViewModel)
            })
        }
    }
}

// MARK: - Delete Account Confirmation View
struct DeleteAccountConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var password: String
    @Binding var error: String?
    let isDeleting: Bool
    let onDelete: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("delete_account_confirmation_message")
                        .font(.body)
                        .foregroundColor(.primary)
                } header: {
                    Text("warning")
                } footer: {
                    Text("delete_account_irreversible_warning")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
            }
            .navigationTitle("delete_my_account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        onCancel()
                        dismiss()
                    }
                    .disabled(isDeleting)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        if isDeleting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("delete_account")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isDeleting || password.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }
}

// MARK: - Image Picker
struct ImagePicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let editedImage = info[.editedImage] as? UIImage {
                parent.onImagePicked(editedImage)
            } else if let originalImage = info[.originalImage] as? UIImage {
                parent.onImagePicked(originalImage)
            }

            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    // Create sample user
    let user = User(context: context)
    user.id = "user123"
    user.username = "john_doe"
    user.displayName = "John Doe"

    try? context.save()

    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth()

    return NavigationStack {
        AccountSettingsView()
            .environment(\.managedObjectContext, context)
            .environmentObject(authViewModel)
    }
}
#endif

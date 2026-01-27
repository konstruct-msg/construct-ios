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

    // Change Password
    @State private var showingChangePassword = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordError: String?
    
    @State private var showingLogoutConfirmation = false
    @State private var showingDeleteAccountWarning = false
    @State private var showingDeleteAccountConfirmation = false
    @State private var deleteAccountPassword = ""
    @State private var deleteAccountError: String?

    private var passwordFooterText: Text {
        Text(String(format: NSLocalizedString("password_min_length_message", comment: ""), ValidationRules.minPasswordLength))
    }

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
            
            Text("@\(viewModel.username)")
                .fontWeight(.medium)
                .foregroundColor(.gray)

            // MARK: - Account Information Section
            Section {
                TextField("display_name", text: $viewModel.displayName)
                    .onChange(of: viewModel.displayName) { newValue in
                        viewModel.saveDisplayName(newValue, authViewModel: authViewModel)
                    }

            } header: {
                Text("account_information")
            }

            // MARK: - Password Section
            Section {
                if showingChangePassword {
                    SecureField("current_password", text: $currentPassword)
                        .textContentType(.password)

                    SecureField("new_password", text: $newPassword)
                        .textContentType(.newPassword)

                    SecureField("confirm_new_password", text: $confirmPassword)
                        .textContentType(.newPassword)

                    if let error = passwordError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    HStack {
                        Button("cancel") {
                            cancelPasswordChange()
                        }

                        Spacer()

                        Button("change_password") {
                            changePassword()
                        }
                        .disabled(!isPasswordValid)
                    }
                } else {
                    Button {
                        showingChangePassword = true
                    } label: {
                        Text("change_password")
                    }
                }
            } header: {
                Text("security")
            } footer: {
                if showingChangePassword {
                    passwordFooterText
                        .font(.caption)
                }
            }
            
            // MARK: - Logout Section
            Section {
                Button {
                    showingLogoutConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundColor(.blue)
                        Text("logout")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            
            // MARK: - Danger Zone
            Section {
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
            }
        }
        .navigationTitle("account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.setContext(viewContext)
            viewModel.loadUserInfo(from: authViewModel)
        }
        .alert("logout", isPresented: $showingLogoutConfirmation) {
            Button("cancel", role: .cancel) { }
            Button("logout", role: .destructive) {
                authViewModel.logout()
            }
        } message: {
            Text("logout_confirmation")
        }
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
            deleteAccountPassword = ""
            deleteAccountError = nil
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(onImagePicked: { image in
                viewModel.saveAvatar(image, authViewModel: authViewModel)
            })
        }
    }

    // MARK: - Validation
    private var isPasswordValid: Bool {
        !currentPassword.isEmpty &&
        !newPassword.isEmpty &&
        newPassword == confirmPassword &&
        newPassword.count >= ValidationRules.minPasswordLength
    }

    // MARK: - Actions
    private func changePassword() {
        guard isPasswordValid else {
            passwordError = NSLocalizedString("please_check_all_fields", comment: "")
            return
        }

        // TODO: Implement password change API call
        // For now, just clear the form
        print("Changing password for user: \(viewModel.username)")
        cancelPasswordChange()
    }

    private func cancelPasswordChange() {
        showingChangePassword = false
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        passwordError = nil
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
                
                Section {
                    SecureField("password", text: $password)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .disabled(isDeleting)
                    
                    if let errorMessage = error {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("confirm_password")
                } footer: {
                    Text("delete_account_password_hint")
                        .font(.caption)
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
    authViewModel.configureMockAuth()  // ✅ REFACTOR Phase 1.2

    return NavigationStack {
        AccountSettingsView()
            .environment(\.managedObjectContext, context)
            .environmentObject(authViewModel)
    }
}

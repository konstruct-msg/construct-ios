//
//  AuthViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import Combine
import CoreData

@MainActor
class AuthViewModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUserId: String?
    
    // ✅ REFACTOR Phase 1.2: Single source of truth - Core Data User entity
    @Published var currentUser: User?
    
    // ✅ Computed properties for convenience (backwards compatibility)
    var currentUsername: String {
        currentUser?.username ?? ""
    }
    
    var currentDisplayName: String {
        currentUser?.displayName ?? currentUser?.username ?? ""
    }
    
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()
    private var sessionRestoreTimer: Timer?
    private var authOperationTimer: Timer?
    private let viewContext: NSManagedObjectContext

    // Timer for monitoring token expiration
    nonisolated(unsafe) private var tokenRefreshTimer: Timer?

    init(context: NSManagedObjectContext) {
        self.viewContext = context
        setupSubscribers()
        startTokenRefreshMonitoring()  // ✅ FIXED: Monitor token expiration
        setupSessionExpiredListener()  // ✅ NEW: Listen for session expiration from REST API
    }
    
    // ✅ NEW: Listen for session expiration notifications from REST API
    private func setupSessionExpiredListener() {
        NotificationCenter.default.publisher(for: NSNotification.Name("SessionExpired"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSessionExpired()
            }
            .store(in: &cancellables)
    }

    deinit {
        tokenRefreshTimer?.invalidate()
    }

    private func setupSubscribers() {
        // ✅ WebSocket removed - using REST API only
        // Session expiration is handled via setupSessionExpiredListener()
    }

    // MARK: - Session Management
    func restoreSession() {
        print("🔄 restoreSession() called")
        
        // ✅ REACTIVE: Load token from keychain into published property
        SessionManager.shared.loadSessionToken()

        guard SessionManager.shared.sessionToken != nil else {
            print("❌ No session token found - user needs to login")
            return
        }

        guard let userId = SessionManager.shared.currentUserId else {
            print("❌ No current user ID found")
            return
        }
        
        // ✅ FIX: Immediately load local data on restore attempt
        loadUserFromCoreData(userId: userId)

        print("✅ Found session token for user: \(userId)")

        // ✅ FIXED: Check if token is still valid
        guard SessionManager.shared.isSessionValid else {
            print("⚠️ Stored session token has expired")
            SessionManager.shared.clearSession()
            return
        }

        print("✅ Session token is valid, attempting restore...")

        isLoading = true

        // ✅ FIXED: Verify connection to server with a quick poll request
        // This will trigger markRequestSucceeded() and set connection status to .connected
        Task {
            do {
                Log.info("📡 Verifying server connection with quick poll...", category: "AuthViewModel")
                _ = try await MessagingAPI.shared.pollMessages(sinceId: nil, timeout: 0)
                
                await MainActor.run {
                    self.isAuthenticated = true
                    self.isLoading = false
                    Log.info("✅ Session restored and server verified", category: "AuthViewModel")
                }
            } catch {
                Log.error("⚠️ Server verification failed during restore: \(error)", category: "AuthViewModel")
                
                await MainActor.run {
                    // Still mark as authenticated (we have valid token and local data)
                    // Connection status will be handled by ConnectionStatusManager
                    self.isAuthenticated = true
                    self.isLoading = false
                    Log.info("ℹ️ Session restored with local data (server unreachable)", category: "AuthViewModel")
                }
            }
        }
        
        // Load user data from Core Data
        loadUserFromCoreData(userId: userId)
        
        print("✅ Session restored successfully via REST API")
    }

    // ✅ FIXED: Monitor token expiration
    private func startTokenRefreshMonitoring() {
        // Check every minute
        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkTokenExpiration()
        }
    }

    // ✅ FIXED: Check if token needs refresh
    private func checkTokenExpiration() {
        guard isAuthenticated else { return }

        if !SessionManager.shared.isSessionValid {
            print("⚠️ Session token expired or expiring soon")
            handleSessionExpired()
        }
    }

    func register(username: String, displayName: String?, password: String) {
        isLoading = true
        errorMessage = nil

        guard let registrationBundle = CryptoManager.shared.generateRegistrationBundle() else {
            errorMessage = "Failed to generate cryptographic keys."
            isLoading = false
            return
        }

        Task {
            do {
                // Step 1: Create BundleData using globally defined structs
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                
                guard let suiteID = UInt16(registrationBundle.suiteId) else {
                    throw NSError(domain: "AuthViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid suiteId format"])
                }

                let suite = SuiteKeyMaterial(
                    suiteId: suiteID,
                    identityKey: registrationBundle.identityPublic,
                    signedPrekey: registrationBundle.signedPrekeyPublic,
                    signedPrekeySignature: registrationBundle.signature,  // ✅ Include signature for signedPrekey
                    oneTimePrekeys: [] // One-time keys are optional for the initial bundle.
                )

                let bundleData = BundleData(
                    userId: "", // User ID is empty during registration.
                    timestamp: isoFormatter.string(from: Date()),
                    supportedSuites: [suite]
                )

                // Step 2: JSON-encode BundleData. This JSON string is what gets Base64-encoded into UploadableKeyBundle.bundleData.
                let jsonEncoder = JSONEncoder()
                jsonEncoder.outputFormatting = .sortedKeys
                let bundleDataJSON = try jsonEncoder.encode(bundleData)
                
                // Step 2.5: Sign the BundleData JSON with Ed25519 signing key
                // The signature from registrationBundle is for signed_prekey, not for BundleData
                // We need to create a new signature for the BundleData JSON string
                let bundleDataSignature = try CryptoManager.shared.signBundleData(bundleDataJSON)

                // Step 3: Create the final UploadableKeyBundle.
                let uploadableBundle = UploadableKeyBundle(
                    masterIdentityKey: registrationBundle.verifyingKey,
                    bundleData: bundleDataJSON.base64EncodedString(), // This is still Base64 encoded JSON string
                    signature: bundleDataSignature
                )

                // Step 4: Send to server via REST API (new approach)
                let result = try await AuthAPI.shared.register(
                    username: username,
                    password: password,
                    publicKey: uploadableBundle
                )
                
                    // Handle success on main thread
                    await MainActor.run {
                        handleAuthSuccess(
                            userId: result.userId,
                            username: result.username,
                            token: result.sessionToken,
                            expires: result.expires
                        )
                        
                        // ✅ REMOVED: WebSocket connection - using REST API only
                    }
            } catch {
                await MainActor.run {
                    cancelTimeouts()
                    isLoading = false
                    errorMessage = "Registration failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func login(username: String, password: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Login via REST API (new approach)
                let result = try await AuthAPI.shared.login(
                    username: username,
                    password: password
                )
                
                    // Handle success on main thread
                    await MainActor.run {
                        handleAuthSuccess(
                            userId: result.userId,
                            username: result.username,
                            token: result.sessionToken,
                            expires: result.expires
                        )
                        
                        // ✅ REMOVED: WebSocket connection - using REST API only
                    }
            } catch {
                await MainActor.run {
                    cancelTimeouts()
                    isLoading = false
                    errorMessage = "Login failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func logout() {
        Task {
            // Logout via REST API
            if let token = SessionManager.shared.sessionToken {
                do {
                    try await AuthAPI.shared.logout(sessionToken: token)
                } catch {
                    Log.error("Logout API call failed: \(error.localizedDescription)", category: "Auth")
                    // Continue with local logout even if API call fails
                }
            }
            
            await MainActor.run {
                cancelTimeouts()
                SessionManager.shared.clearSession()
                
                // Note: We keep the username in Keychain for convenience on next login
                // If you want to clear it, uncomment the line below:
                // KeychainManager.shared.deleteLastUsername()
                
                isAuthenticated = false
                currentUserId = nil
                currentUser = nil  // ✅ REFACTOR Phase 1.2
            }
        }
    }
    
    func deleteAccount(password: String) {
        guard let token = SessionManager.shared.sessionToken else {
            errorMessage = "Session expired. Please login again."
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Log.info("🗑️ Requesting account deletion", category: "AuthViewModel")
        
        Task {
            do {
                try await AuthAPI.shared.deleteAccount(sessionToken: token, password: password)
                
                await MainActor.run {
                    handleDeleteAccountSuccess()
                }
            } catch {
                await MainActor.run {
                    cancelTimeouts()
                    isLoading = false
                    errorMessage = "Account deletion failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Timeout Helpers
    private func startAuthTimeout() {
        authOperationTimer?.invalidate()
        authOperationTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }
    
    private func startSessionRestoreTimeout() {
        sessionRestoreTimer?.invalidate()
        sessionRestoreTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }
    
    private func handleTimeout() {
        if isLoading && !isAuthenticated {
            isLoading = false
            errorMessage = "Connection timeout. Please check your internet and try again."
            print("⏱️ Session restore timeout - showing login screen")
        }
    }

    private func cancelTimeouts() {
        authOperationTimer?.invalidate()
        authOperationTimer = nil
        sessionRestoreTimer?.invalidate()
        sessionRestoreTimer = nil
    }

    // MARK: - State Updaters
    // ✅ WebSocket message handling removed - using REST API only
    private func handleAuthSuccess(userId: String, username: String, token: String, expires: Int64) {
        // ✅ DEBUG: Log token before saving
        Log.info("💾 Saving session token (length: \(token.count), prefix: \(token.prefix(30))...)", category: "Auth")
        
        // ✅ REACTIVE: Pass expires timestamp to SessionManager
        // This will automatically trigger @Published sessionToken update,
        // which will notify all subscribers (like ChatsViewModel)
        SessionManager.shared.saveSession(userId: userId, token: token, expires: expires)
        
        // ✅ DEBUG: Verify token was saved correctly
        if let savedToken = SessionManager.shared.sessionToken {
            if savedToken == token {
                Log.info("✅ Token saved and verified correctly", category: "Auth")
            } else {
                Log.error("❌ Token mismatch! Original length: \(token.count), Saved length: \(savedToken.count)", category: "Auth")
            }
        } else {
            Log.error("❌ Token not found after saving!", category: "Auth")
        }
        
        // ✅ Save username to Keychain for autofill convenience
        KeychainManager.shared.saveLastUsername(username)
        
        currentUserId = userId
        isAuthenticated = true
        
        // ✅ REFACTOR Phase 1.2: Load User entity and set currentUser
        // Pass username parameter so it gets saved to Core Data
        loadUserFromCoreData(userId: userId, username: username)
        
        // ✅ NEW: Request push notification permission after successful registration/login
        // This is done async to not block the auth flow
        Task {
            let granted = await PushNotificationManager.shared.requestPermission()
            if granted {
                Log.info("📱 Push notifications enabled for user", category: "Auth")
            } else {
                Log.info("📱 Push notifications declined by user", category: "Auth")
            }
        }
        
        // ✅ REMOVED: NotificationCenter - now using Combine reactive approach
        // Long polling will start automatically when sessionToken is published
    }

    private func handleConnectSuccess(userId: String, username: String) {
        print("✅ ConnectSuccess received!")
        print("   User ID: \(userId)")
        print("   Username: \(username)")

        // ✅ Save username to Keychain for autofill convenience
        KeychainManager.shared.saveLastUsername(username)

        currentUserId = userId
        isAuthenticated = true

        // ✅ REFACTOR Phase 1.2: Load User entity and set currentUser
        loadUserFromCoreData(userId: userId)
        print("✅ User authenticated successfully")
    }
    
    private func handleSessionExpired() {
        SessionManager.shared.clearSession()
        isAuthenticated = false
        errorMessage = "Session expired. Please login again."
    }
    
    private func handleDeleteAccountSuccess() {
        Log.info("✅ Account deletion successful", category: "AuthViewModel")
        cancelTimeouts()
        isLoading = false
        
        // Clear all user data
        SessionManager.shared.clearSession()
        KeychainManager.shared.deleteLastUsername()
        
        // Clear CoreData - delete all user's data
        let context = PersistenceController.shared.container.viewContext
        
        // ✅ FIX: Check if persistent store coordinator is ready before accessing entities
        guard context.persistentStoreCoordinator != nil else {
            Log.info("⚠️ Core Data persistent store coordinator not ready, skipping data deletion", category: "AuthViewModel")
            // Continue with logout even if Core Data isn't ready
            isAuthenticated = false
            currentUserId = nil
            currentUser = nil  // ✅ REFACTOR Phase 1.2
            NotificationCenter.default.post(name: NSNotification.Name("AccountDeleted"), object: nil)
            return
        }
        
        // Delete all chats and messages
        let chatFetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        if let chats = try? context.fetch(chatFetchRequest) {
            for chat in chats {
                context.delete(chat)
            }
        }
        
        // Delete all users
        let userFetchRequest: NSFetchRequest<User> = User.fetchRequest()
        if let users = try? context.fetch(userFetchRequest) {
            for user in users {
                context.delete(user)
            }
        }
        
        // Save changes
        do {
            try context.save()
            Log.info("✅ All user data deleted from CoreData", category: "AuthViewModel")
        } catch {
            Log.error("❌ Failed to delete user data from CoreData: \(error)", category: "AuthViewModel")
        }

        // Reset auth state
        isAuthenticated = false
        currentUserId = nil
        currentUser = nil  // ✅ REFACTOR Phase 1.2
        
        // Notify UI that account was deleted
        NotificationCenter.default.post(name: NSNotification.Name("AccountDeleted"), object: nil)
        
        Log.info("✅ Account deletion complete - user logged out", category: "AuthViewModel")
    }
    
    // MARK: - Core Data Integration
    
    /// Finds or creates the User entity and loads local data into the AuthViewModel
    /// - Parameters:
    ///   - userId: The user ID to load data for
    ///   - username: Optional username to update/set (from login response)
    private func loadUserFromCoreData(userId: String, username: String? = nil) {
        // ✅ FIX: Check if persistent store coordinator is ready before accessing entities
        guard viewContext.persistentStoreCoordinator != nil else {
            print("⚠️ Core Data persistent store coordinator not ready yet, skipping user load")
            return
        }
        
        // ✅ MIGRATION: First try to find user with multi-account filter
        let fetchRequest = User.fetchRequestForCurrentUser()
        let ownerPredicate = fetchRequest.predicate!
        let idPredicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, idPredicate])
        
        print("🔍 loadUserFromCoreData: Searching for userId: \(userId)")
        print("   Current ownerId from SessionManager: \(SessionManager.shared.currentUserId ?? "nil")")
        if let username = username {
            print("   Username from parameter: \(username)")
        }
        
        do {
            let user: User
            var needsSave = false
            
            if let existingUser = try viewContext.fetch(fetchRequest).first {
                user = existingUser
                print("👤 Found existing user in Core Data: \(user.displayName)")
                print("   ownerId: \(user.value(forKey: "ownerId") as? String ?? "nil")")
                
                // ✅ UPDATE: Update username if provided and different
                if let newUsername = username, !newUsername.isEmpty {
                    if user.username.isEmpty || user.username != newUsername {
                        print("🔄 Updating username: '\(user.username)' -> '\(newUsername)'")
                        user.username = newUsername
                        // Also update displayName if it's empty or was same as old username
                        if user.displayName.isEmpty || user.displayName == user.username {
                            user.displayName = newUsername
                        }
                        needsSave = true
                    }
                }
            } else {
                print("⚠️ User not found with multi-account filter, trying legacy fetch...")
                // Try to find user without owner filter (migration case)
                let legacyFetchRequest: NSFetchRequest<User> = User.fetchRequest()
                legacyFetchRequest.predicate = NSPredicate(format: "id == %@", userId)
                
                if let legacyUser = try viewContext.fetch(legacyFetchRequest).first {
                    // Found legacy user without ownerId - update it
                    print("🔄 Found legacy user with ownerId: \(legacyUser.value(forKey: "ownerId") as? String ?? "nil")")
                    legacyUser.setOwnerToCurrentUser()
                    
                    // ✅ UPDATE: Also update username if provided
                    if let newUsername = username, !newUsername.isEmpty {
                        if legacyUser.username.isEmpty || legacyUser.username != newUsername {
                            print("🔄 Updating legacy user username: '\(legacyUser.username)' -> '\(newUsername)'")
                            legacyUser.username = newUsername
                            if legacyUser.displayName.isEmpty {
                                legacyUser.displayName = newUsername
                            }
                        }
                    }
                    
                    user = legacyUser
                    needsSave = true
                    print("🔄 Migrated legacy user to current owner: \(legacyUser.displayName)")
                    print("   New ownerId: \(legacyUser.value(forKey: "ownerId") as? String ?? "nil")")
                } else {
                    print("✨ No user found, creating new user...")
                    // First login on this device, create a new User entity
                    user = User(context: viewContext)
                    user.id = userId
                    user.setOwnerToCurrentUser()  // ✅ MULTI-ACCOUNT: Set owner
                    user.username = username ?? ""  // ✅ FIX: Use parameter instead of self.currentUsername
                    user.displayName = username ?? "" // Default display name to username
                    user.isSharingWithMe = false
                    user.isBlocked = false
                    user.amISharingWith = false
                    needsSave = true
                    print("✨ Created new user in Core Data for ID: \(userId)")
                    print("   username: \(user.username)")
                    print("   ownerId: \(user.value(forKey: "ownerId") as? String ?? "nil")")
                }
            }
            
            // Save if needed
            if needsSave {
                try viewContext.save()
                print("💾 Saved user changes to Core Data")
            }
            
            // ✅ REFACTOR Phase 1.2: Set currentUser - single source of truth!
            self.currentUserId = user.id
            self.currentUser = user
            
            print("✅ Restored user data from Core Data:")
            print("   userId: \(user.id ?? "nil")")
            print("   username: \(user.username ?? "nil")")
            print("   displayName: \(user.displayName ?? "nil")")
            
            // ✅ MIGRATION: Update legacy Chats and Messages with nil ownerId
            migrateLegacyData(for: userId)
            
        } catch {
            print("❌ Failed to fetch or create user from Core Data: \(error)")
        }
    }
    
    /// Migrate legacy data (Chats, Messages, Users) without ownerId to current user
    private func migrateLegacyData(for userId: String) {
        let context = viewContext
        
        // Migrate Chats
        let chatFetch: NSFetchRequest<Chat> = Chat.fetchRequest()
        chatFetch.predicate = NSPredicate(format: "ownerId == nil")
        if let legacyChats = try? context.fetch(chatFetch) {
            for chat in legacyChats {
                chat.setOwnerToCurrentUser()
            }
            if !legacyChats.isEmpty {
                try? context.save()
                print("🔄 Migrated \(legacyChats.count) legacy chats to current owner")
            }
        }
        
        // Migrate Messages
        let messageFetch: NSFetchRequest<Message> = Message.fetchRequest()
        messageFetch.predicate = NSPredicate(format: "ownerId == nil")
        if let legacyMessages = try? context.fetch(messageFetch) {
            for message in legacyMessages {
                message.setOwnerToCurrentUser()
            }
            if !legacyMessages.isEmpty {
                try? context.save()
                print("🔄 Migrated \(legacyMessages.count) legacy messages to current owner")
            }
        }
        
        // Migrate Users (other users in chats)
        let userFetch: NSFetchRequest<User> = User.fetchRequest()
        userFetch.predicate = NSPredicate(format: "ownerId == nil AND id != %@", userId)
        if let legacyUsers = try? context.fetch(userFetch) {
            for user in legacyUsers {
                user.setOwnerToCurrentUser()
            }
            if !legacyUsers.isEmpty {
                try? context.save()
                print("🔄 Migrated \(legacyUsers.count) legacy users to current owner")
            }
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension AuthViewModel {
    /// Creates a mock User for SwiftUI previews
    static func createMockUser(context: NSManagedObjectContext, username: String = "john_doe", displayName: String = "John Doe") -> User {
        let user = User(context: context)
        user.id = UUID().uuidString
        user.username = username
        user.displayName = displayName
        user.setOwnerToCurrentUser()
        return user
    }
    
    /// Configures AuthViewModel for previews with mock data
    func configureMockAuth(username: String = "john_doe", displayName: String = "John Doe") {
        self.isAuthenticated = true
        self.currentUserId = UUID().uuidString
        self.currentUser = AuthViewModel.createMockUser(context: viewContext, username: username, displayName: displayName)
    }
}
#endif

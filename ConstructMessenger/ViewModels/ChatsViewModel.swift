//
//  ChatsViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import Combine
import CoreData
import UIKit  // ✅ Required for UIApplication notifications

@MainActor
class ChatsViewModel: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    private var viewContext: NSManagedObjectContext?

    // ✅ Store pending first messages from users we don't have sessions with yet
    private var pendingFirstMessages: [String: ChatMessage] = [:]  // [userId: firstMessage]

    // ✅ Chat ID to open programmatically (e.g., from deep link)
    @Published var chatToOpen: String?

    // ✅ Long polling state
    private var isPolling = false
    private var pollingTask: Task<Void, Never>?
    
    // ✅ Exponential backoff for error retry
    private var retryCount = 0
    private let maxRetryDelay: UInt64 = 60_000_000_000  // 60 seconds max
    
    // ✅ App lifecycle state
    private var isPaused = false
    
    // ✅ Persistent lastMessageId (survives app restart)
    private var lastMessageId: String? {
        didSet {
            if let id = lastMessageId {
                UserDefaults.standard.set(id, forKey: "construct.lastMessageId")
                Log.debug("💾 Saved lastMessageId: \(id)", category: "ChatsViewModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "construct.lastMessageId")
            }
        }
    }

    // ✅ Connection status
    private let connectionStatusManager = ConnectionStatusManager.shared

    init() {
        // ✅ Restore lastMessageId from persistent storage
        self.lastMessageId = UserDefaults.standard.string(forKey: "construct.lastMessageId")
        if let restored = lastMessageId {
            Log.info("📥 Restored lastMessageId from UserDefaults: \(restored)", category: "ChatsViewModel")
        }
        
        setupSubscribers()
        setupAppLifecycleObservers()
    }

    isolated deinit {
        stopLongPolling()
    }

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }

    private func setupSubscribers() {
        // ✅ HYBRID POLLING STRATEGY: Combine auth, connection, and push notification state
        // Automatically adjust polling behavior based on:
        // 1. Session token is available (user is authenticated)
        // 2. Connection status is .connected (network is available)
        // 3. Push notifications enabled (reduces polling frequency)
        //
        // Polling Strategy:
        // - Push ENABLED: Minimal polling (background only, ~5 min intervals)
        // - Push DISABLED: Full polling (continuous with 30s timeout)
        //
        // TODO: Phase 3 - State Machine Migration
        // This reactive approach works well but consider migrating to explicit
        // State Machine for better control over edge cases like:
        // - Offline mode (queue messages locally)
        // - Reconnection with exponential backoff
        // - Partial connectivity (WiFi without internet)
        // - Token refresh during active polling
        //
        Publishers.CombineLatest3(
            SessionManager.shared.$sessionToken,
            connectionStatusManager.$connectionStatus,
            PushNotificationManager.shared.$isPushEnabled
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] token, status, pushEnabled in
            Log.info("📡 State change: token=\(token != nil ? "present" : "nil"), status=\(status.displayText), push=\(pushEnabled)", category: "ChatsViewModel")
            
            if token != nil && status == .connected {
                if pushEnabled {
                    Log.info("📱 Push enabled - using minimal background polling", category: "ChatsViewModel")
                    // TODO: Implement minimal polling (only when app is active)
                    // For now, still do full polling but could optimize later
                    self?.startLongPolling()
                } else {
                    Log.info("📡 Push disabled - using full long-polling", category: "ChatsViewModel")
                    self?.startLongPolling()
                }
            } else {
                if token == nil {
                    Log.info("📡 No session token - stopping polling", category: "ChatsViewModel")
                } else if status != .connected {
                    Log.info("📡 Not connected (\(status.displayText)) - stopping polling", category: "ChatsViewModel")
                }
                self?.stopLongPolling()
            }
        }
        .store(in: &cancellables)
    }
    
    // MARK: - App Lifecycle
    
    private func setupAppLifecycleObservers() {
        // ✅ Pause polling when app goes to background
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Log.info("📱 App going to background - pausing polling", category: "ChatsViewModel")
                self?.isPaused = true
                self?.stopLongPolling()
            }
            .store(in: &cancellables)
        
        // ✅ Resume polling when app becomes active
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Log.info("📱 App became active - resuming polling if conditions met", category: "ChatsViewModel")
                self?.isPaused = false
                // Don't manually restart - let Combine publisher handle it
                // based on token + connection status
            }
            .store(in: &cancellables)
    }

    // MARK: - Long Polling

    func startLongPolling() {
        guard !isPolling else {
            Log.info("📡 Long polling already running, skipping duplicate start", category: "ChatsViewModel")
            return
        }
        // ✅ Token check removed - now handled by Combine publisher
        // The subscriber only calls this when token is present

        isPolling = true
        Log.info("📡 ✅ Starting long polling for messages", category: "ChatsViewModel")

        pollingTask = Task { [weak self] in
            await self?.pollMessagesLoop()
        }
    }

    func stopLongPolling() {
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
        retryCount = 0  // ✅ Reset backoff counter when stopping
        Log.info("📡 Stopped long polling", category: "ChatsViewModel")
    }

    private func pollMessagesLoop() async {
        while isPolling && !Task.isCancelled {
            do {
                // ✅ DEBUG: Log current lastMessageId before request
                if let lastId = lastMessageId {
                    Log.info("📡 Polling loop: lastMessageId=\(lastId)", category: "ChatsViewModel")
                } else {
                    Log.info("📡 Polling loop: lastMessageId is nil (first request)", category: "ChatsViewModel")
                }
                
                let response = try await MessagingAPI.shared.pollMessages(
                    sinceId: lastMessageId,
                    timeout: 30
                )

                // ✅ DEBUG: Log response summary
                Log.info("📥 Poll response: \(response.messages.count) messages, nextSince=\(response.nextSince ?? "nil"), hasMore=\(response.hasMore ?? false)", category: "ChatsViewModel")

                // Process received messages
                for messageResponse in response.messages {
                    do {
                        let chatMessage = try messageResponse.toChatMessage()
                        await MainActor.run {
                            self.handleIncomingMessage(chatMessage)
                        }
                    } catch {
                        Log.error("❌ Failed to convert message: \(error)", category: "ChatsViewModel")
                    }
                }

                // Update last message ID for next poll
                let previousLastId = lastMessageId
                if let nextSince = response.nextSince {
                    lastMessageId = nextSince
                    Log.info("✅ Updated lastMessageId from nextSince: \(previousLastId ?? "nil") -> \(nextSince)", category: "ChatsViewModel")
                } else if let lastMessage = response.messages.last {
                    lastMessageId = lastMessage.id
                    Log.info("✅ Updated lastMessageId from last message: \(previousLastId ?? "nil") -> \(lastMessage.id)", category: "ChatsViewModel")
                } else {
                    Log.info("ℹ️ No nextSince and no messages, keeping lastMessageId: \(lastMessageId ?? "nil")", category: "ChatsViewModel")
                }
                
                // ✅ Reset retry count on successful poll
                retryCount = 0

                // If there are more messages, poll again immediately
                if response.hasMore == true {
                    Log.info("🔄 hasMore=true, polling again immediately", category: "ChatsViewModel")
                    continue
                }

            } catch {
                Log.error("❌ Long polling error: \(error.localizedDescription)", category: "ChatsViewModel")
                
                // ✅ EXPONENTIAL BACKOFF: Increase delay with each consecutive failure
                // Pattern: 5s → 10s → 20s → 40s → 60s (max)
                // Prevents hammering server when it's down, saves battery
                retryCount += 1
                let baseDelay: UInt64 = 5_000_000_000  // 5 seconds
                let exponentialDelay = baseDelay * UInt64(pow(2.0, Double(min(retryCount - 1, 4))))
                
                // ✅ Add random jitter (0-2.5s) to prevent thundering herd
                // If many clients reconnect simultaneously, jitter spreads the load
                let jitter = UInt64.random(in: 0...(baseDelay / 2))
                let delay = min(exponentialDelay + jitter, maxRetryDelay)
                
                let delaySeconds = Double(delay) / 1_000_000_000.0
                Log.info("⏳ Retry attempt #\(retryCount) in \(String(format: "%.1f", delaySeconds))s (exponential backoff)", category: "ChatsViewModel")
                
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    // MARK: - Start Chat
    func startChat(with user: PublicUserInfo) -> Chat? {
        guard let context = viewContext else { return nil }

        let fetchRequest = Chat.fetchRequestForCurrentUser()
        // Combine predicates
        let chatOwnerPredicate = fetchRequest.predicate!
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", user.id)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatOwnerPredicate, otherUserPredicate])

        if let existingChat = try? context.fetch(fetchRequest).first {
            return existingChat
        }

        // ✅ FIX: Check if User already exists before creating a new one
        let userFetchRequest = User.fetchRequestForCurrentUser()
        // Combine with additional predicate
        let userOwnerPredicate = userFetchRequest.predicate!
        let idPredicate = NSPredicate(format: "id == %@", user.id)
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [userOwnerPredicate, idPredicate])

        let dbUser: User
        if let existingUser = try? context.fetch(userFetchRequest).first {
            // Use existing user - update username and displayName if they changed
            existingUser.username = user.username
            existingUser.displayName = user.username
            dbUser = existingUser
            Log.debug("Using existing user: id=\(user.id), username=\(user.username), displayName=\(existingUser.displayName)", category: "ChatsViewModel")
        } else {
            // Create new user
            dbUser = User(context: context)
            dbUser.id = user.id
            dbUser.username = user.username
            dbUser.displayName = user.username
            dbUser.isSharingWithMe = false
            dbUser.isBlocked = false
            dbUser.amISharingWith = false
            dbUser.setOwnerToCurrentUser()  // ✅ MULTI-ACCOUNT: Set owner
            Log.debug("Created new user: id=\(user.id), username=\(user.username), displayName=\(user.username)", category: "ChatsViewModel")
        }

        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = dbUser
        chat.setOwnerToCurrentUser()  // ✅ MULTI-ACCOUNT: Set owner

        do {
            try context.save()
            Log.debug("✅ Chat saved successfully", category: "ChatsViewModel")
            Log.debug("   chat.id = \(chat.id)", category: "ChatsViewModel")
            Log.debug("   chat.otherUser?.id = \(chat.otherUser?.id ?? "nil")", category: "ChatsViewModel")
            Log.debug("   chat.otherUser?.username = \(chat.otherUser?.username ?? "nil")", category: "ChatsViewModel")
            Log.debug("   chat.otherUser?.displayName = \(chat.otherUser?.displayName ?? "nil")", category: "ChatsViewModel")
        } catch {
            Log.error("❌ Failed to save chat: \(error)", category: "ChatsViewModel")
        }
        return chat
    }

    // MARK: - Delete Chat
    func deleteChat(chat: Chat) {
        guard let context = viewContext else { return }

        // ✅ CRITICAL FIX: Delete crypto session when deleting chat
        if let userId = chat.otherUser?.id {
            CryptoManager.shared.deleteSession(for: userId)
            Log.info("🗑️ Deleted crypto session for user: \(userId)", category: "ChatsViewModel")
        }

        context.delete(chat)
        try? context.save()
    }

    // MARK: - Handle Public Key Bundle (for receiving session initialization)
    private func handlePublicKeyBundle(_ data: PublicKeyBundleData) {
        Log.debug("📦 ChatsViewModel: Received publicKeyBundle for userId: \(data.userId), hasPendingMessage: \(pendingFirstMessages[data.userId] != nil)", category: "ChatsViewModel")

        // Check if we have a pending first message from this user
        guard let firstMessage = pendingFirstMessages[data.userId] else {
            // No pending message - this bundle was requested for updating username or outgoing session
            Log.debug("ChatsViewModel: No pending first message for \(data.userId) - updating username or for ChatViewModel", category: "ChatsViewModel")

            // ✅ FIX: Always update username for existing user if found (even if no pending message)
            // This handles the case when we request publicKeyBundle just to update username
            guard let context = viewContext else { return }
            
            // Find user in any chat
            let chatFetch = Chat.fetchRequestForCurrentUser()
            // Combine with additional predicate
            let ownerPredicate = chatFetch.predicate!
            let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", data.userId)
            chatFetch.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, otherUserPredicate])
            
            if let existingChat = try? context.fetch(chatFetch).first,
               let user = existingChat.otherUser {
                let oldUsername = user.username
                user.username = data.username
                user.displayName = data.username
                do {
                    try context.save()
                    Log.info("🔄 Updated username from '\(oldUsername)' to '\(data.username)' for existing user \(data.userId)", category: "ChatsViewModel")
                    // Force UI refresh by posting notification
                    NotificationCenter.default.post(name: .NSManagedObjectContextDidSave, object: context)
                } catch {
                    Log.error("❌ Failed to save username update: \(error)", category: "ChatsViewModel")
                }
            } else {
                // Try to find user directly
                let userFetch = User.fetchRequestForCurrentUser()
                // Combine with additional predicate
                let userOwnerPredicate = userFetch.predicate!
                let userIdPredicate = NSPredicate(format: "id == %@", data.userId)
                userFetch.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [userOwnerPredicate, userIdPredicate])
                
                if let existingUser = try? context.fetch(userFetch).first {
                    let oldUsername = existingUser.username
                    existingUser.username = data.username
                    existingUser.displayName = data.username
                    do {
                        try context.save()
                        Log.info("🔄 Updated username from '\(oldUsername)' to '\(data.username)' for user \(data.userId)", category: "ChatsViewModel")
                        // Force UI refresh by posting notification
                        NotificationCenter.default.post(name: .NSManagedObjectContextDidSave, object: context)
                    } catch {
                        Log.error("❌ Failed to save username update: \(error)", category: "ChatsViewModel")
                    }
                } else {
                    Log.debug("⚠️ User \(data.userId) not found in database for username update", category: "ChatsViewModel")
                }
            }
            return
        }

        Log.info("🔑 Received public key bundle for \(data.userId) - initializing receiving session", category: "ChatsViewModel")

        guard let context = viewContext else { return }
        guard SessionManager.shared.currentUserId != nil else { return }

        // Create bundle tuple
        let bundleWithSuite = (
            identityPublic: data.identityPublic,
            signedPrekeyPublic: data.signedPrekeyPublic,
            signature: data.signature,
            verifyingKey: data.verifyingKey,
            suiteId: "1"
        )

        do {
            // ✅ NEW API: Initialize receiving session returns decrypted first message
            // No need to call decryptMessage again!
            let decryptedContent = try CryptoManager.shared.initReceivingSession(
                for: data.userId,
                recipientBundle: bundleWithSuite,
                firstMessage: firstMessage
            )

            Log.info("✅ Receiving session initialized for \(data.userId), first message decrypted", category: "ChatsViewModel")

            // Find or create chat (chat was already created in handleIncomingMessage)
            let fetchRequest = Chat.fetchRequestForCurrentUser()
            // Combine with additional predicate
            let ownerPredicate = fetchRequest.predicate!
            let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", data.userId)
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, otherUserPredicate])

            let chat: Chat
            if let existingChat = try? context.fetch(fetchRequest).first {
                // Update username for existing user (it was set to GUID in handleIncomingMessage)
                if let user = existingChat.otherUser {
                    let oldUsername = user.username
                    user.username = data.username
                    user.displayName = data.username
                    Log.info("🔄 Updating username from '\(oldUsername)' to '\(data.username)' for user \(data.userId)", category: "ChatsViewModel")
                    do {
                        try context.save()  // ✅ FIX: Save updated username
                        Log.info("✅ Updated username to: \(data.username), displayName: \(user.displayName)", category: "ChatsViewModel")
                        // Force UI refresh by posting notification
                        NotificationCenter.default.post(name: .NSManagedObjectContextDidSave, object: context)
                    } catch {
                        Log.error("❌ Failed to save username update: \(error)", category: "ChatsViewModel")
                    }
                } else {
                    Log.error("❌ Chat found but otherUser is nil for userId: \(data.userId)", category: "ChatsViewModel")
                }
                chat = existingChat
            } else {
                // This shouldn't happen since handleIncomingMessage creates the chat
                // But if it does, create it with correct username from the start

                // ✅ FIX: Check if User already exists before creating
                let userFetchRequest = User.fetchRequestForCurrentUser()
                // Combine with additional predicate
                let userOwnerPredicate = userFetchRequest.predicate!
                let userIdPredicate = NSPredicate(format: "id == %@", data.userId)
                userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [userOwnerPredicate, userIdPredicate])

                let dbUser: User
                if let existingUser = try? context.fetch(userFetchRequest).first {
                    existingUser.username = data.username
                    existingUser.displayName = data.username
                    dbUser = existingUser
                    Log.debug("Using existing user in fallback: id=\(data.userId), username=\(data.username)", category: "ChatsViewModel")
                } else {
                    let newUser = User(context: context)
                    newUser.id = data.userId
                    newUser.username = data.username
                    newUser.displayName = data.username
                    newUser.isSharingWithMe = false
                    newUser.isBlocked = false
                    newUser.amISharingWith = false
                    newUser.setOwnerToCurrentUser()  // ✅ MULTI-ACCOUNT: Set owner
                    dbUser = newUser
                    Log.debug("Created new user in fallback: id=\(data.userId), username=\(data.username)", category: "ChatsViewModel")
                }

                let newChat = Chat(context: context)
                newChat.id = UUID().uuidString
                newChat.setOwnerToCurrentUser()
                newChat.otherUser = dbUser
                chat = newChat
                Log.debug("⚠️ Chat didn't exist, created new one with username: \(data.username) (this shouldn't happen)", category: "ChatsViewModel")
            }

            // Save the message
            saveMessage(for: chat, with: firstMessage, decryptedContent: decryptedContent)

            chat.lastMessageText = decryptedContent
            chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(firstMessage.timestamp))

            // Remove from pending
            pendingFirstMessages.removeValue(forKey: data.userId)

            Log.info("✅ First message from \(data.userId) decrypted and saved", category: "ChatsViewModel")

        } catch {
            Log.error("❌ Failed to initialize receiving session: \(error)", category: "ChatsViewModel")
            pendingFirstMessages.removeValue(forKey: data.userId)
        }
    }

    private func handleIncomingMessage(_ message: ChatMessage) {
        Log.debug("📨 ChatsViewModel: Incoming message \(message.id) from \(message.from)", category: "ChatsViewModel")

        guard let context = viewContext,
              let currentUserId = SessionManager.shared.currentUserId else { return }

        let otherUserId = message.from == currentUserId ? message.to : message.from

        let fetchRequest = Chat.fetchRequestForCurrentUser()
        // Combine with additional predicate
        let ownerPredicate = fetchRequest.predicate!
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", otherUserId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, otherUserPredicate])

        let chat: Chat
        let isNewChat: Bool
        if let existingChat = try? context.fetch(fetchRequest).first {
            chat = existingChat
            isNewChat = false
        } else {
            // Create a new user with only the ID (no server-stored metadata)
            // Username will be updated when we receive publicKeyBundle

            // ✅ FIX: Check if User already exists before creating
            let userFetchRequest = User.fetchRequestForCurrentUser()
            // Combine with additional predicate
            let userOwnerPredicate = userFetchRequest.predicate!
            let userIdPredicate = NSPredicate(format: "id == %@", otherUserId)
            userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [userOwnerPredicate, userIdPredicate])

            let dbUser: User
            if let existingUser = try? context.fetch(userFetchRequest).first {
                // Use existing user (shouldn't happen, but safety check)
                dbUser = existingUser
                Log.debug("Using existing user in handleIncomingMessage: id=\(otherUserId)", category: "ChatsViewModel")
            } else {
                let newUser = User(context: context)
                newUser.id = otherUserId
                newUser.setOwnerToCurrentUser() 
                newUser.username = otherUserId  // Temporary: will be updated from publicKeyBundle
                newUser.displayName = otherUserId
                newUser.isSharingWithMe = false
                newUser.isBlocked = false
                newUser.amISharingWith = false
                dbUser = newUser
                Log.debug("Created new user in handleIncomingMessage: id=\(otherUserId)", category: "ChatsViewModel")
            }
            // User display info is stored locally only, not fetched from server

            let newChat = Chat(context: context)
            newChat.id = UUID().uuidString
            newChat.setOwnerToCurrentUser()  // ✅ MULTI-ACCOUNT: Set owner
            newChat.otherUser = dbUser
            chat = newChat
            isNewChat = true

            // NOTE: If we received a message, session already exists.
            // Don't request public key here - it's for session initialization only!
        }

        // ✅ Check if we have a session for this user
        let hasSession = CryptoManager.shared.hasSession(for: otherUserId)

        let decryptedContent: String
        if !hasSession {
            // 🔑 First message from this user - need to initialize receiving session
            Log.info("📩 First message from \(otherUserId) - requesting public key bundle", category: "ChatsViewModel")

            // Store the first message temporarily
            pendingFirstMessages[otherUserId] = message

            // If we created a new chat, save it now so it appears in UI
            // Username will be updated when publicKeyBundle arrives
            if isNewChat {
                do {
                    try context.save()
                    Log.debug("✅ Saved new chat for \(otherUserId) (username will be updated when publicKeyBundle arrives)", category: "ChatsViewModel")
                } catch {
                    Log.error("❌ Failed to save new chat: \(error)", category: "ChatsViewModel")
                }
            }

            // ✅ FIXED: Request sender's public key bundle from server via REST API
            Task {
                do {
                    let publicKeyBundle = try await CryptoAPI.shared.getPublicKey(userId: otherUserId)
                    await MainActor.run {
                        self.handlePublicKeyBundleForIncomingMessage(publicKeyBundle, message: message, otherUserId: otherUserId)
                    }
                } catch {
                    await MainActor.run {
                        Log.error("❌ Failed to fetch public key for incoming message: \(error.localizedDescription)", category: "ChatsViewModel")
                    }
                }
            }

            // Exit early - we'll process this message after receiving the public key bundle
            return
        } else {
            // ✅ Existing session - decrypt normally
            guard let content = try? CryptoManager.shared.decryptMessage(message) else {
                Log.error("❌ ChatsViewModel: Failed to decrypt incoming message \(message.id)", category: "ChatsViewModel")

                // ✅ Session was corrupted and auto-deleted by CryptoManager
                // Request fresh public key bundle to reinitialize via REST API
                Log.debug("🔄 Decryption failed, session was deleted. Requesting reinitialization...", category: "ChatsViewModel")
                Task {
                    do {
                        let publicKeyBundle = try await CryptoAPI.shared.getPublicKey(userId: otherUserId)
                        await MainActor.run {
                            self.handlePublicKeyBundleForIncomingMessage(publicKeyBundle, message: message, otherUserId: otherUserId)
                        }
                    } catch {
                        await MainActor.run {
                            Log.error("❌ Failed to fetch public key for reinitialization: \(error.localizedDescription)", category: "ChatsViewModel")
                            // Store the failed message to retry after reinitialization
                            self.pendingFirstMessages[otherUserId] = message
                            Log.info("📝 Message stored for retry after session reinitialization", category: "ChatsViewModel")
                        }
                    }
                }

                return
            }
            decryptedContent = content
            
            // ✅ FIX: Check if username is still UUID (not yet updated from publicKeyBundle)
            // If username equals userId (UUID format), request publicKeyBundle to get real username
            if let user = chat.otherUser {
                let usernameIsGuid = user.username == user.id || user.username == otherUserId
                let displayNameIsGuid = user.displayName == user.id || user.displayName == otherUserId
                
                if usernameIsGuid || displayNameIsGuid {
                    // Username/displayName is still UUID - request publicKeyBundle to update it via REST API
                    Log.info("🔄 Username/displayName for user \(otherUserId) is still UUID (username=\(user.username), displayName=\(user.displayName)), requesting publicKeyBundle to update", category: "ChatsViewModel")
                    Task {
                        do {
                            let publicKeyBundle = try await CryptoAPI.shared.getPublicKey(userId: otherUserId)
                            await MainActor.run {
                                // Update username from public key bundle
                                if let chatUser = chat.otherUser {
                                    chatUser.username = publicKeyBundle.username
                                    chatUser.displayName = publicKeyBundle.username
                                    try? context.save()
                                }
                            }
                        } catch {
                            Log.error("❌ Failed to fetch public key for username update: \(error.localizedDescription)", category: "ChatsViewModel")
                        }
                    }
                }
            }
            
            // ✅ Handle profile sharing messages
            // Check if content looks like a profile message (JSON with type="profile")
            if decryptedContent.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
               let jsonData = decryptedContent.data(using: .utf8),
               let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let type = jsonDict["type"] as? String,
               type == "profile" {
                // It's a profile message - try to parse it
                if let profileData = parseProfileMessage(decryptedContent) {
                    Log.info("📥 Received profile message from \(otherUserId)", category: "ChatsViewModel")
                    handleProfileMessage(profileData, from: otherUserId)
                    // Don't save profile messages as regular chat messages
                    return
                } else {
                    // Profile message but failed to parse - don't save as regular message
                    Log.info("⚠️ Received profile message from \(otherUserId) but failed to parse, skipping", category: "ChatsViewModel")
                    return
                }
            }
        }

        saveMessage(for: chat, with: message, decryptedContent: decryptedContent)

        chat.lastMessageText = decryptedContent
        chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(message.timestamp))

        // ✅ REMOVED: ACK sending via WebSocket
        // ACK functionality can be implemented via REST API if needed in the future
        // For now, message delivery is confirmed by the server when message is successfully stored
        Log.info("📬 Message received and saved: \(message.id)", category: "ChatsViewModel")

        // ✅ REMOVED DUPLICATE: saveMessage() already calls context.save() internally
    }
    
    // MARK: - Public Key Bundle Handling
    
    /// Handle public key bundle received via REST API for incoming message
    private func handlePublicKeyBundleForIncomingMessage(_ data: PublicKeyBundleData, message: ChatMessage, otherUserId: String) {
        guard let context = viewContext else { return }
        
        Log.info("📦 Received publicKeyBundle for incoming message from userId: \(data.userId)", category: "ChatsViewModel")
        
        // Update username if we have the user in Core Data
        let userFetchRequest = User.fetchRequestForCurrentUser()
        // Combine with additional predicate
        let userOwnerPredicate = userFetchRequest.predicate!
        let userIdPredicate = NSPredicate(format: "id == %@", data.userId)
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [userOwnerPredicate, userIdPredicate])
        
        if let user = try? context.fetch(userFetchRequest).first {
            user.username = data.username
            user.displayName = data.username
            try? context.save()
            Log.info("Updated username for user: \(data.username)", category: "ChatsViewModel")
        }
        
        // Initialize receiving session (we are the recipient)
        do {
            let bundleWithSuite = (
                identityPublic: data.identityPublic,
                signedPrekeyPublic: data.signedPrekeyPublic,
                signature: data.signature,
                verifyingKey: data.verifyingKey,
                suiteId: "1"
            )
            
            // ✅ FIX: For incoming messages, we are the RECIPIENT
            // Use initReceivingSession which takes the first message and returns decrypted content
            let decryptedContent = try CryptoManager.shared.initReceivingSession(
                for: data.userId,
                recipientBundle: bundleWithSuite,
                firstMessage: message
            )
            
            Log.info("✅ Receiving session initialized for \(data.userId), message decrypted", category: "ChatsViewModel")
            
            // Process the decrypted message
            // Find or create chat
            let chatFetchRequest = Chat.fetchRequestForCurrentUser()
            // Combine with additional predicate
            let chatOwnerPredicate = chatFetchRequest.predicate!
            let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", data.userId)
            chatFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatOwnerPredicate, otherUserPredicate])
            
            if let chat = try? context.fetch(chatFetchRequest).first {
                saveMessage(for: chat, with: message, decryptedContent: decryptedContent)
                chat.lastMessageText = decryptedContent
                chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
                try? context.save()
                Log.info("✅ Successfully saved decrypted pending message", category: "ChatsViewModel")
            }
            
            // Remove from pending messages
            pendingFirstMessages.removeValue(forKey: data.userId)
            
        } catch {
            Log.error("❌ Failed to initialize receiving session: \(error.localizedDescription)", category: "ChatsViewModel")
        }
    }
    
    // MARK: - Profile Sharing
    private func parseProfileMessage(_ content: String) -> ProfileShareData? {
        guard let data = content.data(using: .utf8) else {
            Log.debug("❌ parseProfileMessage: Failed to convert content to data", category: "ChatsViewModel")
            return nil
        }
        
        // Debug: Log the content being parsed
        Log.debug("📥 Attempting to parse profile message, content length: \(content.count)", category: "ChatsViewModel")
        Log.debug("   Content preview: \(content.prefix(200))", category: "ChatsViewModel")
        
        // First, try to parse as generic JSON to check if it looks like a profile message
        if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = jsonDict["type"] as? String,
           type == "profile" {
            // It's a profile message, try to decode it properly
            do {
                let json = try JSONDecoder().decode(ProfileShareData.self, from: data)
                Log.info("✅ Successfully parsed profile message: displayName=\(json.displayName), avatarMediaId=\(json.avatarMediaId ?? "nil"), avatarData=\(json.avatarData != nil ? "present" : "nil")", category: "ChatsViewModel")
                return json
            } catch {
                Log.error("❌ parseProfileMessage: Failed to decode ProfileShareData: \(error)", category: "ChatsViewModel")
                // Even if decoding fails, we know it's a profile message, so return nil to prevent it from being saved as regular message
                return nil
            }
        }
        
        // Not a profile message
        Log.debug("❌ parseProfileMessage: Content is not a profile message", category: "ChatsViewModel")
        return nil
    }
    
    private func handleProfileMessage(_ profileData: ProfileShareData, from userId: String) {
        guard let context = viewContext else { return }
        
        let userFetchRequest = User.fetchRequestForCurrentUser()
        // Combine with additional predicate
        let ownerPredicate = userFetchRequest.predicate!
        let userIdPredicate = NSPredicate(format: "id == %@", userId)
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, userIdPredicate])
        
        guard let user = try? context.fetch(userFetchRequest).first else {
            Log.error("❌ User not found for profile update: \(userId)", category: "ChatsViewModel")
            return
        }
        
        // Update user's display name
        user.displayName = profileData.displayName
        
        // Update avatar if provided
        // Priority: new format (Media Upload API) > old format (base64)
        if let avatarMediaId = profileData.avatarMediaId,
           let avatarMediaUrl = profileData.avatarMediaUrl,
           let avatarMediaKey = profileData.avatarMediaKey {
            // New format: download and decrypt media from Media Upload API
            Task {
                do {
                    Log.info("📥 Downloading avatar from Media Upload API: \(avatarMediaId)", category: "ChatsViewModel")
                    
                    // The avatarMediaKey is base64-encoded raw key (JSON is already E2E encrypted)
                    guard let keyData = Data(base64Encoded: avatarMediaKey) else {
                        Log.error("❌ Failed to decode avatar media key", category: "ChatsViewModel")
                        return
                    }
                    
                    // Download encrypted media
                    guard let url = URL(string: avatarMediaUrl) else {
                        Log.error("❌ Invalid avatar media URL", category: "ChatsViewModel")
                        return
                    }
                    
                    let (encryptedData, response) = try await URLSession.shared.data(from: url)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        Log.error("❌ Failed to download avatar: HTTP \(statusCode)", category: "ChatsViewModel")
                        return
                    }
                    
                    // Decrypt media using the key
                    let decryptedData = try CryptoManager.shared.decryptMediaData(encryptedData, with: keyData)
                    
                    await MainActor.run {
                        user.avatarData = decryptedData
                        user.isSharingWithMe = true
                        user.sharedWithMeAt = Date()
                        
                        do {
                            try context.save()
                            Log.info("✅ Avatar downloaded and saved for user \(userId)", category: "ChatsViewModel")
                        } catch {
                            Log.error("❌ Failed to save avatar: \(error)", category: "ChatsViewModel")
                        }
                    }
                } catch {
                    Log.error("❌ Failed to download avatar: \(error.localizedDescription)", category: "ChatsViewModel")
                    // Continue - displayName was already updated
                }
            }
        } else if let avatarBase64 = profileData.avatarData,
                  let avatarData = Data(base64Encoded: avatarBase64) {
            // Old format: base64 data (backward compatibility)
            user.avatarData = avatarData
        }
        
        // Mark as sharing with us
        user.isSharingWithMe = true
        user.sharedWithMeAt = Date()
        
        // ✅ Add system message to chat
        addSystemMessageToChat(
            userId: userId,
            displayName: profileData.displayName,
            hasAvatar: profileData.avatarMediaId != nil || profileData.avatarData != nil
        )
        
        do {
            try context.save()
            Log.info("✅ Profile data updated for user \(userId): displayName=\(profileData.displayName)", category: "ChatsViewModel")
        } catch {
            Log.error("❌ Failed to save profile data: \(error)", category: "ChatsViewModel")
        }
    }
    
    /// Add system message to chat when profile is shared
    private func addSystemMessageToChat(userId: String, displayName: String, hasAvatar: Bool) {
        guard let context = viewContext else { return }
        
        // Find or create chat
        let chatFetchRequest = Chat.fetchRequestForCurrentUser()
        // Combine with additional predicate
        let ownerPredicate = chatFetchRequest.predicate!
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        chatFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, otherUserPredicate])
        
        guard let chat = try? context.fetch(chatFetchRequest).first else {
            Log.error("❌ Chat not found for user \(userId)", category: "ChatsViewModel")
            return
        }
        
        // Create system message
        let message = Message(context: context)
        message.id = UUID().uuidString
        message.setOwnerToCurrentUser()  // ✅ MULTI-ACCOUNT: Set owner
        message.timestamp = Date()
        message.chat = chat
        message.fromUserId = userId
        message.toUserId = SessionManager.shared.currentUserId ?? ""
        message.isSentByMe = false
        message.encryptedContent = ""  // System messages don't need encryption
        
        // Use special prefix to mark as system message
        let icon = hasAvatar ? "📸" : "👤"
        message.decryptedContent = "[SYSTEM]\(icon) \(displayName) shared their profile"
        
        message.deliveryStatus = .delivered
        
        // Update chat's last message
        chat.lastMessageText = message.decryptedContent?.replacingOccurrences(of: "[SYSTEM]", with: "")
        chat.lastMessageTime = message.timestamp
        
        do {
            try context.save()
            Log.info("✅ Added system message for profile share from \(userId)", category: "ChatsViewModel")
        } catch {
            Log.error("❌ Failed to save system message: \(error)", category: "ChatsViewModel")
        }
    }
    
    private func saveMessage(for chat: Chat, with messageData: ChatMessage, decryptedContent: String) {
        guard let context = viewContext else { return }

        let fetchRequest = Message.fetchRequestForCurrentUser()
        // Combine with additional predicate
        let ownerPredicate = fetchRequest.predicate!
        let messagePredicate = NSPredicate(format: "id == %@", messageData.id)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, messagePredicate])

        // ✅ Check if message already exists (from background fetch)
        if let existingMessage = try? context.fetch(fetchRequest).first {
            // ✅ Update decryptedContent if it's nil (background fetch couldn't decrypt)
            if existingMessage.decryptedContent == nil {
                Log.debug("🔄 Updating decrypted content for message \(messageData.id)", category: "ChatsViewModel")
                existingMessage.decryptedContent = decryptedContent
                
                do {
                    try context.save()
                    Log.debug("✅ Updated message decryption", category: "ChatsViewModel")
                } catch {
                    Log.error("❌ Failed to update message: \(error)", category: "ChatsViewModel")
                }
            }
            return // Message already exists and is decrypted
        }

        // ✅ Create new message
        let message = Message(context: context)
        message.id = messageData.id
        message.setOwnerToCurrentUser()  // ✅ MULTI-ACCOUNT: Set owner
        message.fromUserId = messageData.from
        message.toUserId = messageData.to
        message.encryptedContent = messageData.content
        message.decryptedContent = decryptedContent
        message.timestamp = Date(timeIntervalSince1970: TimeInterval(messageData.timestamp))
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        message.chat = chat

        do {
            try context.save()
        } catch {
            print("❌ ChatsViewModel: Failed to save message: \(error)")
        }
    }
}

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

    // ✅ Long polling manager
    private let pollingManager = LongPollingManager()
    
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
        pollingManager.stopPolling()
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
                self?.pollingManager.pause()
            }
            .store(in: &cancellables)
        
        // ✅ Resume polling when app becomes active
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Log.info("📱 App became active - resuming polling if conditions met", category: "ChatsViewModel")
                // Don't manually restart - let Combine publisher handle it
                // based on token + connection status
            }
            .store(in: &cancellables)
    }

    // MARK: - Long Polling

    func startLongPolling() {
        pollingManager.startPolling(
            getLastMessageId: { [weak self] in
                return self?.lastMessageId
            },
            updateLastMessageId: { [weak self] newId in
                self?.lastMessageId = newId
            },
            onMessagesReceived: { [weak self] messages in
                guard let self = self else { return }
                
                // Process received messages
                for messageResponse in messages {
                    do {
                        let chatMessage = try messageResponse.toChatMessage()
                        self.handleIncomingMessage(chatMessage)
                    } catch {
                        Log.error("❌ Failed to convert message: \(error)", category: "ChatsViewModel")
                    }
                }
            }
        )
    }

    func stopLongPolling() {
        pollingManager.stopPolling()
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

    // MARK: - END_SESSION Protocol
    
    /// Send END_SESSION to a specific user
    /// This notifies the peer that we're resetting the encrypted session
    func sendEndSession(to userId: String, reason: String = "manual_reset") async throws {
        Log.info("🔄 Sending END_SESSION to \(userId): \(reason)", category: "ChatsViewModel")
        
        // 1. Send END_SESSION message via API
        do {
            let response = try await MessagingAPI.shared.sendEndSession(to: userId, reason: reason)
            Log.info("✅ END_SESSION sent successfully: \(response.messageId)", category: "ChatsViewModel")
        } catch {
            Log.error("❌ Failed to send END_SESSION: \(error)", category: "ChatsViewModel")
            throw error
        }
        
        // 2. Archive local session
        CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
        
        // 3. Clear archived sessions (fresh start)
        CryptoManager.shared.clearArchivedSessions(for: userId)
        
        Log.info("✅ END_SESSION complete: session archived and cleared", category: "ChatsViewModel")
    }
    
    /// Send END_SESSION to all contacts (e.g., on logout)
    /// Best-effort delivery - continues even if some fail
    func sendEndSessionToAllContacts(reason: String = "logout") async {
        Log.info("🔄 Sending END_SESSION to all contacts: \(reason)", category: "ChatsViewModel")
        
        // Get all users with active sessions
        let sessionUserIds = CryptoManager.shared.getAllSessionUserIds()
        Log.info("📋 Found \(sessionUserIds.count) active sessions", category: "ChatsViewModel")
        
        var successCount = 0
        var failCount = 0
        
        for userId in sessionUserIds {
            do {
                try await sendEndSession(to: userId, reason: reason)
                successCount += 1
            } catch {
                Log.error("❌ Failed to send END_SESSION to \(userId): \(error)", category: "ChatsViewModel")
                failCount += 1
                // Continue anyway - best effort
            }
        }
        
        Log.info("✅ END_SESSION broadcast complete: \(successCount) sent, \(failCount) failed", category: "ChatsViewModel")
    }

    // MARK: - Delete Chat
    func deleteChat(chat: Chat) {
        guard let context = viewContext else { return }

        // ✅ CRITICAL FIX: Archive crypto session when deleting chat
        if let userId = chat.otherUser?.id {
            CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
            Log.info("🗑️ Archived crypto session for user: \(userId)", category: "ChatsViewModel")
        }

        context.delete(chat)
        try? context.save()
    }
    
    // MARK: - Handle END_SESSION
    
    /// Handle incoming END_SESSION control message
    private func handleEndSession(from userId: String) {
        Log.info("🛑 Handling END_SESSION from \(userId)", category: "ChatsViewModel")
        
        // 1. Archive the current session
        CryptoManager.shared.archiveSession(for: userId, reason: .endSessionReceived)
        Log.debug("✅ Session archived for \(userId)", category: "ChatsViewModel")
        
        // 2. Add system message to chat
        addSystemMessage(
            "Encrypted session was reset. Send a message to re-establish encryption.",
            toUserId: userId
        )
        
        // 3. Remove any pending messages for this user
        pendingFirstMessages.removeValue(forKey: userId)
        
        Log.info("✅ END_SESSION handled for \(userId)", category: "ChatsViewModel")
    }
    
    /// Add a system message to chat
    private func addSystemMessage(_ text: String, toUserId userId: String) {
        guard let context = viewContext,
              let currentUserId = SessionManager.shared.currentUserId else { return }
        
        // Find or create chat
        let fetchRequest = Chat.fetchRequestForCurrentUser()
        let ownerPredicate = fetchRequest.predicate!
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, otherUserPredicate])
        
        guard let chat = try? context.fetch(fetchRequest).first else {
            Log.error("❌ Cannot add system message: chat not found for \(userId)", category: "ChatsViewModel")
            return
        }
        
        let message = Message(context: context)
        message.id = UUID().uuidString
        message.setOwnerToCurrentUser()
        message.chat = chat
        message.fromUserId = "SYSTEM"  // ← Special sender for system messages
        message.toUserId = currentUserId
        message.encryptedContent = ""  // System messages are not encrypted
        message.decryptedContent = text
        message.suiteId = 0
        message.timestamp = Date()
        message.isSentByMe = false
        message.deliveryStatus = .delivered  // ← System messages are always "delivered"
        message.retryCount = 0
        
        chat.lastMessageText = Chat.formatPreviewText(text)
        chat.lastMessageTime = Date()
        
        do {
            try context.save()
            Log.debug("✅ System message added to chat with \(userId)", category: "ChatsViewModel")
        } catch {
            Log.error("❌ Failed to save system message: \(error)", category: "ChatsViewModel")
        }
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
        
        // 🆕 Track prekey ID and detect reinstall
        // Use signedPrekeyPublic as the prekey identifier
        let prekeyChanged = CryptoManager.shared.trackPreKeyId(data.signedPrekeyPublic, for: data.userId)
        if prekeyChanged {
            Log.info("⚠️ Prekey changed for \(data.userId) - potential reinstall detected!", category: "ChatsViewModel")
            // Session was already archived by trackPreKeyId()
        }

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

            chat.lastMessageText = Chat.formatPreviewText(decryptedContent)
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
        
        // 1. Check if this is an END_SESSION control message
        if message.isEndSession {
            Log.info("🛑 Received END_SESSION from \(otherUserId)", category: "ChatsViewModel")
            handleEndSession(from: otherUserId)
            return
        }

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
        Log.info("🔐 SESSION_STATE[incoming_message]: userId=\(otherUserId.prefix(8))..., hasSession=\(hasSession), messageId=\(message.id.prefix(8))...", category: "SessionInit")

        let decryptedContent: String
        if !hasSession {
            // 🔑 First message from this user - need to initialize receiving session
            Log.info("📩 First message from \(otherUserId) - requesting public key bundle", category: "ChatsViewModel")
            Log.info("🔐 SESSION_STATE[first_message]: userId=\(otherUserId.prefix(8))..., action=fetch_bundle", category: "SessionInit")

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
            let fetchStartTime = Date()
            Task {
                do {
                    let publicKeyBundle = try await fetchPublicKeyWithRetry(userId: otherUserId)
                    let fetchDuration = Date().timeIntervalSince(fetchStartTime)
                    Log.info("🔐 SESSION_STATE[bundle_fetched]: userId=\(otherUserId.prefix(8))..., duration=\(String(format: "%.2f", fetchDuration))s", category: "SessionInit")
                    
                    await MainActor.run {
                        self.handlePublicKeyBundleForIncomingMessage(publicKeyBundle, message: message, otherUserId: otherUserId)
                    }
                } catch {
                    let fetchDuration = Date().timeIntervalSince(fetchStartTime)
                    Log.error("🔐 SESSION_STATE[bundle_fetch_failed]: userId=\(otherUserId.prefix(8))..., duration=\(String(format: "%.2f", fetchDuration))s, error=\(error.localizedDescription)", category: "SessionInit")
                    
                    await MainActor.run {
                        Log.error("❌ Failed to fetch public key for incoming message after retries: \(error.localizedDescription)", category: "ChatsViewModel")
                    }
                }
            }

            // Exit early - we'll process this message after receiving the public key bundle
            return
        } else {
            // ✅ Existing session - decrypt normally
            Log.info("🔐 SESSION_STATE[decrypt_attempt]: userId=\(otherUserId.prefix(8))..., hasSession=true", category: "SessionInit")
            
            guard let content = try? CryptoManager.shared.decryptMessage(message) else {
                Log.error("❌ ChatsViewModel: Failed to decrypt incoming message \(message.id)", category: "ChatsViewModel")
                Log.error("🔐 SESSION_STATE[decrypt_failed]: userId=\(otherUserId.prefix(8))..., messageId=\(message.id.prefix(8))...", category: "SessionInit")

                // ✅ Session was corrupted and auto-deleted by CryptoManager
                // Request fresh public key bundle to reinitialize via REST API
                Log.debug("🔄 Decryption failed, session was deleted. Requesting reinitialization...", category: "ChatsViewModel")
                Log.info("🔐 SESSION_STATE[reinit_start]: userId=\(otherUserId.prefix(8))..., reason=decrypt_failed", category: "SessionInit")
                
                Task {
                    do {
                        let publicKeyBundle = try await fetchPublicKeyWithRetry(userId: otherUserId)
                        Log.info("🔐 SESSION_STATE[bundle_fetched]: userId=\(otherUserId.prefix(8))..., success=true", category: "SessionInit")
                        await MainActor.run {
                            self.handlePublicKeyBundleForIncomingMessage(publicKeyBundle, message: message, otherUserId: otherUserId)
                        }
                    } catch {
                        Log.error("🔐 SESSION_STATE[bundle_fetch_failed]: userId=\(otherUserId.prefix(8))..., error=\(error.localizedDescription)", category: "SessionInit")
                        await MainActor.run {
                            Log.error("❌ Failed to fetch public key for reinitialization after retries: \(error.localizedDescription)", category: "ChatsViewModel")
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
                            let publicKeyBundle = try await fetchPublicKeyWithRetry(userId: otherUserId)
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
                if let profileData = ProfileSharingManager.shared.parseProfileMessage(decryptedContent) {
                    Log.info("📥 Received profile message from \(otherUserId)", category: "ChatsViewModel")
                    ProfileSharingManager.shared.handleProfileMessage(profileData, from: otherUserId, in: viewContext!)
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

        chat.lastMessageText = Chat.formatPreviewText(decryptedContent)
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
        
        // 🆕 Track prekey ID and detect reinstall
        // Use signedPrekeyPublic as the prekey identifier
        let prekeyChanged = CryptoManager.shared.trackPreKeyId(data.signedPrekeyPublic, for: data.userId)
        if prekeyChanged {
            Log.info("⚠️ Prekey changed for \(data.userId) - potential reinstall detected!", category: "ChatsViewModel")
            // Session was already archived by trackPreKeyId()
        }
        
        // Initialize receiving session (we are the recipient)
        let initStartTime = Date()
        Log.info("🔐 SESSION_STATE[init_receiving_start]: userId=\(data.userId.prefix(8))..., prekeyChanged=\(prekeyChanged)", category: "SessionInit")
        
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
            
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.info("✅ Receiving session initialized for \(data.userId), message decrypted", category: "ChatsViewModel")
            Log.info("🔐 SESSION_STATE[init_receiving_success]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s", category: "SessionInit")
            
            // Process the decrypted message
            // Find or create chat
            let chatFetchRequest = Chat.fetchRequestForCurrentUser()
            // Combine with additional predicate
            let chatOwnerPredicate = chatFetchRequest.predicate!
            let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", data.userId)
            chatFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatOwnerPredicate, otherUserPredicate])
            
            if let chat = try? context.fetch(chatFetchRequest).first {
                saveMessage(for: chat, with: message, decryptedContent: decryptedContent)
                chat.lastMessageText = Chat.formatPreviewText(decryptedContent)
                chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
                try? context.save()
                Log.info("✅ Successfully saved decrypted pending message", category: "ChatsViewModel")
            }
            
            // Remove from pending messages - success!
            pendingFirstMessages.removeValue(forKey: data.userId)
            
        } catch CryptoError.SessionInitializationFailed(let message) {
            // Log detailed error from Rust core
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.error("❌ Session initialization failed: \(message)", category: "ChatsViewModel")
            Log.error("🔐 SESSION_STATE[init_receiving_failed]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s, error=SessionInitializationFailed", category: "SessionInit")
            Log.info("🔄 Keeping message in pending for retry", category: "ChatsViewModel")
            // KEEP in pending for retry - don't remove!
            
        } catch {
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.error("❌ Failed to initialize receiving session: \(error.localizedDescription)", category: "ChatsViewModel")
            Log.error("🔐 SESSION_STATE[init_receiving_failed]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s, error=\(error.localizedDescription)", category: "SessionInit")
            Log.info("🔄 Keeping message in pending for retry", category: "ChatsViewModel")
            // Other errors: keep in pending for retry
        }
    }
    
    // MARK: - Session Initialization Utilities
    
    /// Fetch public key bundle with retry and exponential backoff
    /// - Parameters:
    ///   - userId: Target user ID
    ///   - maxAttempts: Maximum retry attempts (default: 3)
    ///   - initialDelay: Initial retry delay in seconds (default: 1.0)
    /// - Returns: Public key bundle data
    /// - Throws: Last error if all attempts fail
    private func fetchPublicKeyWithRetry(
        userId: String,
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0
    ) async throws -> PublicKeyBundleData {
        var lastError: Error?
        var delay = initialDelay
        
        for attempt in 1...maxAttempts {
            do {
                Log.info("🔑 SESSION_STATE[fetch_bundle_attempt_\(attempt)]: userId=\(userId.prefix(8))..., maxAttempts=\(maxAttempts)", category: "SessionInit")
                let bundle = try await CryptoAPI.shared.getPublicKey(userId: userId)
                Log.info("✅ SESSION_STATE[fetch_bundle_success]: userId=\(userId.prefix(8))..., attempt=\(attempt)", category: "SessionInit")
                return bundle
            } catch {
                lastError = error
                Log.info("⚠️ SESSION_STATE[fetch_bundle_failed]: attempt=\(attempt)/\(maxAttempts), error=\(error.localizedDescription)", category: "SessionInit")
                
                if attempt < maxAttempts {
                    Log.info("⏳ Retrying public key fetch in \(delay)s...", category: "SessionInit")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= 2  // Exponential backoff: 1s, 2s, 4s
                }
            }
        }
        
        Log.error("❌ SESSION_STATE[fetch_bundle_exhausted]: userId=\(userId.prefix(8))..., allAttemptsFailed", category: "SessionInit")
        throw lastError ?? NetworkError.connectionFailed
    }
    
    // MARK: - Message Persistence
    
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

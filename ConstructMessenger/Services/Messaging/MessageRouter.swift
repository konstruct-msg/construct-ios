//
//  MessageRouter.swift
//  Construct Messenger
//
//  Routes and processes incoming messages
//  Extracted from ChatsViewModel as part of Phase 1.4 refactoring
//  Created on 2026-02-01
//

import Foundation
import CoreData

/// Routes and processes incoming messages
@MainActor
class MessageRouter {
    
    // MARK: - Callbacks
    
    /// Called when a new chat is created
    var onChatCreated: ((Chat) -> Void)?
    
    /// Called when username needs updating
    var onUsernameUpdateNeeded: ((String) -> Void)?
    
    /// Called when public key bundle is needed for session initialization
    var onPublicKeyBundleNeeded: ((String, ChatMessage) -> Void)?
    
    // MARK: - Message Routing
    
    /// Route incoming message to appropriate handler
    /// - Parameters:
    ///   - message: Incoming chat message
    ///   - context: Core Data context
    ///   - pendingMessages: Dictionary of pending first messages
    func routeIncomingMessage(
        _ message: ChatMessage,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: ChatMessage]
    ) {
        guard let currentUserId = SessionManager.shared.currentUserId else { return }
        
        let otherUserId = message.from == currentUserId ? message.to : message.from
        
        // 1. Check if this is an END_SESSION control message
        if message.isEndSession {
            Log.info("🛑 Received END_SESSION from \(otherUserId)", category: "MessageRouter")
            handleEndSession(from: otherUserId, in: context, pendingMessages: &pendingMessages)
            return
        }
        
        // 2. Find or create chat
        let (chat, isNewChat) = findOrCreateChat(for: otherUserId, in: context)
        
        // 3. Check if we have a session for this user
        let hasSession = CryptoManager.shared.hasSession(for: otherUserId)
        Log.info("🔐 SESSION_STATE[incoming_message]: userId=\(otherUserId.prefix(8))..., hasSession=\(hasSession), messageId=\(message.id.prefix(8))...", category: "SessionInit")
        
        let decryptedContent: String
        if !hasSession {
            // First message from this user - need to initialize receiving session
            handleFirstMessage(
                message,
                from: otherUserId,
                chat: chat,
                isNewChat: isNewChat,
                in: context,
                pendingMessages: &pendingMessages
            )
            return
        } else {
            // Existing session - decrypt normally
            decryptedContent = handleMessageWithSession(
                message,
                from: otherUserId,
                chat: chat,
                in: context,
                pendingMessages: &pendingMessages
            ) ?? ""
            
            // If decryption failed, handleMessageWithSession already initiated recovery
            if decryptedContent.isEmpty {
                return
            }
        }
        
        // 4. Check for special message types (profile sharing, etc.)
        if let specialMessageHandled = handleSpecialMessage(
            decryptedContent,
            from: otherUserId,
            in: context
        ), specialMessageHandled {
            return  // Special message handled, don't save as regular message
        }
        
        // 5. Save regular message
        saveMessage(for: chat, with: message, decryptedContent: decryptedContent, in: context)
        
        // 6. Update chat metadata
        chat.lastMessageText = Chat.formatPreviewText(decryptedContent)
        chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        
        Log.info("📬 Message received and saved: \(message.id)", category: "MessageRouter")
    }
    
    // MARK: - Chat Management
    
    /// Find or create chat for user
    /// - Parameters:
    ///   - userId: User ID
    ///   - context: Core Data context
    /// - Returns: Tuple of (chat, isNewChat)
    private func findOrCreateChat(
        for userId: String,
        in context: NSManagedObjectContext
    ) -> (Chat, Bool) {
        let fetchRequest = Chat.fetchRequestForCurrentUser()
        let ownerPredicate = fetchRequest.predicate!
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, otherUserPredicate])
        
        if let existingChat = try? context.fetch(fetchRequest).first {
            return (existingChat, false)
        }
        
        // Create new user and chat
        let user = findOrCreateUser(for: userId, in: context)
        
        let newChat = Chat(context: context)
        newChat.id = UUID().uuidString
        newChat.setOwnerToCurrentUser()
        newChat.otherUser = user
        
        return (newChat, true)
    }
    
    /// Find or create user
    /// - Parameters:
    ///   - userId: User ID
    ///   - context: Core Data context
    /// - Returns: User entity
    private func findOrCreateUser(
        for userId: String,
        in context: NSManagedObjectContext
    ) -> User {
        let userFetchRequest = User.fetchRequestForCurrentUser()
        let userOwnerPredicate = userFetchRequest.predicate!
        let userIdPredicate = NSPredicate(format: "id == %@", userId)
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [userOwnerPredicate, userIdPredicate])
        
        if let existingUser = try? context.fetch(userFetchRequest).first {
            Log.debug("Using existing user: id=\(userId)", category: "MessageRouter")
            return existingUser
        }
        
        // Create new user with temporary username (will be updated from publicKeyBundle)
        let newUser = User(context: context)
        newUser.id = userId
        newUser.setOwnerToCurrentUser()
        newUser.username = userId  // Temporary
        newUser.displayName = userId
        newUser.isSharingWithMe = false
        newUser.isBlocked = false
        newUser.amISharingWith = false
        
        Log.debug("Created new user: id=\(userId)", category: "MessageRouter")
        return newUser
    }
    
    // MARK: - First Message Handling
    
    /// Handle first message from user (no session yet)
    private func handleFirstMessage(
        _ message: ChatMessage,
        from userId: String,
        chat: Chat,
        isNewChat: Bool,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: ChatMessage]
    ) {
        Log.info("📩 First message from \(userId) - requesting public key bundle", category: "MessageRouter")
        Log.info("🔐 SESSION_STATE[first_message]: userId=\(userId.prefix(8))..., action=fetch_bundle", category: "SessionInit")
        
        // Store the first message temporarily
        pendingMessages[userId] = message
        
        // If we created a new chat, save it now so it appears in UI
        if isNewChat {
            do {
                try context.save()
                Log.debug("✅ Saved new chat for \(userId)", category: "MessageRouter")
                onChatCreated?(chat)
            } catch {
                Log.error("❌ Failed to save new chat: \(error)", category: "MessageRouter")
            }
        }
        
        // Request public key bundle via callback
        onPublicKeyBundleNeeded?(userId, message)
    }
    
    // MARK: - Session Message Handling
    
    /// Handle message when session exists
    /// - Returns: Decrypted content or nil if failed
    private func handleMessageWithSession(
        _ message: ChatMessage,
        from userId: String,
        chat: Chat,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: ChatMessage]
    ) -> String? {
        Log.info("🔐 SESSION_STATE[decrypt_attempt]: userId=\(userId.prefix(8))..., hasSession=true", category: "SessionInit")
        
        guard let content = try? CryptoManager.shared.decryptMessage(message) else {
            Log.error("❌ Failed to decrypt incoming message \(message.id)", category: "MessageRouter")
            Log.error("🔐 SESSION_STATE[decrypt_failed]: userId=\(userId.prefix(8))..., messageId=\(message.id.prefix(8))...", category: "SessionInit")
            
            // Session was corrupted - reinitialize
            Log.debug("🔄 Decryption failed, requesting reinitialization...", category: "MessageRouter")
            Log.info("🔐 SESSION_STATE[reinit_start]: userId=\(userId.prefix(8))..., reason=decrypt_failed", category: "SessionInit")
            
            // Store message for retry
            pendingMessages[userId] = message
            
            // Request public key bundle via callback
            onPublicKeyBundleNeeded?(userId, message)
            
            return nil
        }
        
        // Check if username is still UUID - request update if needed
        checkUsernameUpdate(for: userId, chat: chat, in: context)
        
        return content
    }
    
    /// Check if username needs updating
    private func checkUsernameUpdate(
        for userId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        guard let user = chat.otherUser else { return }
        
        let usernameIsGuid = user.username == user.id || user.username == userId
        let displayNameIsGuid = user.displayName == user.id || user.displayName == userId
        
        if usernameIsGuid || displayNameIsGuid {
            Log.info("🔄 Username for \(userId) is still UUID, requesting update", category: "MessageRouter")
            onUsernameUpdateNeeded?(userId)
        }
    }
    
    // MARK: - Special Message Types
    
    /// Handle special message types (profile, etc.)
    /// - Returns: true if special message was handled
    private func handleSpecialMessage(
        _ decryptedContent: String,
        from userId: String,
        in context: NSManagedObjectContext
    ) -> Bool? {
        // Check for profile message
        if decryptedContent.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
           let jsonData = decryptedContent.data(using: .utf8),
           let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let type = jsonDict["type"] as? String,
           type == "profile" {
            
            if let profileData = ProfileSharingManager.shared.parseProfileMessage(decryptedContent) {
                Log.info("📥 Received profile message from \(userId)", category: "MessageRouter")
                ProfileSharingManager.shared.handleProfileMessage(profileData, from: userId, in: context)
                return true
            } else {
                Log.info("⚠️ Failed to parse profile message from \(userId), skipping", category: "MessageRouter")
                return true  // Still skip saving as regular message
            }
        }
        
        return false  // Not a special message
    }
    
    // MARK: - END_SESSION Handling
    
    /// Handle END_SESSION message
    private func handleEndSession(
        from userId: String,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: ChatMessage]
    ) {
        Log.info("🛑 Handling END_SESSION from \(userId)", category: "MessageRouter")
        
        // 1. Archive the current session
        CryptoManager.shared.archiveSession(for: userId, reason: .endSessionReceived)
        Log.debug("✅ Session archived for \(userId)", category: "MessageRouter")
        
        // 2. Add system message to chat
        addSystemMessage(
            "Encrypted session was reset. Send a message to re-establish encryption.",
            toUserId: userId,
            in: context
        )
        
        // 3. Remove any pending messages for this user
        pendingMessages.removeValue(forKey: userId)
        
        Log.info("✅ END_SESSION handled for \(userId)", category: "MessageRouter")
    }
    
    /// Add a system message to chat
    private func addSystemMessage(
        _ text: String,
        toUserId userId: String,
        in context: NSManagedObjectContext
    ) {
        guard let currentUserId = SessionManager.shared.currentUserId else { return }
        
        // Find chat
        let fetchRequest = Chat.fetchRequestForCurrentUser()
        let ownerPredicate = fetchRequest.predicate!
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, otherUserPredicate])
        
        guard let chat = try? context.fetch(fetchRequest).first else {
            Log.error("❌ Cannot add system message: chat not found for \(userId)", category: "MessageRouter")
            return
        }
        
        let message = Message(context: context)
        message.id = UUID().uuidString
        message.setOwnerToCurrentUser()
        message.chat = chat
        message.fromUserId = "SYSTEM"
        message.toUserId = currentUserId
        message.encryptedContent = ""
        message.decryptedContent = text
        message.suiteId = 0
        message.timestamp = Date()
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        
        chat.lastMessageText = Chat.formatPreviewText(text)
        chat.lastMessageTime = Date()
        
        do {
            try context.save()
            Log.debug("✅ System message added to chat with \(userId)", category: "MessageRouter")
        } catch {
            Log.error("❌ Failed to save system message: \(error)", category: "MessageRouter")
        }
    }
    
    // MARK: - Message Persistence
    
    /// Save message to Core Data
    private func saveMessage(
        for chat: Chat,
        with messageData: ChatMessage,
        decryptedContent: String,
        in context: NSManagedObjectContext
    ) {
        let fetchRequest = Message.fetchRequestForCurrentUser()
        let ownerPredicate = fetchRequest.predicate!
        let messagePredicate = NSPredicate(format: "id == %@", messageData.id)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, messagePredicate])
        
        // Check if message already exists (from background fetch)
        if let existingMessage = try? context.fetch(fetchRequest).first {
            // Update decryptedContent if it's nil
            if existingMessage.decryptedContent == nil {
                Log.debug("🔄 Updating decrypted content for message \(messageData.id)", category: "MessageRouter")
                existingMessage.decryptedContent = decryptedContent
                
                do {
                    try context.save()
                    Log.debug("✅ Updated message decryption", category: "MessageRouter")
                } catch {
                    Log.error("❌ Failed to update message: \(error)", category: "MessageRouter")
                }
            }
            return  // Message already exists
        }
        
        // Create new message
        let message = Message(context: context)
        message.id = messageData.id
        message.setOwnerToCurrentUser()
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
            Log.error("❌ Failed to save message: \(error)", category: "MessageRouter")
        }
    }
}

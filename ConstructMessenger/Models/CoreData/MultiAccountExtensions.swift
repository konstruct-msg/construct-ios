//
//  Chat+Extensions.swift
//  Construct Messenger
//
//  Multi-account support extensions
//

import Foundation
import CoreData

extension Chat {
    /// Create a fetch request filtered by current user's ID
    /// This ensures multi-account support - only show chats for current logged-in user
    static func fetchRequestForCurrentUser() -> NSFetchRequest<Chat> {
        let request: NSFetchRequest<Chat> = Chat.fetchRequest()
        
        // ✅ SECURITY: Filter by current user's ID
        if let currentUserId = SessionManager.shared.currentUserId {
            request.predicate = NSPredicate(format: "ownerId == %@", currentUserId)
            Log.debug("📋 Fetching chats for user: \(currentUserId)", category: "CoreData")
        } else {
            // No user logged in - return empty predicate that matches nothing
            request.predicate = NSPredicate(value: false)
            Log.info("⚠️ No current user - fetching no chats", category: "CoreData")
        }
        
        return request
    }
    
    /// Set owner ID to current user when creating new chat
    func setOwnerToCurrentUser() {
        guard let currentUserId = SessionManager.shared.currentUserId else {
            Log.error("❌ Cannot set ownerId - no current user", category: "CoreData")
            return
        }
        
        // ✅ Use setValue for dynamic property setting (Core Data might not have generated property yet)
        self.setValue(currentUserId, forKey: "ownerId")
        Log.debug("✅ Set chat ownerId to: \(currentUserId)", category: "CoreData")
    }
}

extension Message {
    /// Create a fetch request filtered by current user's ID
    static func fetchRequestForCurrentUser() -> NSFetchRequest<Message> {
        let request: NSFetchRequest<Message> = Message.fetchRequest()
        
        // ✅ SECURITY: Filter by current user's ID
        if let currentUserId = SessionManager.shared.currentUserId {
            request.predicate = NSPredicate(format: "ownerId == %@", currentUserId)
        } else {
            // No user logged in - return empty predicate
            request.predicate = NSPredicate(value: false)
        }
        
        return request
    }
    
    /// Set owner ID to current user when creating new message
    func setOwnerToCurrentUser() {
        guard let currentUserId = SessionManager.shared.currentUserId else {
            Log.error("❌ Cannot set ownerId - no current user", category: "CoreData")
            return
        }
        
        // ✅ Use setValue for dynamic property setting
        self.setValue(currentUserId, forKey: "ownerId")
    }
}

extension User {
    /// Create a fetch request filtered by current user's ID
    static func fetchRequestForCurrentUser() -> NSFetchRequest<User> {
        let request: NSFetchRequest<User> = User.fetchRequest()
        
        // ✅ SECURITY: Filter by current user's ID
        if let currentUserId = SessionManager.shared.currentUserId {
            request.predicate = NSPredicate(format: "ownerId == %@", currentUserId)
        } else {
            // No user logged in - return empty predicate
            request.predicate = NSPredicate(value: false)
        }
        
        return request
    }
    
    /// Set owner ID to current user when creating new user
    func setOwnerToCurrentUser() {
        guard let currentUserId = SessionManager.shared.currentUserId else {
            Log.error("❌ Cannot set ownerId - no current user", category: "CoreData")
            return
        }
        
        // ✅ Use setValue for dynamic property setting
        self.setValue(currentUserId, forKey: "ownerId")
    }
}

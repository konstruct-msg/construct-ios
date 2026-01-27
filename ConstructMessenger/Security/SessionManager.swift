//
//  SessionManager.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import Combine

// TODO: Phase 3 Architecture Refactoring - State Machine
// ============================================================================
// Current approach uses reactive publishers for auth state synchronization.
// For better scalability and maintainability, consider migrating to explicit
// State Machine pattern:
//
// enum AuthState {
//     case unauthenticated
//     case authenticating
//     case authenticated(token: String, userId: String, expires: Date)
// }
//
// Benefits:
// - Impossible states become impossible (can't have token without userId)
// - Explicit state transitions with validation
// - Easier to add offline mode, reconnection logic
// - Better testability and debugging
// - Clear separation of concerns
//
// See: docs/architecture/state-machine-migration.md (to be created)
// ============================================================================

class SessionManager: ObservableObject {
    static let shared = SessionManager()
    private init() {}

    // ✅ REACTIVE: Published property for session token
    // This allows downstream components to react to token changes automatically
    @Published private(set) var sessionToken: String?
    
    var currentUserId: String? {
        KeychainManager.shared.loadUserId()
    }

    // ✅ FIXED: Get session expiration timestamp
    var sessionExpires: Date? {
        guard let timestamp = UserDefaults.standard.object(forKey: UserDefaultsKey.sessionExpires.key) as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    // ✅ FIXED: Check if session is valid (not expired)
    var isSessionValid: Bool {
        guard sessionToken != nil, currentUserId != nil else { return false }

        // Check expiration (with 5-minute buffer)
        guard let expires = sessionExpires else { return false }
        let bufferTime: TimeInterval = 5 * 60  // 5 minutes
        return Date().addingTimeInterval(bufferTime) < expires
    }

    // ✅ Load token from keychain on init or when needed
    func loadSessionToken() {
        sessionToken = KeychainManager.shared.loadSessionToken()
    }

    // ✅ FIXED: Save session with expiration timestamp
    func saveSession(userId: String, token: String, expires: Int64) {
        KeychainManager.shared.saveUserId(userId)
        KeychainManager.shared.saveSessionToken(token)
        
        // ✅ FIX: Check if expires is in seconds or milliseconds
        // Unix timestamp can be in seconds (10 digits) or milliseconds (13 digits)
        let expiresTimeInterval: TimeInterval
        if expires > 1_000_000_000_000 {
            // Timestamp is in milliseconds (13+ digits)
            expiresTimeInterval = TimeInterval(expires) / 1000.0
            print("⚠️ Expires timestamp appears to be in milliseconds, converting to seconds")
        } else {
            // Timestamp is in seconds (10 digits)
            expiresTimeInterval = TimeInterval(expires)
        }
        
        // Save expiration timestamp
        UserDefaults.standard.set(expiresTimeInterval, forKey: UserDefaultsKey.sessionExpires.key)
        
        let expiresDate = Date(timeIntervalSince1970: expiresTimeInterval)
        print("✅ Session saved - expires at: \(expiresDate)")
        print("   Raw expires value: \(expires)")
        print("   Expires in: \(Int(expiresDate.timeIntervalSinceNow / 60)) minutes")
        
        // ✅ REACTIVE: Update published property to trigger subscribers
        self.sessionToken = token
    }

    func clearSession() {
        KeychainManager.shared.deleteSessionToken()
        // Clear expiration timestamp
        UserDefaults.standard.removeObject(forKey: UserDefaultsKey.sessionExpires.key)
        
        // ✅ REACTIVE: Clear published property to trigger subscribers
        self.sessionToken = nil
        // Note: We keep currentUserId so user data persists in Core Data
    }
}

//
//  AuthAPI.swift
//  Construct Messenger
//
//  Authentication and account management API
//  Created on 26.01.2026 (Phase 2.1 refactoring)
//

import Foundation

/// Authentication and account management endpoints
class AuthAPI {
    static let shared = AuthAPI()
    
    private let client = RestAPIClient.shared
    
    private init() {}
    
    // MARK: - Authentication Endpoints
    
    /// Register a new user
    /// POST /api/v1/auth/register
    func register(username: String, password: String, publicKey: UploadableKeyBundle) async throws -> RegisterSuccessData {
        let endpoint = "/api/v1/auth/register"
        
        let requestBody: [String: Any] = [
            "username": username,
            "password": password,
            "keyBundle": [
                "masterIdentityKey": publicKey.masterIdentityKey,
                "bundleData": publicKey.bundleData,
                "signature": publicKey.signature
            ]
        ]
        
        let response: AuthResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody
        )
        
        return RegisterSuccessData(
            userId: response.userId,
            username: username,
            sessionToken: response.accessToken,
            expires: response.expiresAt
        )
    }
    
    /// Login with username and password
    /// POST /api/v1/auth/login
    func login(username: String, password: String) async throws -> LoginSuccessData {
        let endpoint = "/api/v1/auth/login"
        let requestBody: [String: Any] = [
            "username": username,
            "password": password
        ]
        
        let response: AuthResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody
        )
        
        Log.info("📥 Login response received:", category: "Network")
        Log.info("   userId: \(response.userId)", category: "Network")
        Log.info("   accessToken length: \(response.accessToken.count)", category: "Network")
        Log.info("   expiresAt: \(response.expiresAt) (raw value)", category: "Network")
        
        // Check if expiresAt is in seconds or milliseconds
        let expiresDate: Date
        if response.expiresAt > 1_000_000_000_000 {
            expiresDate = Date(timeIntervalSince1970: TimeInterval(response.expiresAt) / 1000.0)
            Log.info("   Interpreting as milliseconds", category: "Network")
        } else {
            expiresDate = Date(timeIntervalSince1970: TimeInterval(response.expiresAt))
            Log.info("   Interpreting as seconds", category: "Network")
        }
        Log.info("   Expires at: \(expiresDate)", category: "Network")
        Log.info("   Expires in: \(Int(expiresDate.timeIntervalSinceNow / 60)) minutes", category: "Network")
        
        return LoginSuccessData(
            userId: response.userId,
            username: username,
            sessionToken: response.accessToken,
            expires: response.expiresAt
        )
    }
    
    /// Logout current session
    /// POST /api/v1/auth/logout
    func logout(sessionToken: String) async throws {
        let endpoint = "/api/v1/auth/logout"
        let requestBody: [String: Any] = [
            "all_devices": false
        ]
        
        let _: EmptyResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody,
            requiresAuth: true
        )
    }
    
    /// Delete account
    /// POST /api/v1/auth/delete
    func deleteAccount(sessionToken: String, password: String) async throws {
        let endpoint = "/api/v1/auth/delete"
        let requestBody: [String: Any] = [
            "password": password
        ]
        
        let _: EmptyResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody,
            requiresAuth: true
        )
    }
}

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

    /// Check username availability
    /// GET /api/v1/users/username/availability?username=<string>
    func checkUsernameAvailability(username: String) async throws -> Bool {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
        let endpoint = "/api/v1/users/username/availability?username=\(encoded)"

        let response: UsernameAvailabilityResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "GET",
            requiresAuth: false
        )

        return response.available
    }
    
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
        
        // Calculate expiration timestamp
        let expiresTimestamp: Int64
        if let expiresAt = response.expiresAt {
            expiresTimestamp = expiresAt
        } else if let expiresIn = response.expiresIn {
            let expiresDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            expiresTimestamp = Int64(expiresDate.timeIntervalSince1970)
        } else {
            let expiresDate = Date().addingTimeInterval(3600)
            expiresTimestamp = Int64(expiresDate.timeIntervalSince1970)
        }
        
        return RegisterSuccessData(
            userId: response.userId,
            username: username,
            sessionToken: response.accessToken,
            refreshToken: response.refreshToken,
            expires: expiresTimestamp
        )
    }
    
    /// Authenticate with device keys (device-based auth)
    /// POST /api/v1/auth/device
    func authenticateDevice(deviceId: String, timestamp: Int64, signature: String) async throws -> AuthResponse {
        let endpoint = "/api/v1/auth/device"
        
        let requestBody: [String: Any] = [
            "deviceId": deviceId,
            "timestamp": timestamp,
            "signature": signature
        ]
        
        let response: AuthResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody
        )
        
        return response
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
        if let expiresAt = response.expiresAt {
            Log.info("   expiresAt: \(expiresAt) (raw value)", category: "Network")
        } else if let expiresIn = response.expiresIn {
            Log.info("   expiresIn: \(expiresIn) seconds", category: "Network")
        }
        
        // Calculate expiration timestamp
        let expiresTimestamp: Int64
        if let expiresAt = response.expiresAt {
            // Old format: Unix timestamp
            if expiresAt > 1_000_000_000_000 {
                // Milliseconds
                expiresTimestamp = expiresAt / 1000
                Log.info("   Interpreting expiresAt as milliseconds", category: "Network")
            } else {
                // Seconds
                expiresTimestamp = expiresAt
                Log.info("   Interpreting expiresAt as seconds", category: "Network")
            }
        } else if let expiresIn = response.expiresIn {
            // New format: seconds from now
            let expiresDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            expiresTimestamp = Int64(expiresDate.timeIntervalSince1970)
            Log.info("   Calculated expiration from expiresIn", category: "Network")
        } else {
            // Fallback: 1 hour
            let expiresDate = Date().addingTimeInterval(3600)
            expiresTimestamp = Int64(expiresDate.timeIntervalSince1970)
            Log.info("⚠️ No expiration info - defaulting to 1 hour", category: "Network")
        }
        
        let expiresDate = Date(timeIntervalSince1970: TimeInterval(expiresTimestamp))
        Log.info("   Expires at: \(expiresDate)", category: "Network")
        Log.info("   Expires in: \(Int(expiresDate.timeIntervalSinceNow / 60)) minutes", category: "Network")
        
        return LoginSuccessData(
            userId: response.userId,
            username: username,
            sessionToken: response.accessToken,
            refreshToken: response.refreshToken,
            expires: expiresTimestamp
        )
    }
    
    /// Logout current session
    /// POST /api/v1/auth/logout
    func logout(sessionToken: String) async throws {
        let endpoint = "/api/v1/auth/logout"
        let requestBody: [String: Any] = [
            "allDevices": false
        ]
        
        let _: EmptyResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody,
            requiresAuth: true
        )
    }
    
    // MARK: - Device-Signed Account Deletion

    /// Get device delete challenge
    /// GET /api/v1/users/me/delete-challenge
    func getDeleteChallenge() async throws -> DeleteChallengeResponse {
        let endpoint = "/api/v1/users/me/delete-challenge"
        let response: DeleteChallengeResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "GET",
            body: nil,
            requiresAuth: true
        )
        return response
    }

    /// Confirm device deletion
    /// POST /api/v1/users/me/delete-device
    func confirmDeleteDevice(request: DeleteDeviceRequest) async throws {
        let endpoint = "/api/v1/users/me/delete-device"
        let requestBody: [String: Any] = [
            "deviceId": request.deviceId,
            "challenge": request.challenge,
            "signature": request.signature,
            "ts": request.ts
        ]

        let _: EmptyResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody,
            requiresAuth: true
        )
    }
    
    /// Refresh access token using refresh token
    /// POST /api/v1/auth/refresh
    func refreshToken(refreshToken: String) async throws -> AuthResponse {
        let endpoint = "/api/v1/auth/refresh"
        
        Log.info("🔄 Refreshing access token", category: "AuthAPI")
        
        let requestBody: [String: Any] = [
            "refreshToken": refreshToken
        ]
        
        let response: AuthResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody,
            requiresAuth: true  // May use expired access_token (server allows this)
        )
        
        Log.info("✅ Token refreshed successfully (expiresIn: \(response.expiresIn ?? 0)s)", category: "AuthAPI")
        return response
    }
    
    // MARK: - Device-Based Authentication (v2)
    
    /// Get PoW challenge for registration
    /// GET /api/v1/auth/challenge
    func getRegistrationChallenge() async throws -> ChallengeResponse {
        let endpoint = "/api/v1/auth/challenge"
        
        Log.info("🎲 Fetching PoW challenge", category: "AuthAPI")
        
        let response: ChallengeResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "GET",
            requiresAuth: false
        )
        
        Log.info("✅ Challenge received: difficulty=\(response.difficulty)", category: "AuthAPI")
        return response
    }
    
    /// Register with device-based authentication (v2)
    /// POST /api/v1/auth/register-device
    func registerV2(
        username: String?,
        deviceId: String,
        registrationBundle: String,
        challenge: String,
        powSolution: PowSolution
    ) async throws -> RegisterSuccessData {
        let endpoint = "/api/v1/auth/register-device"
        
        Log.info("📝 Registering device: \(deviceId), username: \(username ?? "nil")", category: "AuthAPI")
        
        // Parse registration bundle JSON
        guard let bundleData = registrationBundle.data(using: .utf8),
              let bundleDict = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any] else {
            throw NetworkError.decodingFailed
        }
        
        // ✅ Server expects publicKeys as nested object
        let signedPrekeySignature = (bundleDict["signed_prekey_signature"] as? String)
            ?? (bundleDict["signature"] as? String)
        var requestBody: [String: Any] = [
            "deviceId": deviceId,
            "publicKeys": [
                "verifyingKey": bundleDict["verifying_key"] ?? "",
                "identityPublic": bundleDict["identity_public"] ?? "",
                "signedPrekeyPublic": bundleDict["signed_prekey_public"] ?? "",
                // Backward-compatible: keep legacy field name
                "signature": bundleDict["signature"] ?? "",
                // New required field for server
                "signedPrekeySignature": signedPrekeySignature ?? ""
            ],
            "cryptoSuites": ["Curve25519+Ed25519"],
            "powSolution": [
                "challenge": challenge,
                "nonce": powSolution.nonce,
                "hash": powSolution.hash
            ]
        ]

        if let verifyingKey = bundleDict["verifying_key"] as? String {
            Log.info("🔐 Register payload verifyingKey: \(verifyingKey)", category: "AuthAPI")
        } else {
            Log.info("⚠️ Register payload missing verifying_key", category: "AuthAPI")
        }
        if let identityPublic = bundleDict["identity_public"] as? String {
            Log.info("🔐 Register payload identityPublic: \(identityPublic)", category: "AuthAPI")
        } else {
            Log.info("⚠️ Register payload missing identity_public", category: "AuthAPI")
        }
        if let signedPrekeySignature {
            Log.info("🔐 Register payload signedPrekeySignature: \(signedPrekeySignature)", category: "AuthAPI")
        } else {
            Log.info("⚠️ Register payload missing signed_prekey_signature/signature", category: "AuthAPI")
        }
        
        // Username is optional
        if let username = username, !username.isEmpty {
            requestBody["username"] = username
        }
        
        let response: AuthResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody,
            requiresAuth: false
        )
        
        // Calculate expiration
        let expiresTimestamp: Int64
        if let expiresIn = response.expiresIn {
            let expiresDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            expiresTimestamp = Int64(expiresDate.timeIntervalSince1970)
        } else {
            let expiresDate = Date().addingTimeInterval(3600)
            expiresTimestamp = Int64(expiresDate.timeIntervalSince1970)
        }
        
        Log.info("✅ Device registered successfully! userId=\(response.userId)", category: "AuthAPI")
        
        return RegisterSuccessData(
            userId: response.userId,
            username: username ?? "",
            sessionToken: response.accessToken,
            refreshToken: response.refreshToken,
            expires: expiresTimestamp
        )
    }
}

// MARK: - Response Models

struct ChallengeResponse: Codable {
    let challenge: String
    let difficulty: UInt32
    let expiresAt: Int64
    
    enum CodingKeys: String, CodingKey {
        case challenge
        case difficulty
        case expiresAt  // Server sends "expiresAt" in camelCase
    }
}

struct DeleteChallengeResponse: Codable {
    let challenge: String
    let expiresAt: Int64
    let deviceId: String
}

struct DeleteDeviceRequest {
    let deviceId: String
    let challenge: String
    let signature: String
    let ts: Int64
}

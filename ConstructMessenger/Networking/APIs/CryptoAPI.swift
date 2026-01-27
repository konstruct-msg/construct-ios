//
//  CryptoAPI.swift
//  Construct Messenger
//
//  Cryptographic key management API
//  Created on 26.01.2026 (Phase 2.1 refactoring)
//

import Foundation

/// Cryptographic key management endpoints
class CryptoAPI {
    static let shared = CryptoAPI()
    
    private let client = RestAPIClient.shared
    
    private init() {}
    
    // MARK: - Key Management Endpoints
    
    /// Get public key bundle for a user
    /// GET /api/v1/users/:id/public-key
    /// Returns: Array with [KeyBundleObject, username]
    func getPublicKey(userId: String) async throws -> PublicKeyBundleData {
        let endpoint = "/api/v1/users/\(userId)/public-key"

        let response: PublicKeyBundleArrayResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "GET",
            body: nil,
            requiresAuth: true
        )

        // Parse the bundleData (base64 encoded JSON)
        guard let bundleDataString = response.keyBundle.bundleData,
              let bundleDataDecoded = Data(base64Encoded: bundleDataString) else {
            Log.error("❌ Failed to decode bundleData from base64", category: "Network")
            throw NetworkError.decodingFailed
        }

        let bundleContent: KeyBundleContent
        do {
            bundleContent = try JSONDecoder().decode(KeyBundleContent.self, from: bundleDataDecoded)
        } catch {
            Log.error("❌ Failed to parse bundleData JSON: \(error)", category: "Network")
            throw NetworkError.decodingFailed
        }

        // Get the first suite (we use suiteId: 1)
        guard let firstSuite = bundleContent.supportedSuites.first else {
            Log.error("❌ No supported suites in key bundle", category: "Network")
            throw NetworkError.decodingFailed
        }

        // Convert server response to client format
        return PublicKeyBundleData(
            userId: bundleContent.userId,
            username: response.username,
            identityPublic: firstSuite.identityKey,
            signedPrekeyPublic: firstSuite.signedPrekey,
            signature: firstSuite.signedPrekeySignature,
            verifyingKey: response.keyBundle.masterIdentityKey,
            suiteId: UInt16(firstSuite.suiteId)
        )
    }
    
    /// Rotate prekeys
    /// POST /api/v1/keys/rotate
    func rotatePrekeys(keyBundle: UploadableKeyBundle) async throws {
        let endpoint = "/api/v1/keys/rotate"
        
        let requestBody: [String: Any] = [
            "key_bundle": [
                "master_identity_key": keyBundle.masterIdentityKey,
                "bundle_data": keyBundle.bundleData,
                "signature": keyBundle.signature
            ]
        ]
        
        let _: EmptyResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody,
            requiresAuth: true
        )
    }
}

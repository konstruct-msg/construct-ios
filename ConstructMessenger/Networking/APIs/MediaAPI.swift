//
//  MediaAPI.swift
//  Construct Messenger
//
//  Media upload/download API
//  Created on 26.01.2026 (Phase 2.1 refactoring)
//

import Foundation

/// Media upload and download endpoints
class MediaAPI {
    static let shared = MediaAPI()
    
    private let client = RestAPIClient.shared
    
    private init() {}
    
    // MARK: - Media Endpoints
    
    /// Request upload token for media
    /// POST /api/v1/media/token
    func requestMediaToken() async throws -> MediaTokenData {
        let endpoint = "/api/v1/media/token"
        
        let response: MediaTokenResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: nil,
            requiresAuth: true
        )
        
        return MediaTokenData(
            requestId: response.requestId ?? UUID().uuidString,
            uploadToken: response.uploadToken,
            uploadUrl: response.uploadUrl,
            maxFileSize: response.maxFileSize,
            expiresAt: response.expiresAt
        )
    }
}

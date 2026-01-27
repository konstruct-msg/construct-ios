//
//  APNsAPI.swift
//  Construct Messenger
//
//  Apple Push Notification service API
//  Created on 26.01.2026 (Phase 2.1 refactoring)
//

import Foundation

/// Apple Push Notification endpoints
class APNsAPI {
    static let shared = APNsAPI()
    
    private let client = RestAPIClient.shared
    
    private init() {}
    
    // MARK: - Push Notifications Endpoints
    
    /// Register device token for push notifications
    /// POST /api/v1/notifications/register-device
    func registerDeviceToken(token: String) async throws -> DeviceTokenResponse {
        let endpoint = "/api/v1/notifications/register-device"
        
        let body: [String: Any] = [
            "deviceToken": token,
            "platform": "ios"
        ]
        
        let response: DeviceTokenResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            requiresAuth: true
        )
        
        return response
    }
    
    /// Unregister device token
    /// POST /api/v1/notifications/unregister-device
    func unregisterDeviceToken(token: String) async throws {
        let endpoint = "/api/v1/notifications/unregister-device"
        
        let body: [String: Any] = [
            "deviceToken": token
        ]
        
        let _: EmptyResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            requiresAuth: true
        )
    }
}

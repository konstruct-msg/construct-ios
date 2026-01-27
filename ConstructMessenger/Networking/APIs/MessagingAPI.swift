//
//  MessagingAPI.swift
//  Construct Messenger
//
//  Messaging API endpoints
//  Created on 26.01.2026 (Phase 2.1 refactoring)
//

import Foundation

/// Messaging endpoints for sending and receiving messages
class MessagingAPI {
    static let shared = MessagingAPI()
    
    private let client = RestAPIClient.shared
    
    private init() {}
    
    // MARK: - Messaging Endpoints
    
    /// Send a message
    /// POST /api/v1/messages
    func sendMessage(
        recipientId: String,
        ephemeralPublicKey: Data,
        messageNumber: UInt32,
        content: String,
        timestamp: UInt64,
        suiteId: UInt16
    ) async throws -> SendMessageResponse {
        let endpoint = "/api/v1/messages"

        let requestBody: [String: Any] = [
            "recipientId": recipientId,
            "suiteId": suiteId,
            "ephemeralPublicKey": ephemeralPublicKey.base64EncodedString(),
            "messageNumber": messageNumber,
            "previousChainLength": 0,
            "ciphertext": content
        ]

        Log.debug("📤 Sending message to \(recipientId), suiteId: \(suiteId), msgNum: \(messageNumber)", category: "Network")

        let response: SendMessageResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "POST",
            body: requestBody,
            requiresAuth: true
        )

        return response
    }
    
    /// Poll for new messages (long polling)
    /// GET /api/v1/messages?since=<id>&timeout=30
    func pollMessages(sinceId: String? = nil, timeout: Int = 30) async throws -> PollMessagesResponse {
        var endpoint = "/api/v1/messages"
        
        if let sinceId = sinceId {
            Log.info("📡 Polling messages with since=\(sinceId)", category: "Network")
        } else {
            Log.info("📡 Polling messages without since parameter (first request)", category: "Network")
        }
        
        // Build query parameters with proper URL encoding
        var queryItems: [URLQueryItem] = []
        if let sinceId = sinceId {
            queryItems.append(URLQueryItem(name: "since", value: sinceId))
        }
        queryItems.append(URLQueryItem(name: "timeout", value: String(timeout)))
        
        if !queryItems.isEmpty {
            var components = URLComponents(string: endpoint)
            components?.queryItems = queryItems
            if let queryString = components?.url?.query {
                endpoint += "?" + queryString
            }
        }
        
        Log.info("📡 Final endpoint: \(endpoint)", category: "Network")
        
        let response: PollMessagesResponse = try await client.performRequest(
            endpoint: endpoint,
            method: "GET",
            body: nil,
            requiresAuth: true,
            timeout: TimeInterval(timeout + 5),
            isLongPolling: true
        )
        
        Log.info("📥 Received \(response.messages.count) messages", category: "Network")
        if let nextSince = response.nextSince {
            Log.info("   nextSince: \(nextSince)", category: "Network")
        } else {
            Log.info("   nextSince: nil", category: "Network")
        }
        Log.info("   hasMore: \(response.hasMore ?? false)", category: "Network")
        
        return response
    }
}

//
//  RestAPIClient.swift
//  Construct Messenger
//
//  Core REST API client - shared networking infrastructure
//  Created on 26.01.2026 (Phase 2.1 refactoring)
//

import Foundation

/// Base REST API client providing shared networking infrastructure
/// Handles session management, server fallback, and request execution
class RestAPIClient {
    static let shared = RestAPIClient()

    private let session: URLSession
    private let longPollingSession: URLSession
    
    private var baseURL: String {
        APIConstants.activeServerURL
    }

    // Track which server URL is currently working
    private var workingServerURL: String?

    // Reference to connection status manager
    private let connectionStatusManager = ConnectionStatusManager.shared

    private init() {
        // Regular session for standard requests
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = APIConstants.connectionTimeout
        config.timeoutIntervalForResource = APIConstants.connectionTimeout * 2
        self.session = URLSession(configuration: config)
        
        // Separate session for long polling with increased timeouts
        let longPollingConfig = URLSessionConfiguration.default
        longPollingConfig.timeoutIntervalForRequest = APIConstants.longPollingTimeout
        longPollingConfig.timeoutIntervalForResource = APIConstants.longPollingResourceTimeout
        self.longPollingSession = URLSession(configuration: longPollingConfig)
    }
    
    // MARK: - Server Fallback Logic
    
    /// Get list of server URLs to try (with fallback)
    private func getServerURLsToTry() -> [String] {
        // If we have a working URL, try it first
        if let working = workingServerURL {
            var urls = [working]
            // Add other URLs as fallbacks
            for url in ServerConfig.serverURLs where url != working {
                urls.append(url)
            }
            return urls
        }
        // Otherwise try all URLs in order
        return ServerConfig.serverURLs
    }
    
    // MARK: - Core Request Method
    
    /// Perform HTTP request with automatic server fallback and error handling
    /// - Parameters:
    ///   - endpoint: API endpoint path (e.g., "/api/v1/auth/login")
    ///   - method: HTTP method (GET, POST, DELETE, etc.)
    ///   - body: Optional request body as dictionary (will be JSON encoded)
    ///   - requiresAuth: Whether to include Bearer token in Authorization header
    ///   - timeout: Optional custom timeout (for long-polling)
    ///   - isLongPolling: Whether this is a long-polling request (uses separate session)
    /// - Returns: Decoded response of type T
    func performRequest<T: Codable>(
        endpoint: String,
        method: String,
        body: [String: Any]? = nil,
        requiresAuth: Bool = false,
        timeout: TimeInterval? = nil,
        isLongPolling: Bool = false
    ) async throws -> T {
        let serverURLs = getServerURLsToTry()
        var lastError: Error?
        
        // Try each server URL until one works
        for (index, serverURL) in serverURLs.enumerated() {
            let fullURL = serverURL + endpoint
            Log.info("🌐 REST API \(method) \(endpoint) (attempt \(index + 1)/\(serverURLs.count))", category: "Network")
            Log.info("   Server URL: \(serverURL)", category: "Network")
            Log.info("   Full URL: \(fullURL)", category: "Network")
            
            guard let url = URL(string: fullURL) else {
                Log.error("❌ Invalid URL: \(fullURL)", category: "Network")
                lastError = NetworkError.connectionFailed
                continue
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = method
            
            // Set timeout if provided (for long polling)
            if let timeout = timeout {
                request.timeoutInterval = timeout
            }
            
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            
            // Set Host header explicitly to help with DNS resolution
            if let host = url.host {
                request.setValue(host, forHTTPHeaderField: "Host")
                Log.info("📋 Host header: \(host)", category: "Network")
            }
            
            // Add authentication header if required
            if requiresAuth {
                if let token = SessionManager.shared.sessionToken {
                    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if trimmedToken != token {
                        Log.info("⚠️ Token had whitespace, trimmed (original: \(token.count), trimmed: \(trimmedToken.count))", category: "Network")
                    }
                    
                    let tokenPreview = if trimmedToken.count > 40 {
                        "\(trimmedToken.prefix(20))...\(trimmedToken.suffix(20))"
                    } else {
                        trimmedToken
                    }
                    Log.info("🔐 Token preview: \(tokenPreview)", category: "Network")
                    Log.info("   Token length: \(trimmedToken.count) characters", category: "Network")
                    
                    let authHeader = "Bearer \(trimmedToken)"
                    request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                    Log.info("🔐 Added Authorization header (full length: \(authHeader.count))", category: "Network")
                    
                    // Log token expiration status
                    if let expires = SessionManager.shared.sessionExpires {
                        let timeUntilExpiry = expires.timeIntervalSinceNow
                        if timeUntilExpiry > 0 {
                            Log.info("   Token expires in: \(Int(timeUntilExpiry / 60)) minutes", category: "Network")
                        } else {
                            Log.info("⚠️ Token has already expired! (expired \(Int(-timeUntilExpiry / 60)) minutes ago)", category: "Network")
                        }
                    } else {
                        Log.info("⚠️ No expiration info for token", category: "Network")
                    }
                } else {
                    Log.error("❌ No session token available for authenticated request", category: "Network")
                    throw NetworkError.notConnected
                }
            }
            
            // Add request body if provided
            if let body = body {
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
                } catch {
                    throw NetworkError.encodingFailed
                }
            }
            
            do {
                // Use appropriate session based on request type
                let activeSession = isLongPolling ? longPollingSession : session
                let (data, response) = try await activeSession.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = NetworkError.connectionFailed
                    continue
                }
                
                Log.info("📡 Response status: \(httpResponse.statusCode) from \(serverURL)", category: "Network")
                
                // Handle error responses
                if httpResponse.statusCode >= 400 {
                    let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
                    let errorMessage = errorResponse?.message ?? errorResponse?.error ?? "Server error (status: \(httpResponse.statusCode))"
                    let responseBody = String(data: data, encoding: .utf8)
                    
                    // Handle 401 Unauthorized - token expired or invalid
                    if httpResponse.statusCode == 401 {
                        Log.error("❌ Authentication failed (401): \(errorMessage)", category: "Network")
                        
                        let shouldClearSession: Bool
                        if let expires = SessionManager.shared.sessionExpires {
                            shouldClearSession = Date() >= expires
                            if shouldClearSession {
                                Log.info("⚠️ Token has expired (expired at: \(expires))", category: "Network")
                            } else {
                                Log.info("⚠️ Got 401 but token is not expired yet. May be a server issue.", category: "Network")
                            }
                        } else {
                            shouldClearSession = true
                            Log.info("⚠️ Got 401 and no expiration info available", category: "Network")
                        }
                        
                        if shouldClearSession {
                            DispatchQueue.main.async {
                                SessionManager.shared.clearSession()
                                NotificationCenter.default.post(name: NSNotification.Name("SessionExpired"), object: nil)
                            }
                            throw NetworkError.serverError(message: "Session expired. Please login again.", responseBody: responseBody)
                        } else {
                            throw NetworkError.serverError(message: "Authentication failed: \(errorMessage)", responseBody: responseBody)
                        }
                    }
                    
                    // For other 4xx errors, don't try fallback
                    if httpResponse.statusCode < 500 {
                        throw NetworkError.serverError(message: errorMessage, responseBody: responseBody)
                    }
                    
                    // For 5xx errors, try next server
                    lastError = NetworkError.serverError(message: errorMessage, responseBody: responseBody)
                    continue
                }
                
                // Success! Remember this working server URL
                workingServerURL = serverURL
                Log.info("✅ Successfully connected to: \(serverURL)", category: "Network")

                // Update connection status
                connectionStatusManager.markRequestSucceeded()
                
                // Decode successful response
                do {
                    let decoder = JSONDecoder()
                    // Handle empty response
                    if data.isEmpty {
                        if T.self == EmptyResponse.self {
                            return EmptyResponse() as! T
                        }
                    }
                    return try decoder.decode(T.self, from: data)
                } catch {
                    Log.error("❌ Failed to decode response: \(error)", category: "Network")
                    if let responseString = String(data: data, encoding: .utf8) {
                        Log.error("   Response body: \(responseString)", category: "Network")
                    }
                    throw NetworkError.decodingFailed
                }
            } catch let error as NetworkError {
                // Don't retry on certain errors
                if case .decodingFailed = error {
                    throw error
                }
                if case .encodingFailed = error {
                    throw error
                }
                if case .notConnected = error {
                    throw error
                }
                lastError = error
                continue
            } catch let urlError as URLError {
                Log.error("❌ URL Error for \(serverURL): \(urlError.localizedDescription)", category: "Network")
                Log.error("   Code: \(urlError.code.rawValue)", category: "Network")
                
                // SPECIAL CASE: Long-polling timeout is NORMAL
                if isLongPolling && urlError.code == .timedOut {
                    Log.debug("⏱️ Long-polling timeout (normal behavior) - no new messages", category: "Network")
                    connectionStatusManager.markRequestSucceeded()
                    if T.self == PollMessagesResponse.self {
                        return PollMessagesResponse(messages: [], nextSince: nil, hasMore: false) as! T
                    }
                    throw urlError
                }
                
                // Check if this is a connectivity error that might be fixed by trying another server
                switch urlError.code {
                case .cannotFindHost, .cannotConnectToHost, .timedOut:
                    lastError = urlError
                    if index < serverURLs.count - 1 {
                        Log.info("🔄 Trying fallback server...", category: "Network")
                        continue
                    }
                    let message = "Cannot connect to any server. Tried:\n\(serverURLs.map { "- \($0)" }.joined(separator: "\n"))\n\nError: \(urlError.localizedDescription)"
                    throw NetworkError.serverError(message: message, responseBody: nil)
                case .notConnectedToInternet:
                    throw NetworkError.serverError(message: "No internet connection available.", responseBody: nil)
                default:
                    lastError = urlError
                    if index < serverURLs.count - 1 {
                        continue
                    }
                    throw NetworkError.serverError(message: "Network error: \(urlError.localizedDescription)", responseBody: nil)
                }
            } catch {
                Log.error("❌ Network request failed: \(error.localizedDescription)", category: "Network")
                lastError = error
                if index < serverURLs.count - 1 {
                    continue
                }
                throw NetworkError.connectionFailed
            }
        }
        
        // All servers failed
        connectionStatusManager.markRequestFailed(error: "Failed to connect to server", isCritical: true)

        if let lastError = lastError {
            throw lastError
        }
        throw NetworkError.connectionFailed
    }
}

// MARK: - Response Types

/// Server response format for auth endpoints
struct AuthResponse: Codable {
    let userId: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64
}

/// Empty response for endpoints that return no data
struct EmptyResponse: Codable {
    init() {}
}

/// Error response from server
struct ErrorResponse: Codable {
    let code: String?
    let error: String?
    let message: String?
}

// MARK: - Messaging Response Types

/// Response from sending a message
struct SendMessageResponse: Codable {
    let messageId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case status
    }
}

/// Response from polling messages
struct PollMessagesResponse: Codable {
    let messages: [ChatMessageResponse]
    let nextSince: String?
    let hasMore: Bool?
    
    enum CodingKeys: String, CodingKey {
        case messages
        case nextSince = "next_since"
        case hasMore = "has_more"
    }
    
    func toChatMessages() throws -> [ChatMessage] {
        try messages.map { try $0.toChatMessage() }
    }
}

/// Chat message in REST API response format
struct ChatMessageResponse: Codable {
    let id: String
    let from: String
    let to: String
    let ephemeralPublicKey: String?
    let messageNumber: UInt32?
    let content: String
    let suiteId: UInt16
    let timestamp: UInt64
    
    func toChatMessage() throws -> ChatMessage {
        let ephemeralKeyData: Data
        if let ephemeralKeyString = ephemeralPublicKey, !ephemeralKeyString.isEmpty {
            guard let keyData = Data(base64Encoded: ephemeralKeyString) else {
                Log.error("❌ Failed to decode ephemeralPublicKey from base64", category: "Network")
                throw NetworkError.decodingFailed
            }
            ephemeralKeyData = keyData
        } else {
            ephemeralKeyData = Data()
            Log.debug("ℹ️ Message has no ephemeralPublicKey, using empty data", category: "Network")
        }
        
        return ChatMessage(
            id: id,
            from: from,
            to: to,
            ephemeralPublicKey: ephemeralKeyData,
            messageNumber: messageNumber ?? 0,
            content: content,
            suiteId: suiteId,
            timestamp: timestamp
        )
    }
}

// MARK: - Key Management Response Types

/// Response from getting public key - API returns array: [KeyBundle, username]
struct PublicKeyBundleArrayResponse: Codable {
    let keyBundle: KeyBundleObject
    let username: String

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.keyBundle = try container.decode(KeyBundleObject.self)
        self.username = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(keyBundle)
        try container.encode(username)
    }
}

/// Key bundle object from API response
struct KeyBundleObject: Codable {
    let bundleData: String?
    let masterIdentityKey: String
    let signature: String
}

/// Decoded content from bundleData
struct KeyBundleContent: Codable {
    let userId: String
    let timestamp: String
    let supportedSuites: [KeyBundleSuite]
}

/// Suite data inside bundleData
struct KeyBundleSuite: Codable {
    let suiteId: Int
    let identityKey: String
    let signedPrekey: String
    let signedPrekeySignature: String
}

// MARK: - Media Response Types

/// Response from requesting media token
struct MediaTokenResponse: Codable {
    let requestId: String?
    let uploadToken: String
    let uploadUrl: String
    let maxFileSize: Int
    let expiresAt: String
    
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case uploadToken = "upload_token"
        case uploadUrl = "upload_url"
        case maxFileSize = "max_file_size"
        case expiresAt = "expires_at"
    }
}

// MARK: - Push Notifications Response Types

/// Response from device token registration
struct DeviceTokenResponse: Codable {
    let success: Bool
    let message: String?
}

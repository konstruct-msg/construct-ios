//
//  MediaUploadService.swift
//  Construct Messenger
//
//  Service for uploading encrypted media files to the media server.
//  Uses one-time upload tokens from construct-server.
//
//  Flow:
//  1. Request upload token from WebSocket
//  2. Encrypt media with random key
//  3. Upload encrypted blob to media server
//  4. Send message with media URL + encrypted key
//

import Foundation
import CryptoKit
import UIKit

// MARK: - Media Upload Error
enum MediaUploadError: LocalizedError {
    case notAuthenticated
    case tokenRequestFailed(String)
    case tokenTimeout
    case uploadFailed(String)
    case encryptionFailed
    case invalidResponse
    case fileTooLarge(Int, Int)  // actual, max
    case mediaServerDisabled
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You must be authenticated to upload media"
        case .tokenRequestFailed(let reason):
            return "Failed to get upload token: \(reason)"
        case .tokenTimeout:
            return "Upload token request timed out"
        case .uploadFailed(let reason):
            return "Upload failed: \(reason)"
        case .encryptionFailed:
            return "Failed to encrypt media"
        case .invalidResponse:
            return "Invalid response from media server"
        case .fileTooLarge(let actual, let max):
            return "File too large: \(actual / 1024 / 1024)MB exceeds limit of \(max / 1024 / 1024)MB"
        case .mediaServerDisabled:
            return "Media uploads are not enabled on this server"
        }
    }
}

// MARK: - Media Upload Response
struct MediaUploadResponse {
    let mediaId: String
    let mediaUrl: String
    let expiresAt: Date
    let size: Int
}

// MARK: - Encrypted Media
struct EncryptedMedia {
    let data: Data
    let key: Data  // 32 bytes ChaCha20-Poly1305 key
    let hash: String  // SHA-256 of encrypted data (server verifies uploaded file hash)
}

// MARK: - Media Upload Service
class MediaUploadService {
    static let shared = MediaUploadService()
    
    private var pendingTokenRequests: [String: CheckedContinuation<MediaTokenData, Error>] = [:]
    private let queue = DispatchQueue(label: "com.construct.mediaupload", attributes: .concurrent)
    
    private init() {}
    
    // MARK: - Public API
    
    /// Upload media to server
    /// - Parameters:
    ///   - optimizedMedia: Already optimized media from MediaOptimizer
    ///   - recipientId: User ID of the recipient (for encrypting media key)
    /// - Returns: MediaMessage data to include in chat message
    func uploadMedia(_ optimizedMedia: OptimizedMedia, for recipientId: String) async throws -> MediaMessageData {
        Log.info("Starting media upload (\(optimizedMedia.data.count) bytes)", category: "MediaUpload")
        
        // 1. Request upload token
        let token = try await requestUploadToken()
        Log.debug("Got upload token, expires: \(token.expiresAt)", category: "MediaUpload")
        
        // 2. Check file size
        if optimizedMedia.data.count > token.maxFileSize {
            throw MediaUploadError.fileTooLarge(optimizedMedia.data.count, token.maxFileSize)
        }
        
        // 3. Encrypt media
        let encrypted = try encryptMedia(optimizedMedia.data)
        Log.debug("Media encrypted (key: \(encrypted.key.count) bytes, hash: \(encrypted.hash.prefix(16))...)", category: "MediaUpload")
        
        // 4. Upload to media server
        let response = try await uploadToServer(
            data: encrypted.data,
            hash: encrypted.hash,
            token: token
        )
        Log.info("Media uploaded: \(response.mediaId)", category: "MediaUpload")
        
        // 5. Encrypt media key for recipient using Double Ratchet
        let encryptedMediaKey = try CryptoManager.shared.encryptMediaKey(
            mediaKey: encrypted.key,
            for: recipientId
        )
        
        // 6. Build media message data
        // ✅ FIX: Don't include thumbnail in JSON to avoid exceeding 64KB limit
        // Thumbnails can be generated client-side from downloaded media
        // If thumbnail is needed, it should be uploaded separately via Media Upload API
        return MediaMessageData(
            mediaId: response.mediaId,
            mediaUrl: response.mediaUrl,
            mediaKey: encryptedMediaKey,
            mediaType: optimizedMedia.metadata.mimeType,
            size: optimizedMedia.metadata.originalSize,
            width: optimizedMedia.metadata.width,
            height: optimizedMedia.metadata.height,
            duration: optimizedMedia.metadata.duration,
            thumbnail: nil,  // ✅ Excluded to keep JSON under 64KB
            hash: encrypted.hash
        )
    }
    
    /// Upload image
    func uploadImage(_ image: UIImage, for recipientId: String) async throws -> MediaMessageData {
        let optimized = try MediaOptimizer.optimizeImage(image)
        return try await uploadMedia(optimized, for: recipientId)
    }
    
    // MARK: - Token Request
    
    /// Request upload token from server via REST API
    func requestUploadToken() async throws -> MediaTokenData {
        // ✅ FIXED: Use REST API instead of WebSocket
        do {
            return try await MediaAPI.shared.requestMediaToken()
        } catch {
            throw MediaUploadError.tokenRequestFailed(error.localizedDescription)
        }
    }
    
    /// Called by WebSocketManager when token response is received
    func handleMediaTokenResponse(_ data: MediaTokenData) {
        queue.async(flags: .barrier) {
            if let continuation = self.pendingTokenRequests.removeValue(forKey: data.requestId) {
                continuation.resume(returning: data)
            }
        }
    }
    
    /// Called by WebSocketManager when token error is received
    func handleMediaTokenError(_ data: MediaTokenErrorData) {
        queue.async(flags: .barrier) {
            if let continuation = self.pendingTokenRequests.removeValue(forKey: data.requestId) {
                continuation.resume(throwing: MediaUploadError.tokenRequestFailed(data.error))
            }
        }
    }
    
    // MARK: - Encryption
    
    /// Encrypt media data with random key
    func encryptMedia(_ data: Data) throws -> EncryptedMedia {
        // Generate random 32-byte key
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        
        // Generate random nonce (12 bytes for ChaCha20-Poly1305)
        let nonce = try ChaChaPoly.Nonce()
        
        // Encrypt
        let sealedBox = try ChaChaPoly.seal(data, using: key, nonce: nonce)
        
        // Combined format: nonce (12) + ciphertext + tag (16)
        let encryptedData = sealedBox.combined
        
        // ✅ FIX: Calculate hash of ENCRYPTED data (server verifies hash of uploaded file)
        // Server receives encrypted data and verifies its hash, not the original data hash
        let hash = SHA256.hash(data: encryptedData)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        
        return EncryptedMedia(
            data: encryptedData,
            key: keyData,
            hash: hashHex
        )
    }
    
    // MARK: - Upload
    
    /// Upload encrypted blob to media server
    func uploadToServer(data: Data, hash: String, token: MediaTokenData) async throws -> MediaUploadResponse {
        guard let url = URL(string: token.uploadUrl) else {
            throw MediaUploadError.invalidResponse
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        // Create multipart form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add token field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"token\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(token.uploadToken)\r\n".data(using: .utf8)!)
        
        // Add hash field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"hash\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(hash)\r\n".data(using: .utf8)!)
        
        // Add file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"media.bin\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        // Send request
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MediaUploadError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw MediaUploadError.uploadFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        
        // Parse response
        struct UploadResponseJSON: Codable {
            let mediaId: String
            let mediaUrl: String
            let expiresAt: String
            let size: Int
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let uploadResponse = try decoder.decode(UploadResponseJSON.self, from: responseData)
        
        // Parse expiry date
        let formatter = ISO8601DateFormatter()
        let expiresAt = formatter.date(from: uploadResponse.expiresAt) ?? Date().addingTimeInterval(86400)
        
        return MediaUploadResponse(
            mediaId: uploadResponse.mediaId,
            mediaUrl: uploadResponse.mediaUrl,
            expiresAt: expiresAt,
            size: uploadResponse.size
        )
    }
    
    // MARK: - Download Media
    
    /// Download and decrypt media from media server
    /// - Parameters:
    ///   - mediaUrl: URL to download encrypted media from
    ///   - mediaKeyBase64: Base64-encoded media key (raw key, not Double Ratchet encrypted)
    ///                     For profile sharing, the key is included in E2E-encrypted JSON
    /// - Returns: Decrypted media data
    func downloadAndDecryptMedia(mediaUrl: String, mediaKeyBase64: String) async throws -> Data {
        Log.info("📥 Downloading media from: \(mediaUrl)", category: "MediaUpload")
        
        // 1. Download encrypted media from server
        guard let url = URL(string: mediaUrl) else {
            throw MediaUploadError.invalidResponse
        }
        
        let (encryptedData, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MediaUploadError.uploadFailed("HTTP \(statusCode): Failed to download media")
        }
        
        Log.debug("📥 Downloaded encrypted media: \(encryptedData.count) bytes", category: "MediaUpload")
        
        // 2. Decode media key (base64-encoded raw key)
        guard let keyData = Data(base64Encoded: mediaKeyBase64) else {
            throw MediaUploadError.encryptionFailed
        }
        
        // 3. Decrypt media using the key
        let decryptedData = try CryptoManager.shared.decryptMediaData(encryptedData, with: keyData)
        
        Log.info("✅ Media decrypted: \(decryptedData.count) bytes", category: "MediaUpload")
        
        return decryptedData
    }
}

// MARK: - Media Message Data
/// Data to include in chat message for media
struct MediaMessageData: Codable {
    let mediaId: String
    let mediaUrl: String
    let mediaKey: String  // Encrypted with Double Ratchet
    let mediaType: String  // MIME type
    let size: Int
    let width: Int?
    let height: Int?
    let duration: TimeInterval?
    let thumbnail: String?  // Base64 JPEG
    let hash: String  // SHA-256 of encrypted file (for server verification)
}

// MARK: - CryptoManager Extension
extension CryptoManager {
    
    /// Encrypt media key for recipient
    /// Uses existing Double Ratchet session
    func encryptMediaKey(mediaKey: Data, for userId: String) throws -> String {
        // Convert key to base64 for encryption
        let keyBase64 = mediaKey.base64EncodedString()
        
        // Encrypt using Double Ratchet
        let encrypted = try encryptMessage(keyBase64, for: userId)
        
        // Return the encrypted content
        return encrypted.content
    }
    
    /// Decrypt media key from sender
    /// The encryptedKey should be decrypted as part of the message content
    /// This method decrypts media using the symmetric key
    func decryptMediaData(_ encryptedData: Data, with keyData: Data) throws -> Data {
        guard keyData.count == 32 else {
            throw MediaUploadError.encryptionFailed
        }
        
        let key = SymmetricKey(data: keyData)
        
        // Data format: nonce (12 bytes) + ciphertext + tag (16 bytes)
        let sealedBox = try ChaChaPoly.SealedBox(combined: encryptedData)
        let decryptedData = try ChaChaPoly.open(sealedBox, using: key)
        
        return decryptedData
    }
}

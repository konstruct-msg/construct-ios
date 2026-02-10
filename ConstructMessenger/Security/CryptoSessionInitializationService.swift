//
//  SessionInitializationService.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation
import os.log

final class CryptoSessionInitializationService {
    func initializeSession(
        for userId: String,
        recipientBundle: (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String, suiteId: String),
        core: ClassicCryptoCore?,
        sessionStore: SessionStore,
        archiveSession: (String, ArchiveReason) -> Void,
        saveSession: (String) -> Void
    ) throws {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if sessionStore.hasSession(for: userId) {
            archiveSession(userId, .manualReset)
        }

        Log.debug("🔐 Session init bundle lengths: identity=\(recipientBundle.identityPublic.count), signedPrekey=\(recipientBundle.signedPrekeyPublic.count), signature=\(recipientBundle.signature.count), verifyingKey=\(recipientBundle.verifyingKey.count), suiteId=\(recipientBundle.suiteId)", category: "CryptoManager")

        guard let identityPublicData = Data(base64Encoded: recipientBundle.identityPublic) else {
            Log.error("❌ Invalid base64: identityPublic", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let signedPrekeyPublicData = Data(base64Encoded: recipientBundle.signedPrekeyPublic) else {
            Log.error("❌ Invalid base64: signedPrekeyPublic", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let signatureData = Data(base64Encoded: recipientBundle.signature) else {
            Log.error("❌ Invalid base64: signature", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let verifyingKeyData = Data(base64Encoded: recipientBundle.verifyingKey) else {
            Log.error("❌ Invalid base64: verifyingKey", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        guard let suiteID = UInt16(recipientBundle.suiteId) else {
            throw CryptoManagerError.invalidKeyData
        }

        let bundleDict: [String: Any] = [
            "identity_public": [UInt8](identityPublicData),
            "signed_prekey_public": [UInt8](signedPrekeyPublicData),
            "signature": [UInt8](signatureData),
            "verifying_key": [UInt8](verifyingKeyData),
            "suite_id": suiteID,
        ]

        do {
            let bundleData = try JSONSerialization.data(withJSONObject: bundleDict)
            let bytes = [UInt8](bundleData)
            let sessionId = try core.initSession(contactId: userId, recipientBundle: bytes)
            sessionStore.setSession(userId: userId, sessionId: sessionId, suiteId: suiteID)
            saveSession(userId)
        } catch {
            Log.error("❌ Rust core initSession failed: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    func initReceivingSession(
        for userId: String,
        recipientBundle: (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String, suiteId: String),
        firstMessage: ChatMessage,
        core: ClassicCryptoCore?,
        sessionStore: SessionStore,
        archiveSession: (String, ArchiveReason) -> Void,
        saveSession: (String) -> Void
    ) throws -> String {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if sessionStore.hasSession(for: userId) {
            archiveSession(userId, .manualReset)
        }

        Log.debug("🔐 Receiving init bundle lengths: identity=\(recipientBundle.identityPublic.count), signedPrekey=\(recipientBundle.signedPrekeyPublic.count), signature=\(recipientBundle.signature.count), verifyingKey=\(recipientBundle.verifyingKey.count), suiteId=\(recipientBundle.suiteId)", category: "CryptoManager")

        guard let identityPublicData = Data(base64Encoded: recipientBundle.identityPublic) else {
            Log.error("❌ Invalid base64: identityPublic", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let signedPrekeyPublicData = Data(base64Encoded: recipientBundle.signedPrekeyPublic) else {
            Log.error("❌ Invalid base64: signedPrekeyPublic", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let signatureData = Data(base64Encoded: recipientBundle.signature) else {
            Log.error("❌ Invalid base64: signature", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let verifyingKeyData = Data(base64Encoded: recipientBundle.verifyingKey) else {
            Log.error("❌ Invalid base64: verifyingKey", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        guard let suiteID = UInt16(recipientBundle.suiteId) else {
            throw CryptoManagerError.invalidKeyData
        }

        let bundleDict: [String: Any] = [
            "identity_public": [UInt8](identityPublicData),
            "signed_prekey_public": [UInt8](signedPrekeyPublicData),
            "signature": [UInt8](signatureData),
            "verifying_key": [UInt8](verifyingKeyData),
            "suite_id": suiteID,
        ]

        let messageDict: [String: Any] = [
            "ephemeral_public_key": [UInt8](firstMessage.ephemeralPublicKey),
            "message_number": firstMessage.messageNumber,
            "content": firstMessage.content
        ]

        do {
            let bundleData = try JSONSerialization.data(withJSONObject: bundleDict)
            let bundleBytes = [UInt8](bundleData)
            let messageData = try JSONSerialization.data(withJSONObject: messageDict)
            let messageBytes = [UInt8](messageData)

            let result = try core.initReceivingSession(
                contactId: userId,
                recipientBundle: bundleBytes,
                firstMessage: messageBytes
            )

            sessionStore.setSession(userId: userId, sessionId: result.sessionId, suiteId: suiteID)
            saveSession(userId)
            return result.decryptedMessage
        } catch {
            Log.error("❌ Rust core initReceivingSession failed: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }
}

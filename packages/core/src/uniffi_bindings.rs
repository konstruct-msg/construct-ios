use crate::crypto::client_api::ClassicClient;
use crate::crypto::handshake::x3dh::X3DHPublicKeyBundle;
use crate::crypto::messaging::double_ratchet::EncryptedRatchetMessage;
use crate::crypto::provider::CryptoProvider;
use crate::crypto::suites::classic::ClassicSuiteProvider;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

// Wrapper for Client to make it work with UniFFI
// Note: We use UDL definition, not derive macro
// UniFFI wraps this in Arc automatically, so we only need Mutex here
pub struct ClassicCryptoCore {
    inner: Mutex<ClassicClient<ClassicSuiteProvider>>,
}

// Error type that matches UDL definition (flat errors)
// Note: We use UDL definition, not derive macro
#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("Initialization failed")]
    InitializationFailed,

    #[error("Session not found")]
    SessionNotFound,

    #[error("Session initialization failed")]
    SessionInitializationFailed,

    #[error("Encryption failed")]
    EncryptionFailed,

    #[error("Decryption failed")]
    DecryptionFailed,

    #[error("Invalid key data")]
    InvalidKeyData,

    #[error("Invalid ciphertext")]
    InvalidCiphertext,

    #[error("Serialization failed")]
    SerializationFailed,

    #[error("MessagePack deserialization failed - check format")]
    MessagePackDeserializationFailed,
}

// Registration bundle as JSON - matches UDL
// Note: We use UDL definition, not derive macro
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegistrationBundleJson {
    pub identity_public: String,
    pub signed_prekey_public: String,
    pub signature: String,
    pub verifying_key: String,
    pub suite_id: String,
}

// Encrypted message components for wire format (matches server ChatMessage)
// Note: We use UDL definition for UniFFI
#[derive(Debug, Clone)]
pub struct EncryptedMessageComponents {
    pub ephemeral_public_key: Vec<u8>,  // 32 bytes
    pub message_number: u32,
    pub content: String,  // Base64(nonce || ciphertext_with_tag)
}

// Session initialization result with decrypted first message
// Note: We use UDL definition for UniFFI
#[derive(Debug, Clone)]
pub struct SessionInitResult {
    pub session_id: String,
    pub decrypted_message: String,  // UTF-8 decoded plaintext
}

// Key bundle for session initialization
#[derive(Debug, Clone, Serialize, Deserialize)]
struct KeyBundle {
    identity_public: Vec<u8>,
    signed_prekey_public: Vec<u8>,
    signature: Vec<u8>,
    verifying_key: Vec<u8>,
    suite_id: u16,
}

// UniFFI interface implementation (exported via UDL, not proc-macros)
impl ClassicCryptoCore {
    /// Export registration bundle as JSON string
    pub fn export_registration_bundle_json(&self) -> Result<String, CryptoError> {
        let client = self.inner.lock().unwrap();

        // Get registration bundle from X3DH
        let bundle = client.get_registration_bundle()
            .map_err(|_| CryptoError::InitializationFailed)?;

        // Convert to base64 strings
        use base64::Engine;
        let json_bundle = RegistrationBundleJson {
            identity_public: base64::engine::general_purpose::STANDARD.encode(&bundle.identity_public),
            signed_prekey_public: base64::engine::general_purpose::STANDARD.encode(&bundle.signed_prekey_public),
            signature: base64::engine::general_purpose::STANDARD.encode(&bundle.signature),
            verifying_key: base64::engine::general_purpose::STANDARD.encode(&bundle.verifying_key),
            suite_id: bundle.suite_id.to_string(),
        };

        serde_json::to_string(&json_bundle)
            .map_err(|_| CryptoError::SerializationFailed)
    }

    /// Initialize a session with a contact
    pub fn init_session(
        &self,
        contact_id: String,
        recipient_bundle: Vec<u8>,
    ) -> Result<String, CryptoError> {
        let bundle_str = std::str::from_utf8(&recipient_bundle)
            .map_err(|_| CryptoError::InvalidKeyData)?;

        let key_bundle: KeyBundle = serde_json::from_str(bundle_str)
            .map_err(|_| CryptoError::InvalidKeyData)?;

        // Create X3DHPublicKeyBundle
        let public_bundle = X3DHPublicKeyBundle {
            identity_public: key_bundle.identity_public.clone(),
            signed_prekey_public: key_bundle.signed_prekey_public.clone(),
            signature: key_bundle.signature.clone(),
            verifying_key: key_bundle.verifying_key.clone(),
            suite_id: key_bundle.suite_id,
        };

        // Extract remote identity public key
        let remote_identity = ClassicSuiteProvider::kem_public_key_from_bytes(
            key_bundle.identity_public.clone()
        );

        let mut client = self.inner.lock().unwrap();
        client.init_session(&contact_id, &public_bundle, &remote_identity)
            .map_err(|_| CryptoError::SessionInitializationFailed)
    }

    /// Initialize a receiving session (for responder) with first message
    ///
    /// Returns SessionInitResult with session_id and decrypted first message
    pub fn init_receiving_session(
        &self,
        contact_id: String,
        recipient_bundle: Vec<u8>,
        first_message: Vec<u8>,
    ) -> Result<SessionInitResult, CryptoError> {
        eprintln!("[uniffi_bindings::NEW] init_receiving_session called for contact: {}", contact_id);

        // Parse recipient bundle JSON
        let bundle_str = std::str::from_utf8(&recipient_bundle)
            .map_err(|_| CryptoError::InvalidKeyData)?;

        let key_bundle: KeyBundle = serde_json::from_str(bundle_str)
            .map_err(|_| CryptoError::InvalidKeyData)?;

        eprintln!("[uniffi_bindings::NEW] Parsed key bundle, suite_id: {}", key_bundle.suite_id);

        // Parse first message JSON
        let message_str = std::str::from_utf8(&first_message)
            .map_err(|_| CryptoError::InvalidCiphertext)?;

        #[derive(Deserialize)]
        struct FirstMessage {
            ephemeral_public_key: Vec<u8>,
            message_number: u32,
            content: String,  // Base64
        }

        let first_msg: FirstMessage = serde_json::from_str(message_str)
            .map_err(|_| CryptoError::InvalidCiphertext)?;

        // Decode base64 content
        let sealed_box = base64::engine::general_purpose::STANDARD
            .decode(&first_msg.content)
            .map_err(|_| CryptoError::InvalidCiphertext)?;

        // Extract nonce (first 12 bytes) and ciphertext (rest)
        if sealed_box.len() < 12 {
            return Err(CryptoError::InvalidCiphertext);
        }
        let nonce = sealed_box[..12].to_vec();
        let ciphertext = sealed_box[12..].to_vec();

        // Convert ephemeral_public_key to [u8; 32]
        let dh_public_key: [u8; 32] = first_msg.ephemeral_public_key.clone()
            .try_into()
            .map_err(|_| CryptoError::InvalidKeyData)?;

        // Create EncryptedRatchetMessage
        let encrypted_first_message = EncryptedRatchetMessage {
            dh_public_key,
            message_number: first_msg.message_number,
            ciphertext,
            nonce,
            previous_chain_length: 0,
            suite_id: key_bundle.suite_id,
        };

        // Extract keys for session initialization
        let remote_identity = ClassicSuiteProvider::kem_public_key_from_bytes(
            key_bundle.identity_public.clone()
        );

        let remote_ephemeral = ClassicSuiteProvider::kem_public_key_from_bytes(
            first_msg.ephemeral_public_key
        );

        let mut client = self.inner.lock().unwrap();
        let (session_id, plaintext_bytes) = client.init_receiving_session_with_ephemeral(
            &contact_id,
            &remote_identity,
            &remote_ephemeral,
            &encrypted_first_message,
        )
        .map_err(|e| {
            eprintln!("[UniFFI] init_receiving_session_with_ephemeral failed: {:?}", e);
            CryptoError::SessionInitializationFailed
        })?;

        // Convert plaintext bytes to UTF-8 string
        let decrypted_message = String::from_utf8(plaintext_bytes)
            .map_err(|_| CryptoError::DecryptionFailed)?;

        eprintln!("[uniffi_bindings::NEW] Session initialized, plaintext length: {}", decrypted_message.len());

        Ok(SessionInitResult {
            session_id,
            decrypted_message,
        })
    }

    /// Encrypt a message for a session - returns wire format components
    pub fn encrypt_message(
        &self,
        session_id: String,
        plaintext: String,
    ) -> Result<EncryptedMessageComponents, CryptoError> {
        let mut client = self.inner.lock().unwrap();

        // Note: session_id from Swift is actually contact_id in our new API
        let contact_id = &session_id;

        let encrypted_message = client
            .encrypt_message(contact_id, plaintext.as_bytes())
            .map_err(|_| CryptoError::EncryptionFailed)?;

        // Create sealed box: nonce || ciphertext_with_tag
        let mut sealed_box = Vec::new();
        sealed_box.extend_from_slice(&encrypted_message.nonce);
        sealed_box.extend_from_slice(&encrypted_message.ciphertext);

        Ok(EncryptedMessageComponents {
            ephemeral_public_key: encrypted_message.dh_public_key.to_vec(),
            message_number: encrypted_message.message_number,
            content: base64::engine::general_purpose::STANDARD.encode(&sealed_box),
        })
    }

    /// Decrypt a message from a session - accepts wire format components
    pub fn decrypt_message(
        &self,
        session_id: String,
        ephemeral_public_key: Vec<u8>,
        message_number: u32,
        content: String,
    ) -> Result<String, CryptoError> {
        // Decode base64 sealed box
        let sealed_box = base64::engine::general_purpose::STANDARD
            .decode(&content)
            .map_err(|_| CryptoError::InvalidCiphertext)?;

        // Extract nonce (first 12 bytes) and ciphertext (rest)
        if sealed_box.len() < 12 {
            return Err(CryptoError::InvalidCiphertext);
        }
        let nonce = sealed_box[..12].to_vec();
        let ciphertext = sealed_box[12..].to_vec();

        // Convert ephemeral_public_key to [u8; 32]
        let dh_public_key: [u8; 32] = ephemeral_public_key
            .try_into()
            .map_err(|_| CryptoError::InvalidKeyData)?;

        // Reconstruct EncryptedRatchetMessage
        let encrypted_message = EncryptedRatchetMessage {
            dh_public_key,
            message_number,
            ciphertext,
            nonce,
            previous_chain_length: 0,  // Not used by decryption
            suite_id: crate::config::Config::global().classic_suite_id,
        };

        // Note: session_id from Swift is actually contact_id in our new API
        let contact_id = &session_id;

        let mut client = self.inner.lock().unwrap();
        let plaintext_bytes = client
            .decrypt_message(contact_id, &encrypted_message)
            .map_err(|_| CryptoError::DecryptionFailed)?;

        String::from_utf8(plaintext_bytes)
            .map_err(|_| CryptoError::DecryptionFailed)
    }
}

/// Create a new CryptoCore instance (exported via UDL)
/// UniFFI automatically wraps this in Arc<>, so we return Arc<ClassicCryptoCore>
pub fn create_crypto_core() -> Result<Arc<ClassicCryptoCore>, CryptoError> {
    // Инициализировать конфигурацию при первом вызове
    let _ = crate::config::Config::init();

    let client = ClassicClient::<ClassicSuiteProvider>::new()
        .map_err(|_| CryptoError::InitializationFailed)?;

    Ok(Arc::new(ClassicCryptoCore {
        inner: Mutex::new(client),
    }))
}

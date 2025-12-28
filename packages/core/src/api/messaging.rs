// API для отправки и получения сообщений

use crate::crypto::{ClientCrypto, CryptoProvider};
use crate::crypto::double_ratchet::EncryptedRatchetMessage;
use crate::utils::error::{ConstructError, Result};
use serde::{Deserialize, Serialize};

/// Зашифрованное сообщение для передачи
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedMessage {
    pub session_id: String,
    pub ciphertext: Vec<u8>,
    pub dh_public_key: [u8; 32],
    pub nonce: Vec<u8>,
    pub message_number: u32,
    pub previous_chain_length: u32,
}

impl From<EncryptedRatchetMessage> for EncryptedMessage {
    fn from(msg: EncryptedRatchetMessage) -> Self {
        Self {
            session_id: String::new(), // Will be set by caller
            ciphertext: msg.ciphertext,
            dh_public_key: msg.dh_public_key,
            nonce: msg.nonce,
            message_number: msg.message_number,
            previous_chain_length: msg.previous_chain_length,
        }
    }
}

impl From<EncryptedMessage> for EncryptedRatchetMessage {
    fn from(msg: EncryptedMessage) -> Self {
        Self {
            ciphertext: msg.ciphertext,
            dh_public_key: msg.dh_public_key,
            nonce: msg.nonce,
            message_number: msg.message_number,
            previous_chain_length: msg.previous_chain_length,
            suite_id: crate::config::Config::global().classic_suite_id,
        }
    }
}

/// Отправить зашифрованное сообщение
pub fn encrypt_message<P: CryptoProvider>(
    client: &mut ClientCrypto<P>,
    session_id: &str,
    plaintext: &str,
) -> Result<EncryptedMessage> {
    let encrypted = client
        .encrypt_ratchet_message(session_id, plaintext.as_bytes())
        .map_err(ConstructError::CryptoError)?;

    let mut msg: EncryptedMessage = encrypted.into();
    msg.session_id = session_id.to_string();
    Ok(msg)
}

/// Получить и расшифровать сообщение
pub fn decrypt_message<P: CryptoProvider>(
    client: &mut ClientCrypto<P>,
    session_id: &str,
    encrypted: EncryptedMessage,
) -> Result<String> {
    let ratchet_msg: EncryptedRatchetMessage = encrypted.into();

    let plaintext = client
        .decrypt_ratchet_message(session_id, &ratchet_msg)
        .map_err(ConstructError::CryptoError)?;

    String::from_utf8(plaintext)
        .map_err(|e| ConstructError::SerializationError(format!("Invalid UTF-8: {}", e)))
}

/// Инициализировать сессию с контактом (отправитель)
pub fn init_session<P: CryptoProvider>(
    client: &mut ClientCrypto<P>,
    contact_id: &str,
    remote_bundle: &crate::api::crypto::KeyBundle,
) -> Result<String> {
    let public_bundle = remote_bundle.clone().into();
    client
        .init_double_ratchet_session(contact_id, &public_bundle)
        .map_err(ConstructError::SessionError)
}

/// Инициализировать сессию получателя при получении первого сообщения
pub fn init_receiving_session<P: CryptoProvider>(
    client: &mut ClientCrypto<P>,
    contact_id: &str,
    remote_bundle: &crate::api::crypto::KeyBundle,
    first_encrypted_msg: &EncryptedMessage,
) -> Result<String> {
    let public_bundle = remote_bundle.clone().into();
    let ratchet_msg: EncryptedRatchetMessage = first_encrypted_msg.clone().into();

    client
        .init_receiving_session(contact_id, &public_bundle, &ratchet_msg)
        .map_err(ConstructError::SessionError)
}

/// Сериализовать зашифрованное сообщение в JSON
pub fn serialize_encrypted_message(msg: &EncryptedMessage) -> Result<String> {
    serde_json::to_string(msg)
        .map_err(|e| ConstructError::SerializationError(e.to_string()))
}

/// Десериализовать зашифрованное сообщение из JSON
pub fn deserialize_encrypted_message(json: &str) -> Result<EncryptedMessage> {
    serde_json::from_str(json)
        .map_err(|e| ConstructError::SerializationError(e.to_string()))
}

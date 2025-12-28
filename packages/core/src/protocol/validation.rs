// Валидация входящих данных

use crate::config::Config;
use crate::protocol::messages::{ChatMessage, ClientMessage, RegistrationBundle};
use crate::utils::error::{ConstructError, Result};
use base64::{engine::general_purpose, Engine as _};

/// Валидация Base64 строки
pub fn validate_base64(encoded: &str) -> Result<()> {
    if general_purpose::STANDARD.decode(encoded).is_err() {
        return Err(ConstructError::ValidationError(
            "Invalid Base64 string".to_string(),
        ));
    }
    Ok(())
}

/// Валидация имени пользователя
pub fn validate_username(username: &str) -> Result<()> {
    let cfg = Config::global();
    if username.len() < cfg.username_min_length || username.len() > cfg.username_max_length {
        return Err(ConstructError::ValidationError(
            format!("Username must be between {} and {} characters",
                cfg.username_min_length, cfg.username_max_length),
        ));
    }

    // Проверка на допустимые символы (буквы, цифры, подчеркивание, дефис)
    if !username
        .chars()
        .all(|c| c.is_alphanumeric() || c == '_' || c == '-')
    {
        return Err(ConstructError::ValidationError(
            "Username can only contain alphanumeric characters, underscores, and hyphens"
                .to_string(),
        ));
    }

    Ok(())
}

/// Валидация UUID v4
pub fn validate_uuid(uuid: &str) -> Result<()> {
    // Простая проверка формата UUID
    if uuid.len() != Config::global().uuid_length {
        return Err(ConstructError::ValidationError(
            "Invalid UUID format: incorrect length".to_string(),
        ));
    }

    let parts: Vec<&str> = uuid.split('-').collect();
    if parts.len() != 5 || parts[0].len() != 8 || parts[1].len() != 4 || parts[2].len() != 4 || parts[3].len() != 4 || parts[4].len() != 12 {
        return Err(ConstructError::ValidationError(
            "Invalid UUID format".to_string(),
        ));
    }

    Ok(())
}

/// Валидация ChatMessage
pub fn validate_chat_message(msg: &ChatMessage) -> Result<()> {
    // Проверка UUID
    validate_uuid(&msg.id)?;
    validate_uuid(&msg.from)?;
    validate_uuid(&msg.to)?;

    // Проверка ephemeral key (должен быть 32 байта для X25519)
    if msg.ephemeral_public_key.len() != Config::global().ephemeral_key_size {
        return Err(ConstructError::ValidationError(
            format!("Ephemeral public key must be {} bytes", Config::global().ephemeral_key_size),
        ));
    }

    // Проверка зашифрованного содержимого
    if msg.content.is_empty() {
        return Err(ConstructError::ValidationError(
            "Message content cannot be empty".to_string(),
        ));
    }

    validate_base64(&msg.content)?;

    // Проверка timestamp (не должен быть в будущем или слишком старым)
    let now = crate::utils::time::now();
    let cfg = Config::global();
    if msg.timestamp > now + cfg.message_timestamp_future_tolerance_secs as u64 {
        return Err(ConstructError::ValidationError(
            "Message timestamp is too far in the future".to_string(),
        ));
    }
    if msg.timestamp < now.saturating_sub(cfg.message_timestamp_past_tolerance_secs as u64) {
        return Err(ConstructError::ValidationError(
            "Message timestamp is too old".to_string(),
        ));
    }

    Ok(())
}

/// Валидация RegistrationBundle
pub fn validate_registration_bundle(bundle: &RegistrationBundle) -> Result<()> {
    let cfg = Config::global();

    // Base64 X25519 public key должен быть 44 символа
    if bundle.identity_public.len() != cfg.base64_public_key_length {
        return Err(ConstructError::ValidationError(
            format!("Identity public key must be {} characters (32 bytes base64)", cfg.base64_public_key_length),
        ));
    }

    if bundle.signed_prekey_public.len() != cfg.base64_public_key_length {
        return Err(ConstructError::ValidationError(
            format!("Signed prekey public must be {} characters (32 bytes base64)", cfg.base64_public_key_length),
        ));
    }

    // Ed25519 signature должна быть 88 символов (64 bytes base64)
    if bundle.signature.len() != cfg.base64_signature_length {
        return Err(ConstructError::ValidationError(
            format!("Signature must be {} characters (64 bytes base64)", cfg.base64_signature_length),
        ));
    }

    // Ed25519 verifying key должен быть 44 символа
    if bundle.verifying_key.len() != cfg.base64_public_key_length {
        return Err(ConstructError::ValidationError(
            format!("Verifying key must be {} characters (32 bytes base64)", cfg.base64_public_key_length),
        ));
    }

    Ok(())
}

/// Валидация ClientMessage (клиент → сервер)
pub fn validate_client_message(msg: &ClientMessage) -> Result<()> {
    match msg {
        ClientMessage::Register(data) => {
            validate_username(&data.username)?;
            let min_pass = Config::global().password_min_length;
            if data.password.len() < min_pass {
                return Err(ConstructError::ValidationError(
                    format!("Password too short (min {} chars)", min_pass),
                ));
            }
            // Декодируем и валидируем бандл
            let msgpack_bytes = general_purpose::STANDARD
                .decode(&data.public_key)
                .map_err(|_| {
                    ConstructError::ValidationError("Invalid Base64 in public_key".to_string())
                })?;
            let bundle: RegistrationBundle = rmp_serde::from_slice(&msgpack_bytes).map_err(
                |_| ConstructError::ValidationError("Invalid MessagePack in public_key".to_string()),
            )?;
            validate_registration_bundle(&bundle)?;
        }
        ClientMessage::Login(data) => {
            validate_username(&data.username)?;
            let min_pass = Config::global().password_min_length;
            if data.password.len() < min_pass {
                return Err(ConstructError::ValidationError(
                    format!("Password too short (min {} chars)", min_pass),
                ));
            }
        }
        ClientMessage::Connect(data) => {
            if data.session_token.is_empty() {
                return Err(ConstructError::ValidationError(
                    "Session token is required".to_string(),
                ));
            }
        }
        ClientMessage::SendMessage(chat_msg) => {
            validate_chat_message(chat_msg)?;
        }
        ClientMessage::GetPublicKey(data) => {
            validate_uuid(&data.user_id)?;
        }
        ClientMessage::SearchUsers(data) => {
            if data.query.is_empty() {
                return Err(ConstructError::ValidationError(
                    "Search query cannot be empty".to_string(),
                ));
            }
        }
        // Logout, RotatePrekey не требуют специальной валидации на этом уровне
        _ => {}
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_username() {
        assert!(validate_username("user123").is_ok());
        assert!(validate_username("us").is_err()); // Слишком короткое
        assert!(validate_username("a".repeat(33).as_str()).is_err()); // Слишком длинное
        assert!(validate_username("user@123").is_err()); // Недопустимые символы
    }

    #[test]
    fn test_validate_uuid() {
        assert!(validate_uuid("550e8400-e29b-41d4-a716-446655440000").is_ok());
        assert!(validate_uuid("invalid-uuid").is_err());
        assert!(validate_uuid("").is_err());
    }

    #[test]
    fn test_validate_chat_message() {
        // Valid base64 content (base64 of "test")
        let valid_base64_content = base64::engine::general_purpose::STANDARD.encode(b"test");

        let msg = ChatMessage {
            id: "550e8400-e29b-41d4-a716-446655440000".to_string(),
            from: "550e8400-e29b-41d4-a716-446655440001".to_string(),
            to: "550e8400-e29b-41d4-a716-446655440002".to_string(),
            ephemeral_public_key: vec![0u8; 32],
            message_number: 1,
            content: valid_base64_content,
            timestamp: crate::utils::time::current_timestamp() as u64,
        };

        assert!(validate_chat_message(&msg).is_ok());

        // Тест с неверным ephemeral key
        let mut bad_msg = msg.clone();
        bad_msg.ephemeral_public_key = vec![0u8; 16]; // Неверная длина
        assert!(validate_chat_message(&bad_msg).is_err());
    }
}

// Типы ошибок

use crate::error::CryptoError;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ConstructError {
    /// Криптографическая ошибка
    #[error("Cryptography error: {0}")]
    Crypto(#[from] CryptoError),

    /// Ошибка хранилища
    #[error("Storage error: {0}")]
    StorageError(String),

    /// Ошибка сети
    #[error("Network error: {0}")]
    NetworkError(String),

    /// Ошибка сериализации
    #[error("Serialization error: {0}")]
    SerializationError(String),

    /// Ошибка валидации
    #[error("Validation error: {0}")]
    ValidationError(String),

    /// Ошибка сессии
    #[error("Session error: {0}")]
    SessionError(String),

    /// Не найдено
    #[error("Not found: {0}")]
    NotFound(String),

    /// Внутренняя ошибка
    #[error("Internal error: {0}")]
    InternalError(String),
}

pub type Result<T> = std::result::Result<T, ConstructError>;

// Alias для совместимости
pub type MessengerError = ConstructError;

// Для WASM-биндингов
#[cfg(target_arch = "wasm32")]
impl From<ConstructError> for wasm_bindgen::JsValue {
    fn from(error: ConstructError) -> Self {
        wasm_bindgen::JsValue::from_str(&error.to_string())
    }
}

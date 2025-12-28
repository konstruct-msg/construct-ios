// Construct Messenger Core
// Rust/WASM engine with end-to-end encryption

#![warn(clippy::all)]
#![allow(clippy::too_many_arguments)]

// UniFFI bindings for iOS/macOS
#[cfg(not(target_arch = "wasm32"))]
pub mod uniffi_bindings;

// Re-export UniFFI types at crate root so scaffolding can find them
#[cfg(not(target_arch = "wasm32"))]
pub use uniffi_bindings::{ClassicCryptoCore, CryptoError, EncryptedMessageComponents, RegistrationBundleJson, SessionInitResult, create_crypto_core};

// Include UniFFI scaffolding generated from construct_core.udl
#[cfg(not(target_arch = "wasm32"))]
uniffi::include_scaffolding!("construct_core");

// Модули
pub mod api;
pub mod config;
pub mod crypto;
pub mod protocol;
pub mod storage;
pub mod state;
pub mod utils;
pub mod error;

#[cfg(target_arch = "wasm32")]
pub mod wasm;

// Re-exports для удобства
pub use api::MessengerAPI;
pub use crypto::ClientCrypto;
// pub use utils::error::Result; // Conflict with our new error module, commented out for now
// Note: CryptoError from error module is for internal use
// UniFFI CryptoError is exported above for FFI

// WASM экспорты
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen(start)]
pub fn init() {
    // Инициализация конфигурации (должна быть первой!)
    let _ = config::Config::init();

    // Настройка panic hook для лучшей отладки в браузере
    #[cfg(feature = "console_error_panic_hook")]
    console_error_panic_hook::set_once();

    // Инициализация логирования
    wasm::console::init_logging();
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

// Re-export WASM bindings
#[cfg(target_arch = "wasm32")]
pub use wasm::bindings::{
    create_crypto_client,
    get_registration_bundle,
    init_session,
    init_receiving_session,
    encrypt_message,
    decrypt_message,
    destroy_client,
};


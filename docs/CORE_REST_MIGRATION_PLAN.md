# construct-core REST API Migration Plan

**Дата:** 2026-01-15
**Версия:** 0.3.0 (планируемая)
**Авторы:** Core Team

---

## 📊 Анализ текущего использования

### iOS Client (construct-messenger)
**Уровень абстракции:** Низкоуровневая криптография

**Используемые методы (UniFFI):**
- ✅ `create_crypto_core()` / `create_crypto_core_from_keys_json()`
- ✅ `init_session()` / `init_receiving_session()`
- ✅ `encrypt_message()` / `decrypt_message()`
- ✅ `export_private_keys_json()` / `import_session_json()`
- ✅ `export_registration_bundle_json()` / `sign_bundle_data()`

**НЕ использует:**
- ❌ `AppState` - весь транспорт в Swift
- ❌ `WebSocketTransport` из ядра
- ❌ Методы `app_state_*`

**Вывод:** iOS использует **ТОЛЬКО криптографию**, транспортный слой полностью в Swift.

---

### Web Client (construct-messenger-web)
**Уровень абстракции:** Высокоуровневый AppState API

**Используемые методы (WASM):**
- ✅ `app_state_connect(server_url)` - WebSocket подключение
- ✅ `app_state_register_on_server(password)` - регистрация через WS
- ✅ `app_state_send_message(to, session_id, text)` - отправка через WS
- ✅ `app_state_load_conversation(contact_id)` - загрузка из IndexedDB
- ✅ `app_state_initialize_user()` / `finalize_registration()`

**Текущие проблемы:**
- ⚠️ Polling IndexedDB каждые 2-3 секунды (нет real-time получения)
- ⚠️ Нет логики refresh token
- ⚠️ Session tokens не персистятся (только sessionStorage)

**Вывод:** Web зависит от **AppState** для всего (крипто + транспорт + storage).

---

## 🎯 Архитектурное решение

### Принцип: Два независимых уровня API

```
┌──────────────────────────────────────────────────────────────┐
│                    CONSTRUCT-CORE                            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  УРОВЕНЬ 1: Низкоуровневая криптография (СТАБИЛЬНЫЙ)        │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ ClassicCryptoCore (UniFFI)                           │   │
│  │ - init_session / init_receiving_session              │   │
│  │ - encrypt_message / decrypt_message                  │   │
│  │ - export_private_keys_json / import_session_json     │   │
│  │ - export_registration_bundle_json                    │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│             ⬆ iOS использует напрямую                        │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  УРОВЕНЬ 2: Высокоуровневый AppState API (МОДЕРНИЗАЦИЯ)     │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ AppState (WASM)                                       │   │
│  │                                                       │   │
│  │ Новые методы (REST):                                 │   │
│  │ - app_state_register_rest(url, username, password)   │   │
│  │ - app_state_login_rest(url, username, password)      │   │
│  │ - app_state_refresh_token()                          │   │
│  │ - app_state_logout(all_devices)                      │   │
│  │ - app_state_send_message_rest(to, text)              │   │
│  │ - app_state_poll_messages(since_id, timeout)         │   │
│  │ - app_state_get_auth_state()                         │   │
│  │                                                       │   │
│  │ Старые методы (deprecated):                          │   │
│  │ - app_state_connect() ⚠️                             │   │
│  │ - app_state_register_on_server() ⚠️                   │   │
│  │                                                       │   │
│  │ Внутренние компоненты:                               │   │
│  │ ├─ REST Transport (новый)                            │   │
│  │ ├─ Token Manager (новый)                             │   │
│  │ ├─ Long Polling (новый)                              │   │
│  │ ├─ CSRF Manager (новый)                              │   │
│  │ └─ ClassicCryptoCore ──────────────┬─────────────────┘  │
│  │                                     │                    │
│  └─────────────────────────────────────┘                    │
│                                        │                     │
│             ⬆ Web использует через WASM                      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 🔧 Изменения в construct-core

### 1. Низкоуровневая криптография (НЕИЗМЕННО)

**Файлы:**
- `src/crypto/` - вся криптография
- `src/uniffi_bindings.rs` - UniFFI bindings для iOS
- `ClassicCryptoCore`, `EncryptedMessageComponents`, etc.

**Статус:** ✅ **БЕЗ ИЗМЕНЕНИЙ**

**Причина:** iOS клиент полагается на стабильность этого API.

---

### 2. Транспортный слой (НОВЫЙ)

#### A. REST Transport (`src/protocol/rest_transport.rs`) - НОВЫЙ ФАЙЛ

```rust
use crate::utils::error::Result;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthTokens {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64, // Unix timestamp
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterRequest {
    pub username: String,
    pub password: String,
    pub key_bundle: UploadableKeyBundle,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageRequest {
    pub recipient_id: String,
    pub suite_id: u16,
    pub ciphertext: String, // Base64
    pub nonce: Option<String>,
    pub timestamp: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PollMessagesResponse {
    pub messages: Vec<ReceivedMessage>,
    pub next_since: Option<String>,
    pub has_more: bool,
}

#[cfg(target_arch = "wasm32")]
pub struct RestTransport {
    base_url: String,
    access_token: Option<String>,
    csrf_token: Option<String>,
}

#[cfg(target_arch = "wasm32")]
impl RestTransport {
    pub fn new(base_url: String) -> Self {
        Self {
            base_url,
            access_token: None,
            csrf_token: None,
        }
    }

    /// POST /api/v1/auth/register
    pub async fn register(
        &self,
        username: String,
        password: String,
        key_bundle: UploadableKeyBundle,
    ) -> Result<AuthTokens> {
        // Implementation with fetch API
        unimplemented!()
    }

    /// POST /api/v1/auth/login
    pub async fn login(&self, username: String, password: String) -> Result<AuthTokens> {
        unimplemented!()
    }

    /// POST /auth/refresh
    pub async fn refresh_token(&self, refresh_token: String) -> Result<AuthTokens> {
        unimplemented!()
    }

    /// POST /auth/logout
    pub async fn logout(&self, all_devices: bool) -> Result<()> {
        unimplemented!()
    }

    /// POST /api/v1/messages
    pub async fn send_message(&self, request: MessageRequest) -> Result<String> {
        // Returns message_id
        unimplemented!()
    }

    /// GET /api/v1/messages?since=<id>&timeout=30
    pub async fn poll_messages(
        &self,
        since_id: Option<String>,
        timeout: u32,
    ) -> Result<PollMessagesResponse> {
        unimplemented!()
    }

    /// GET /api/v1/users/:id/public-key
    pub async fn get_user_public_key(&self, user_id: String) -> Result<String> {
        // Returns JSON bundle
        unimplemented!()
    }

    /// POST /api/v1/keys/upload
    pub async fn upload_keys(&self, bundle: UploadableKeyBundle) -> Result<()> {
        unimplemented!()
    }

    /// GET /api/csrf-token
    pub async fn get_csrf_token(&self) -> Result<String> {
        unimplemented!()
    }

    /// Set access token (for subsequent requests)
    pub fn set_access_token(&mut self, token: String) {
        self.access_token = Some(token);
    }

    /// Set CSRF token (cached)
    pub fn set_csrf_token(&mut self, token: String) {
        self.csrf_token = Some(token);
    }

    /// Make authenticated request with auto-headers
    async fn make_request(
        &self,
        method: &str,
        path: &str,
        body: Option<String>,
    ) -> Result<web_sys::Response> {
        // Auto-add:
        // - Authorization: Bearer <token>
        // - X-CSRF-Token: <csrf_token>
        // - X-Requested-With: XMLHttpRequest
        // - Content-Type: application/json
        unimplemented!()
    }
}
```

#### B. Token Manager (`src/auth/token_manager.rs`) - НОВЫЙ ФАЙЛ

```rust
use crate::utils::error::Result;
use crate::protocol::rest_transport::AuthTokens;
use crate::storage::Storage;

pub struct TokenManager<S: Storage> {
    storage: S,
    tokens: Option<AuthTokens>,
}

impl<S: Storage> TokenManager<S> {
    pub fn new(storage: S) -> Self {
        Self {
            storage,
            tokens: None,
        }
    }

    /// Загрузить токены из хранилища
    pub async fn load_tokens(&mut self) -> Result<Option<AuthTokens>> {
        // Load from IndexedDB
        unimplemented!()
    }

    /// Сохранить токены
    pub async fn save_tokens(&mut self, tokens: AuthTokens) -> Result<()> {
        self.tokens = Some(tokens.clone());
        // Save to IndexedDB
        unimplemented!()
    }

    /// Получить access token (с автоматическим refresh)
    pub async fn get_access_token<T: RestTransportTrait>(&mut self, transport: &T) -> Result<String> {
        if let Some(tokens) = &self.tokens {
            // Проверить истечение (5 минут buffer)
            if self.is_token_expiring_soon(tokens) {
                // Автоматический refresh
                let new_tokens = transport.refresh_token(tokens.refresh_token.clone()).await?;
                self.save_tokens(new_tokens.clone()).await?;
                return Ok(new_tokens.access_token);
            }
            Ok(tokens.access_token.clone())
        } else {
            Err(ConstructError::Unauthenticated("No tokens available".to_string()))
        }
    }

    /// Проверить, истекает ли токен скоро
    fn is_token_expiring_soon(&self, tokens: &AuthTokens) -> bool {
        let now = crate::utils::time::current_timestamp() as i64;
        let buffer = 5 * 60; // 5 минут
        tokens.expires_at - now < buffer
    }

    /// Очистить токены (logout)
    pub async fn clear_tokens(&mut self) -> Result<()> {
        self.tokens = None;
        // Clear from IndexedDB
        unimplemented!()
    }

    /// Получить состояние аутентификации
    pub fn get_auth_state(&self) -> AuthState {
        if let Some(tokens) = &self.tokens {
            AuthState {
                is_authenticated: true,
                token_expires_at: Some(tokens.expires_at),
                needs_refresh: self.is_token_expiring_soon(tokens),
            }
        } else {
            AuthState {
                is_authenticated: false,
                token_expires_at: None,
                needs_refresh: false,
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthState {
    pub is_authenticated: bool,
    pub token_expires_at: Option<i64>,
    pub needs_refresh: bool,
}
```

#### C. Long Polling Manager (`src/protocol/long_polling.rs`) - НОВЫЙ ФАЙЛ

```rust
use crate::protocol::rest_transport::RestTransport;
use crate::utils::error::Result;

pub struct LongPollingManager {
    last_message_id: Option<String>,
    polling: bool,
    timeout: u32, // seconds
}

impl LongPollingManager {
    pub fn new() -> Self {
        Self {
            last_message_id: None,
            polling: false,
            timeout: 30, // default 30 секунд
        }
    }

    /// Запустить long polling (в фоне)
    pub async fn start_polling<F>(
        &mut self,
        transport: &RestTransport,
        on_messages: F,
    ) -> Result<()>
    where
        F: Fn(Vec<ReceivedMessage>) + 'static,
    {
        self.polling = true;

        // TODO: Реализовать через wasm_bindgen_futures::spawn_local
        // для асинхронного polling в фоне
        unimplemented!()
    }

    /// Остановить polling
    pub fn stop_polling(&mut self) {
        self.polling = false;
    }

    /// Однократное получение сообщений (sync)
    pub async fn poll_once(&mut self, transport: &RestTransport) -> Result<Vec<ReceivedMessage>> {
        let response = transport
            .poll_messages(self.last_message_id.clone(), self.timeout)
            .await?;

        if let Some(next_id) = response.next_since {
            self.last_message_id = Some(next_id);
        }

        Ok(response.messages)
    }

    /// Установить timeout для polling
    pub fn set_timeout(&mut self, timeout: u32) {
        self.timeout = timeout;
    }
}
```

---

### 3. Обновление AppState

#### Новые поля в `AppState<P>`:

```rust
pub struct AppState<P: CryptoProvider> {
    // === Существующие поля ===
    user_id: Option<String>,
    username: Option<String>,
    crypto_manager: CryptoCore<P>,
    contact_manager: ContactManager,
    conversations_manager: ConversationsManager,
    storage: StorageType,

    // === НОВЫЕ поля для REST API ===
    #[cfg(target_arch = "wasm32")]
    rest_transport: Option<RestTransport>,

    #[cfg(target_arch = "wasm32")]
    token_manager: TokenManager<IndexedDbStorage>,

    #[cfg(target_arch = "wasm32")]
    long_polling_manager: LongPollingManager,

    // === Устаревшие поля (deprecated) ===
    #[cfg(target_arch = "wasm32")]
    transport: Option<WebSocketTransport>, // ⚠️ Deprecated

    connection_state: ConnectionState, // Для совместимости
    server_url: Option<String>,

    // ...остальное без изменений
}
```

#### Новые методы AppState (WASM bindings):

```rust
impl<P: CryptoProvider> AppState<P> {
    // =========================================
    // НОВЫЕ REST API МЕТОДЫ
    // =========================================

    /// Регистрация через REST API
    #[cfg(target_arch = "wasm32")]
    pub async fn register_rest(
        &mut self,
        server_url: String,
        username: String,
        password: String,
    ) -> Result<AuthTokens> {
        // 1. Создать REST transport
        let mut transport = RestTransport::new(server_url.clone());

        // 2. Получить registration bundle
        let bundle = self.crypto_manager.export_registration_bundle_uploadable()?;

        // 3. Зарегистрироваться
        let tokens = transport.register(username.clone(), password, bundle).await?;

        // 4. Сохранить токены
        self.token_manager.save_tokens(tokens.clone()).await?;

        // 5. Установить transport
        transport.set_access_token(tokens.access_token.clone());
        self.rest_transport = Some(transport);
        self.server_url = Some(server_url);

        // 6. Сохранить user_id
        self.user_id = Some(tokens.user_id.clone());
        self.username = Some(username);

        Ok(tokens)
    }

    /// Логин через REST API
    #[cfg(target_arch = "wasm32")]
    pub async fn login_rest(
        &mut self,
        server_url: String,
        username: String,
        password: String,
    ) -> Result<AuthTokens> {
        // Аналогично register_rest
        unimplemented!()
    }

    /// Обновить access token
    #[cfg(target_arch = "wasm32")]
    pub async fn refresh_token(&mut self) -> Result<AuthTokens> {
        let transport = self.rest_transport.as_ref()
            .ok_or(ConstructError::NetworkError("Not connected".to_string()))?;

        let tokens = self.token_manager.get_access_token(transport).await?;
        // TokenManager уже обновил токены автоматически
        Ok(tokens)
    }

    /// Logout
    #[cfg(target_arch = "wasm32")]
    pub async fn logout(&mut self, all_devices: bool) -> Result<()> {
        if let Some(transport) = &self.rest_transport {
            transport.logout(all_devices).await?;
        }

        self.token_manager.clear_tokens().await?;
        self.user_id = None;
        self.username = None;
        self.rest_transport = None;

        Ok(())
    }

    /// Отправить сообщение через REST
    #[cfg(target_arch = "wasm32")]
    pub async fn send_message_rest(
        &mut self,
        to_contact_id: &str,
        plaintext: &str,
    ) -> Result<String> {
        // 1. Зашифровать
        let encrypted = self.crypto_manager.encrypt_message_for_contact(
            to_contact_id,
            plaintext.as_bytes(),
        )?;

        // 2. Отправить через REST
        let transport = self.rest_transport.as_ref()
            .ok_or(ConstructError::NetworkError("Not connected".to_string()))?;

        let request = MessageRequest {
            recipient_id: to_contact_id.to_string(),
            suite_id: 1, // Classic suite
            ciphertext: base64::encode(&encrypted.ciphertext),
            nonce: Some(base64::encode(&encrypted.nonce)),
            timestamp: Some(current_timestamp() as i64),
        };

        let message_id = transport.send_message(request).await?;

        // 3. Сохранить в storage
        self.storage.save_message(StoredMessage {
            id: message_id.clone(),
            conversation_id: to_contact_id.to_string(),
            from: self.user_id.clone().unwrap(),
            to: to_contact_id.to_string(),
            plaintext: plaintext.to_string(),
            timestamp: current_timestamp(),
            status: MessageStatus::Sent,
        }).await?;

        Ok(message_id)
    }

    /// Получить сообщения через long polling (однократно)
    #[cfg(target_arch = "wasm32")]
    pub async fn poll_messages_once(&mut self) -> Result<Vec<ReceivedMessage>> {
        let transport = self.rest_transport.as_ref()
            .ok_or(ConstructError::NetworkError("Not connected".to_string()))?;

        let messages = self.long_polling_manager.poll_once(transport).await?;

        // Расшифровать и сохранить
        for msg in &messages {
            self.receive_and_store_message(msg).await?;
        }

        Ok(messages)
    }

    /// Запустить автоматический long polling (в фоне)
    #[cfg(target_arch = "wasm32")]
    pub async fn start_long_polling(&mut self) -> Result<()> {
        let transport = self.rest_transport.as_ref()
            .ok_or(ConstructError::NetworkError("Not connected".to_string()))?;

        // TODO: Callback для обработки сообщений
        self.long_polling_manager.start_polling(transport, |messages| {
            // Обработать сообщения
        }).await?;

        Ok(())
    }

    /// Остановить long polling
    #[cfg(target_arch = "wasm32")]
    pub fn stop_long_polling(&mut self) {
        self.long_polling_manager.stop_polling();
    }

    /// Получить состояние аутентификации
    #[cfg(target_arch = "wasm32")]
    pub fn get_auth_state(&self) -> AuthState {
        self.token_manager.get_auth_state()
    }

    /// Получить CSRF token
    #[cfg(target_arch = "wasm32")]
    pub async fn get_csrf_token(&mut self) -> Result<String> {
        let transport = self.rest_transport.as_mut()
            .ok_or(ConstructError::NetworkError("Not connected".to_string()))?;

        let token = transport.get_csrf_token().await?;
        transport.set_csrf_token(token.clone());
        Ok(token)
    }

    // =========================================
    // УСТАРЕВШИЕ МЕТОДЫ (для совместимости)
    // =========================================

    /// Подключиться к WebSocket (DEPRECATED)
    #[cfg(target_arch = "wasm32")]
    #[deprecated(note = "Use register_rest() or login_rest() instead")]
    pub fn connect(&mut self, server_url: &str) -> Result<()> {
        // Оставить для обратной совместимости
        // Но предупреждать в логах
        #[cfg(feature = "wasm")]
        crate::wasm::console::log("⚠️ app_state_connect() is deprecated. Use app_state_register_rest() or app_state_login_rest()");

        // Старая реализация
        self.connection_state = ConnectionState::Connecting;
        let mut transport = WebSocketTransport::new();
        transport.connect(server_url)?;
        self.setup_transport_callbacks(&mut transport)?;
        self.transport = Some(transport);
        self.connection_state = ConnectionState::Connected;
        Ok(())
    }

    /// Регистрация через WebSocket (DEPRECATED)
    #[cfg(target_arch = "wasm32")]
    #[deprecated(note = "Use register_rest() instead")]
    pub fn register_on_server(&self, password: String) -> Result<()> {
        #[cfg(feature = "wasm")]
        crate::wasm::console::log("⚠️ app_state_register_on_server() is deprecated. Use app_state_register_rest()");

        // Старая реализация через WebSocket
        // ...
        unimplemented!()
    }
}
```

---

### 4. WASM Bindings (`src/platforms/wasm/bindings.rs`)

#### Новые экспортируемые функции:

```rust
use wasm_bindgen::prelude::*;

// =========================================
// НОВЫЕ REST API ФУНКЦИИ
// =========================================

/// Регистрация через REST API
#[wasm_bindgen]
pub async fn app_state_register_rest(
    state_id: String,
    server_url: String,
    username: String,
    password: String,
) -> Result<JsValue, JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    let tokens = state.register_rest(server_url, username, password).await
        .map_err(|e| JsValue::from_str(&format!("Registration failed: {}", e)))?;

    // Вернуть как JS object
    serde_wasm_bindgen::to_value(&tokens)
        .map_err(|e| JsValue::from_str(&format!("Serialization error: {}", e)))
}

/// Логин через REST API
#[wasm_bindgen]
pub async fn app_state_login_rest(
    state_id: String,
    server_url: String,
    username: String,
    password: String,
) -> Result<JsValue, JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    let tokens = state.login_rest(server_url, username, password).await
        .map_err(|e| JsValue::from_str(&format!("Login failed: {}", e)))?;

    serde_wasm_bindgen::to_value(&tokens)
        .map_err(|e| JsValue::from_str(&format!("Serialization error: {}", e)))
}

/// Обновить access token
#[wasm_bindgen]
pub async fn app_state_refresh_token(state_id: String) -> Result<JsValue, JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    let tokens = state.refresh_token().await
        .map_err(|e| JsValue::from_str(&format!("Refresh failed: {}", e)))?;

    serde_wasm_bindgen::to_value(&tokens)
        .map_err(|e| JsValue::from_str(&format!("Serialization error: {}", e)))
}

/// Logout
#[wasm_bindgen]
pub async fn app_state_logout(state_id: String, all_devices: bool) -> Result<(), JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    state.logout(all_devices).await
        .map_err(|e| JsValue::from_str(&format!("Logout failed: {}", e)))
}

/// Отправить сообщение через REST
#[wasm_bindgen]
pub async fn app_state_send_message_rest(
    state_id: String,
    to_contact_id: String,
    text: String,
) -> Result<String, JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    state.send_message_rest(&to_contact_id, &text).await
        .map_err(|e| JsValue::from_str(&format!("Send failed: {}", e)))
}

/// Получить сообщения (long polling, однократно)
#[wasm_bindgen]
pub async fn app_state_poll_messages(state_id: String) -> Result<JsValue, JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    let messages = state.poll_messages_once().await
        .map_err(|e| JsValue::from_str(&format!("Poll failed: {}", e)))?;

    serde_wasm_bindgen::to_value(&messages)
        .map_err(|e| JsValue::from_str(&format!("Serialization error: {}", e)))
}

/// Запустить автоматический long polling
#[wasm_bindgen]
pub async fn app_state_start_long_polling(state_id: String) -> Result<(), JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    state.start_long_polling().await
        .map_err(|e| JsValue::from_str(&format!("Start polling failed: {}", e)))
}

/// Остановить long polling
#[wasm_bindgen]
pub fn app_state_stop_long_polling(state_id: String) -> Result<(), JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    state.stop_long_polling();
    Ok(())
}

/// Получить состояние аутентификации
#[wasm_bindgen]
pub fn app_state_get_auth_state(state_id: String) -> Result<JsValue, JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    let auth_state = state.get_auth_state();
    serde_wasm_bindgen::to_value(&auth_state)
        .map_err(|e| JsValue::from_str(&format!("Serialization error: {}", e)))
}

/// Получить CSRF token
#[wasm_bindgen]
pub async fn app_state_get_csrf_token(state_id: String) -> Result<String, JsValue> {
    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    state.get_csrf_token().await
        .map_err(|e| JsValue::from_str(&format!("CSRF token failed: {}", e)))
}

// =========================================
// УСТАРЕВШИЕ ФУНКЦИИ (для совместимости)
// =========================================

/// Подключиться к WebSocket (DEPRECATED)
#[wasm_bindgen]
#[deprecated]
pub fn app_state_connect(state_id: String, server_url: String) -> Result<(), JsValue> {
    web_sys::console::warn_1(&"⚠️ app_state_connect() is deprecated. Use app_state_register_rest() or app_state_login_rest()".into());

    let state_arc = get_app_state(&state_id)?;
    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    state.connect(&server_url)
        .map_err(|e| JsValue::from_str(&format!("Connect failed: {}", e)))
}

/// Регистрация через WebSocket (DEPRECATED)
#[wasm_bindgen]
#[deprecated]
pub fn app_state_register_on_server(state_id: String, password: String) -> Result<(), JsValue> {
    web_sys::console::warn_1(&"⚠️ app_state_register_on_server() is deprecated. Use app_state_register_rest()".into());

    let state_arc = get_app_state(&state_id)?;
    let state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Lock error: {}", e)))?;

    state.register_on_server(password)
        .map_err(|e| JsValue::from_str(&format!("Register failed: {}", e)))
}
```

---

## 📋 План реализации

<function_calls>
<invoke name="TodoWrite">
<parameter name="todos">[{"content": "Create REST transport layer (src/protocol/rest_transport.rs)", "activeForm": "Creating REST transport layer (src/protocol/rest_transport.rs)", "status": "pending"}, {"content": "Create Token Manager (src/auth/token_manager.rs)", "activeForm": "Creating Token Manager (src/auth/token_manager.rs)", "status": "pending"}, {"content": "Create Long Polling Manager (src/protocol/long_polling.rs)", "activeForm": "Creating Long Polling Manager (src/protocol/long_polling.rs)", "status": "pending"}, {"content": "Update AppState with REST methods", "activeForm": "Updating AppState with REST methods", "status": "pending"}, {"content": "Add new WASM bindings for REST API", "activeForm": "Adding new WASM bindings for REST API", "status": "pending"}, {"content": "Update TypeScript definitions for WASM", "activeForm": "Updating TypeScript definitions for WASM", "status": "pending"}, {"content": "Write integration tests for REST API", "activeForm": "Writing integration tests for REST API", "status": "pending"}, {"content": "Update construct-messenger-web client code", "activeForm": "Updating construct-messenger-web client code", "status": "pending"}, {"content": "Document iOS migration guide (REST in Swift)", "activeForm": "Documenting iOS migration guide (REST in Swift)", "status": "pending"}, {"content": "Analyze migration impact and create detailed plan", "activeForm": "Analyzing migration impact and creating detailed plan", "status": "completed"}]
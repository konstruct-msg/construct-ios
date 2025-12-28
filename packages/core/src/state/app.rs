use crate::api::contacts::{Contact, ContactManager};
use crate::api::crypto::CryptoCore;
use crate::storage::models::*;
use crate::utils::error::{ConstructError, Result};
use crate::utils::time::current_timestamp;
use std::collections::HashMap;

#[cfg(target_arch = "wasm32")]
use crate::storage::indexeddb::IndexedDbStorage;

#[cfg(not(target_arch = "wasm32"))]
use crate::storage::memory::MemoryStorage;

use crate::protocol::messages::ChatMessage;
use crate::state::conversations::ConversationsManager;
use crate::crypto::CryptoProvider;
use std::marker::PhantomData;

#[cfg(target_arch = "wasm32")]
use crate::protocol::transport::WebSocketTransport;



/// Состояние подключения к серверу
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
    Error,
}

/// Состояние UI
#[derive(Debug, Clone)]
pub struct UiState {
    pub is_loading: bool,
    pub error_message: Option<String>,
    pub notification: Option<String>,
}

impl UiState {
    pub fn new() -> Self {
        Self {
            is_loading: false,
            error_message: None,
            notification: None,
        }
    }

    pub fn set_loading(&mut self, loading: bool) {
        self.is_loading = loading;
    }

    pub fn set_error(&mut self, error: String) {
        self.error_message = Some(error);
    }

    pub fn clear_error(&mut self) {
        self.error_message = None;
    }

    pub fn set_notification(&mut self, notification: String) {
        self.notification = Some(notification);
    }

    pub fn clear_notification(&mut self) {
        self.notification = None;
    }
}

impl Default for UiState {
    fn default() -> Self {
        Self::new()
    }
}

/// Состояние автоматического переподключения
#[derive(Debug, Clone)]
pub struct ReconnectState {
    /// Количество попыток переподключения
    attempts: u32,
    /// Максимальное количество попыток (0 = бесконечно)
    max_attempts: u32,
    /// Текущая задержка в миллисекундах
    current_delay_ms: u32,
    /// Начальная задержка в миллисекундах
    initial_delay_ms: u32,
    /// Максимальная задержка в миллисекундах
    max_delay_ms: u32,
    /// Включено ли автоматическое переподключение
    enabled: bool,
}

impl ReconnectState {
    /// Создать новое состояние переподключения
    pub fn new() -> Self {
        let cfg = crate::config::Config::global();
        let initial_delay = cfg.websocket_retry_initial_ms as u32;
        let max_delay = cfg.websocket_retry_max_ms as u32;

        Self {
            attempts: 0,
            max_attempts: 0,        // Бесконечные попытки
            current_delay_ms: initial_delay,
            initial_delay_ms: initial_delay,
            max_delay_ms: max_delay,
            enabled: true,
        }
    }

    /// Вычислить следующую задержку с exponential backoff
    pub fn next_delay(&mut self) -> u32 {
        let delay = self.current_delay_ms;

        // Exponential backoff: удваиваем задержку
        self.current_delay_ms = (self.current_delay_ms * 2).min(self.max_delay_ms);
        self.attempts += 1;

        delay
    }

    /// Сбросить счётчик попыток
    pub fn reset(&mut self) {
        self.attempts = 0;
        self.current_delay_ms = self.initial_delay_ms;
    }

    /// Проверить, можно ли продолжать попытки
    pub fn can_retry(&self) -> bool {
        self.enabled && (self.max_attempts == 0 || self.attempts < self.max_attempts)
    }

    /// Получить количество попыток
    pub fn attempts(&self) -> u32 {
        self.attempts
    }

    /// Включить/выключить автоматическое переподключение
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }
}

impl Default for ReconnectState {
    fn default() -> Self {
        Self::new()
    }
}

/// Главное состояние всего приложения
pub struct AppState<P: CryptoProvider> {
    // === Идентификация пользователя ===
    user_id: Option<String>,
    username: Option<String>,

    // === Менеджеры ===
    crypto_manager: CryptoCore<P>,
    contact_manager: ContactManager,
    conversations_manager: ConversationsManager,

    // === Хранилище ===
    #[cfg(target_arch = "wasm32")]
    storage: IndexedDbStorage,

    #[cfg(not(target_arch = "wasm32"))]
    storage: MemoryStorage,

    // === Сетевое соединение ===
    #[cfg(target_arch = "wasm32")]
    transport: Option<WebSocketTransport>,

    // === Состояние соединения ===
    connection_state: ConnectionState,
    server_url: Option<String>,
    reconnect_state: ReconnectState,

    // === Кеш сообщений (в памяти) ===
    message_cache: HashMap<String, Vec<StoredMessage>>,

    // === Состояние UI ===
    active_conversation: Option<String>,
    ui_state: UiState,

    _phantom: PhantomData<P>,
}

impl<P: CryptoProvider> AppState<P> {
    /// Создать новое состояние приложения
    #[cfg(target_arch = "wasm32")]
    pub async fn new() -> Result<Self> {
        let mut storage = IndexedDbStorage::new();
        storage.init().await?;

        let crypto_manager = CryptoCore::<P>::new()?;
        let contact_manager = ContactManager::new();
        let conversations_manager = ConversationsManager::new();

        Ok(Self {
            user_id: None,
            username: None,
            crypto_manager,
            contact_manager,
            conversations_manager,
            storage,
            transport: None,
            connection_state: ConnectionState::Disconnected,
            server_url: None,
            reconnect_state: ReconnectState::new(),
            message_cache: HashMap::new(),
            active_conversation: None,
            ui_state: UiState::new(),
            _phantom: PhantomData,
        })
    }

    /// Создать новое состояние приложения (non-WASM версия)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn new(_db_name: &str) -> Result<Self> {
        let storage = MemoryStorage::new();
        let crypto_manager = CryptoCore::<P>::new()?;
        let contact_manager = ContactManager::new();
        let conversations_manager = ConversationsManager::new();

        Ok(Self {
            user_id: None,
            username: None,
            crypto_manager,
            contact_manager,
            conversations_manager,
            storage,
            connection_state: ConnectionState::Disconnected,
            server_url: None,
            reconnect_state: ReconnectState::new(),
            message_cache: HashMap::new(),
            active_conversation: None,
            ui_state: UiState::new(),
            _phantom: PhantomData,
        })
    }

    // === Инициализация пользователя ===

    /// Инициализировать нового пользователя (только создать ключи, не сохранять)
    /// UUID будет получен от сервера после успешной регистрации
    #[cfg(target_arch = "wasm32")]
    pub async fn initialize_user(&mut self, username: String, password: String) -> Result<()> {
        use crate::crypto::master_key;

        self.ui_state.set_loading(true);

        // Валидация пароля
        master_key::validate_password(&password)?;

        // Криптографические ключи уже созданы в CryptoManager при создании AppState
        // Просто сохраняем username и password временно (password нужен для finalize_registration)
        self.username = Some(username);

        self.ui_state.set_loading(false);
        Ok(())
    }

    /// Завершить регистрацию после получения UUID от сервера
    #[cfg(target_arch = "wasm32")]
    pub async fn finalize_registration(
        &mut self,
        server_user_id: String,
        _session_token: String,
        password: String,
    ) -> Result<()> {
        unimplemented!()
    }

    /// Инициализировать нового пользователя (non-WASM версия)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn initialize_user(&mut self, username: String, password: String) -> Result<()> {
        use crate::crypto::master_key;

        self.ui_state.set_loading(true);

        // Валидация пароля
        master_key::validate_password(&password)?;

        // Только сохраняем username
        self.username = Some(username);

        self.ui_state.set_loading(false);
        Ok(())
    }

    /// Завершить регистрацию (non-WASM версия)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn finalize_registration(
        &mut self,
        server_user_id: String,
        _session_token: String,
        password: String,
    ) -> Result<()> {
        unimplemented!()
    }

    /// Загрузить существующего пользователя
    #[cfg(target_arch = "wasm32")]
    pub async fn load_user(&mut self, user_id: String, password: String) -> Result<()> {
        unimplemented!()
    }

    /// Загрузить существующего пользователя (non-WASM версия)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn load_user(&mut self, user_id: String, password: String) -> Result<()> {
        unimplemented!()
    }

    // === Управление контактами ===

    /// Добавить контакт
    #[cfg(target_arch = "wasm32")]
    pub async fn add_contact(&mut self, contact_id: String, username: String) -> Result<()> {
        // 1. Добавить в ContactManager
        let contact = crate::api::contacts::create_contact(contact_id.clone(), username.clone());
        self.contact_manager.add_contact(contact)?;

        // 2. Сохранить в storage
        let stored = StoredContact {
            id: contact_id,
            username,
            public_key_bundle: None,
            added_at: current_timestamp(),
            last_message_at: None,
        };
        self.storage.save_contact(stored).await?;

        Ok(())
    }

    /// Добавить контакт (non-WASM версия)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn add_contact(&mut self, contact_id: String, username: String) -> Result<()> {
        let contact = crate::api::contacts::create_contact(contact_id.clone(), username.clone());
        self.contact_manager.add_contact(contact)?;

        let stored = StoredContact {
            id: contact_id,
            username,
            public_key_bundle: None,
            added_at: current_timestamp(),
            last_message_at: None,
        };
        self.storage.save_contact(stored)?;

        Ok(())
    }

    /// Получить все контакты
    pub fn get_contacts(&self) -> Vec<&Contact> {
        self.contact_manager.get_all_contacts()
    }

    // === Работа с сообщениями ===

    /// Отправить сообщение
    #[cfg(target_arch = "wasm32")]
    pub async fn send_message(
        &mut self,
        to_contact_id: &str,
        session_id: &str,
        plaintext: &str,
    ) -> Result<String> {
        unimplemented!()
    }

    /// Отправить сообщение (non-WASM версия)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn send_message(
        &mut self,
        to_contact_id: &str,
        _session_id: &str,
        plaintext: &str,
    ) -> Result<String> {
        unimplemented!()
    }

    /// Обработать входящее сообщение
    #[cfg(target_arch = "wasm32")]
    pub async fn receive_message(&mut self, chat_msg: ChatMessage, session_id: &str) -> Result<()> {
        unimplemented!()
    }

    /// Обработать входящее сообщение (non-WASM заглушка)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn receive_message(&mut self, _chat_msg: ChatMessage, _session_id: &str) -> Result<()> {
        Ok(())
    }

    /// Обновить кеш сообщений
    #[cfg(target_arch = "wasm32")]
    async fn update_message_cache(
        &mut self,
        conversation_id: &str,
        msg: StoredMessage,
    ) -> Result<()> {
        unimplemented!()
    }

    /// Загрузить беседу
    #[cfg(target_arch = "wasm32")]
    pub async fn load_conversation(&mut self, contact_id: &str) -> Result<Vec<StoredMessage>> {
        unimplemented!()
    }

    /// Загрузить беседу (non-WASM версия)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn load_conversation(&mut self, contact_id: &str) -> Result<Vec<StoredMessage>> {
        unimplemented!()
    }

    /// Установить активную беседу
    pub fn set_active_conversation(&mut self, contact_id: Option<String>) {
        self.active_conversation = contact_id;
    }

    /// Получить активную беседу
    pub fn get_active_conversation(&self) -> Option<&str> {
        self.active_conversation.as_deref()
    }

    // === Управление соединением ===

    /// Подключиться к серверу WebSocket
    #[cfg(target_arch = "wasm32")]
    pub fn connect(&mut self, server_url: &str) -> Result<()> {
        if self.connection_state == ConnectionState::Connected {
            return Err(ConstructError::NetworkError(
                "Already connected".to_string(),
            ));
        }

        self.connection_state = ConnectionState::Connecting;

        let mut transport = WebSocketTransport::new();
        transport.connect(server_url)?;

        // Настроить базовые callbacks
        self.setup_transport_callbacks(&mut transport)?;

        self.transport = Some(transport);
        self.connection_state = ConnectionState::Connected;

        Ok(())
    }

    /// Настроить WebSocket callbacks (базовая версия без Arc)
    /// Эта версия используется внутри AppState, где мы не имеем доступа к Arc
    #[cfg(target_arch = "wasm32")]
    fn setup_transport_callbacks(&self, transport: &mut WebSocketTransport) -> Result<()> {
        use crate::wasm::console;

        // Callback для успешного подключения
        transport.set_on_open(|| {
            console::log("✅ WebSocket connected successfully");
        })?;

        // Базовый callback для входящих сообщений
        transport.set_on_message(|msg| {
            console::log(&format!("📩 Received message: {:?}", msg));
        })?;

        // Callback для ошибок
        transport.set_on_error(|err| {
            console::log(&format!("❌ WebSocket error: {}", err));
        })?;

        // Callback для закрытия соединения
        transport.set_on_close(|code, reason| {
            console::log(&format!("🔌 WebSocket closed: {} - {}", code, reason));
        })?;

        Ok(())
    }

    /// Настроить WebSocket callbacks с доступом к Arc<Mutex<AppState>>
    /// Эта версия вызывается из WASM bindings и имеет полный доступ к AppState
    #[cfg(target_arch = "wasm32")]
    pub fn setup_transport_callbacks_with_arc(
        transport: &mut WebSocketTransport,
        app_state_arc: std::sync::Arc<std::sync::Mutex<AppState<P>>>,
    ) -> Result<()> {
        unimplemented!()
    }

    /// Подключиться к серверу (non-WASM заглушка)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn connect(&mut self, _server_url: &str) -> Result<()> {
        Err(ConstructError::NetworkError(
            "WebSocket only available in WASM".to_string(),
        ))
    }

    /// Отключиться от сервера
    #[cfg(target_arch = "wasm32")]
    pub fn disconnect(&mut self) -> Result<()> {
        if let Some(transport) = &mut self.transport {
            transport.close()?;
        }

        self.transport = None;
        self.connection_state = ConnectionState::Disconnected;

        Ok(())
    }

    /// Отключиться от сервера (non-WASM заглушка)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn disconnect(&mut self) -> Result<()> {
        self.connection_state = ConnectionState::Disconnected;
        Ok(())
    }

    /// Установить WebSocket транспорт
    /// Используется из WASM bindings после настройки callbacks
    #[cfg(target_arch = "wasm32")]
    pub fn set_transport(&mut self, transport: WebSocketTransport) {
        self.transport = Some(transport);
        self.connection_state = ConnectionState::Connecting;
    }

    /// Установить состояние соединения
    pub fn set_connection_state(&mut self, state: ConnectionState) {
        self.connection_state = state;
    }

    /// Получить состояние соединения
    pub fn connection_state(&self) -> ConnectionState {
        self.connection_state
    }

    /// Проверить, подключен ли к серверу
    pub fn is_connected(&self) -> bool {
        self.connection_state == ConnectionState::Connected
    }

    /// Установить URL сервера
    pub fn set_server_url(&mut self, url: String) {
        self.server_url = Some(url);
    }

    /// Получить URL сервера
    pub fn get_server_url(&self) -> Option<&str> {
        self.server_url.as_deref()
    }

    /// Получить состояние переподключения
    pub fn reconnect_state(&self) -> &ReconnectState {
        &self.reconnect_state
    }

    /// Получить мутабельное состояние переподключения
    pub fn reconnect_state_mut(&mut self) -> &mut ReconnectState {
        &mut self.reconnect_state
    }

    /// Запланировать автоматическое переподключение
    #[cfg(target_arch = "wasm32")]
    pub fn schedule_reconnect(app_state_arc: std::sync::Arc<std::sync::Mutex<AppState<P>>>) {
        unimplemented!()
    }

    /// Попытка переподключения
    #[cfg(target_arch = "wasm32")]
    async fn attempt_reconnect(
        app_state_arc: std::sync::Arc<std::sync::Mutex<AppState<P>>>,
        server_url: &str,
    ) -> Result<()> {
        unimplemented!()
    }

    // === Геттеры для UI ===

    pub fn get_user_id(&self) -> Option<&str> {
        self.user_id.as_deref()
    }

    pub fn get_username(&self) -> Option<&str> {
        self.username.as_deref()
    }

    pub fn ui_state(&self) -> &UiState {
        &self.ui_state
    }

    pub fn ui_state_mut(&mut self) -> &mut UiState {
        &mut self.ui_state
    }

    pub fn crypto_manager(&self) -> &CryptoCore<P> {
        &self.crypto_manager
    }

    pub fn crypto_manager_mut(&mut self) -> &mut CryptoCore<P> {
        &mut self.crypto_manager
    }

    pub fn conversations_manager(&self) -> &ConversationsManager {
        &self.conversations_manager
    }

    pub fn conversations_manager_mut(&mut self) -> &mut ConversationsManager {
        &mut self.conversations_manager
    }

    // === Очистка ===

    /// Очистить все данные
    #[cfg(target_arch = "wasm32")]
    pub async fn clear_all_data(&mut self) -> Result<()> {
        // Очистить кеши
        self.message_cache.clear();
        self.conversations_manager.clear_all();
        self.contact_manager.clear_all();

        // Сбросить состояние
        self.user_id = None;
        self.username = None;
        self.active_conversation = None;
        self.connection_state = ConnectionState::Disconnected;

        // TODO: Очистить IndexedDB полностью

        Ok(())
    }

    /// Очистить все данные (non-WASM версия)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn clear_all_data(&mut self) -> Result<()> {
        self.message_cache.clear();
        self.conversations_manager.clear_all();
        self.contact_manager.clear_all();
        self.storage.clear_all()?;

        self.user_id = None;
        self.username = None;
        self.active_conversation = None;
        self.connection_state = ConnectionState::Disconnected;

        Ok(())
    }

    // === Регистрация на сервере ===

    /// Зарегистрировать пользователя на сервере
    /// Отправляет сообщение Register с username, password и registration bundle
    #[cfg(target_arch = "wasm32")]
    pub fn register_on_server(&self, password: String) -> Result<()> {
        use crate::protocol::messages::{ClientMessage, RegisterData};

        // 1. Проверить, что пользователь инициализирован
        let username = self.username.as_ref()
            .ok_or_else(|| ConstructError::InvalidInput(
                "User not initialized. Call initialize_user first.".to_string()
            ))?;

        // 2. Проверить, что есть transport
        let transport = self.transport.as_ref()
            .ok_or_else(|| ConstructError::NetworkError(
                "Not connected to server. Call connect first.".to_string()
            ))?;

        // 3. Получить registration bundle в base64
        let bundle = self.crypto_manager.export_registration_bundle_b64()?;

        // 4. Сериализовать bundle в JSON для public_key поля
        let public_key = serde_json::to_string(&bundle)
            .map_err(|e| ConstructError::SerializationError(
                format!("Failed to serialize registration bundle: {}", e)
            ))?;

        // 5. Создать RegisterData
        let register_data = RegisterData {
            username: username.clone(),
            display_name: username.clone(), // Используем username как display_name
            password,
            public_key,
        };

        // 6. Отправить через transport
        let message = ClientMessage::Register(register_data);
        transport.send(&message)?;

        Ok(())
    }

    /// Зарегистрировать пользователя на сервере (non-WASM заглушка)
    #[cfg(not(target_arch = "wasm32"))]
    pub fn register_on_server(&self, _password: String) -> Result<()> {
        Err(ConstructError::NetworkError(
            "Registration only available in WASM".to_string(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::suites::classic::ClassicSuiteProvider;

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn test_app_state_creation() {
        let state = AppState::<ClassicSuiteProvider>::new("test_db");
        assert!(state.is_ok());

        let state = state.unwrap();
        assert!(state.get_user_id().is_none());
        assert_eq!(state.connection_state(), ConnectionState::Disconnected);
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn test_app_state_initialize_user() {
        let mut state = AppState::<ClassicSuiteProvider>::new("test_db").unwrap();
        state
            .initialize_user("alice".to_string(), "testpass123".to_string())
            .unwrap();

        assert_eq!(state.get_username(), Some("alice"));
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn test_app_state_contacts() {
        let mut state = AppState::<ClassicSuiteProvider>::new("test_db").unwrap();
        state
            .initialize_user("alice".to_string(), "testpass123".to_string())
            .unwrap();

        state
            .add_contact("contact1".to_string(), "bob".to_string())
            .unwrap();

        let contacts = state.get_contacts();
        assert_eq!(contacts.len(), 1);
        assert_eq!(contacts[0].username, "bob");
    }
}
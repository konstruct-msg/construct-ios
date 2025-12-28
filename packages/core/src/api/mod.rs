// Публичный API для мессенджера
// Высокоуровневые методы для работы с мессенджером

pub mod messaging;
pub mod contacts;
pub mod crypto;

/// Главный API для мессенджера
pub struct MessengerAPI {
    // Внутренние компоненты будут добавлены по мере необходимости
}

impl MessengerAPI {
    pub fn new() -> Self {
        Self {}
    }

    /// Инициализация мессенджера
    /// В текущей реализации не требует дополнительных действий
    pub async fn initialize(&mut self) -> crate::utils::error::Result<()> {
        Ok(())
    }
}

impl Default for MessengerAPI {
    fn default() -> Self {
        Self::new()
    }
}

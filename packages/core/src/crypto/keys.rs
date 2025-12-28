// Управление ключами
// Хранение и ротация криптографических ключей

use crate::utils::error::{ConstructError, Result};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use std::collections::HashMap;
use x25519_dalek::{PublicKey, StaticSecret};
use crate::crypto::CryptoProvider;
use std::marker::PhantomData;

/// Пара ключей X25519
#[derive(Clone)]
pub struct X25519KeyPair {
    pub secret: StaticSecret,
    pub public: PublicKey,
}

impl X25519KeyPair {
    pub fn generate() -> Self {
        let secret = StaticSecret::random_from_rng(rand::rngs::OsRng);
        let public = PublicKey::from(&secret);
        Self { secret, public }
    }

    pub fn from_secret(secret: StaticSecret) -> Self {
        let public = PublicKey::from(&secret);
        Self { secret, public }
    }
}

/// Пара ключей Ed25519 для подписи
#[derive(Clone)]
pub struct Ed25519KeyPair {
    pub signing_key: SigningKey,
    pub verifying_key: VerifyingKey,
}

impl Ed25519KeyPair {
    pub fn generate() -> Self {
        let signing_key = SigningKey::generate(&mut rand::rngs::OsRng);
        let verifying_key = signing_key.verifying_key();
        Self {
            signing_key,
            verifying_key,
        }
    }

    pub fn sign(&self, message: &[u8]) -> Signature {
        self.signing_key.sign(message)
    }
}

/// Хранилище prekey с метаданными
#[derive(Clone)]
pub struct PrekeyStore<P: CryptoProvider> {
    pub key_pair: (P::KemPrivateKey, P::KemPublicKey),
    pub signature: Vec<u8>,
    pub created_at: i64,
    pub key_id: u32,
}

/// Менеджер криптографических ключей
pub struct KeyManager<P: CryptoProvider> {
    /// Identity ключ (долговременный)
    identity_key: Option<(P::KemPrivateKey, P::KemPublicKey)>,

    /// Signing ключ для подписей
    signing_key: Option<(P::SignaturePrivateKey, P::SignaturePublicKey)>,

    /// Текущий signed prekey
    current_signed_prekey: Option<PrekeyStore<P>>,

    /// История старых prekey для обратной совместимости
    old_prekeys: HashMap<u32, PrekeyStore<P>>,

    /// Счетчик для key_id
    next_prekey_id: u32,

    _phantom: PhantomData<P>,
}

impl<P: CryptoProvider> KeyManager<P> {
    /// Создать новый KeyManager
    pub fn new() -> Self {
        Self {
            identity_key: None,
            signing_key: None,
            current_signed_prekey: None,
            old_prekeys: HashMap::new(),
            next_prekey_id: 1,
            _phantom: PhantomData,
        }
    }

    /// Инициализировать с новыми ключами
    pub fn initialize(&mut self) -> Result<()> {
        self.identity_key = Some(P::generate_kem_keys().map_err(|e| ConstructError::CryptoError(e.to_string()))?);
        self.signing_key = Some(P::generate_signature_keys().map_err(|e| ConstructError::CryptoError(e.to_string()))?);
        self.rotate_signed_prekey()?;
        Ok(())
    }

    /// Получить identity public key
    pub fn identity_public_key(&self) -> Result<&P::KemPublicKey> {
        self.identity_key
            .as_ref()
            .map(|k| &k.1)
            .ok_or_else(|| ConstructError::CryptoError("Identity key not initialized".to_string()))
    }

    /// Получить identity secret key
    pub fn identity_secret_key(&self) -> Result<&P::KemPrivateKey> {
        self.identity_key
            .as_ref()
            .map(|k| &k.0)
            .ok_or_else(|| ConstructError::CryptoError("Identity key not initialized".to_string()))
    }

    /// Получить verifying key
    pub fn verifying_key(&self) -> Result<&P::SignaturePublicKey> {
        self.signing_key
            .as_ref()
            .map(|k| &k.1)
            .ok_or_else(|| ConstructError::CryptoError("Signing key not initialized".to_string()))
    }

    /// Получить текущий signed prekey
    pub fn current_signed_prekey(&self) -> Result<&PrekeyStore<P>> {
        self.current_signed_prekey
            .as_ref()
            .ok_or_else(|| ConstructError::CryptoError("No signed prekey available".to_string()))
    }

    /// Ротация signed prekey
    pub fn rotate_signed_prekey(&mut self) -> Result<()> {
        let (signing_key, _) = self.signing_key.as_ref().ok_or_else(|| {
            ConstructError::CryptoError("Signing key not initialized".to_string())
        })?;

        // Генерируем новый prekey
        let key_pair = P::generate_kem_keys().map_err(|e| ConstructError::CryptoError(e.to_string()))?;
        let signature = P::sign(signing_key, &key_pair.1.as_ref()).map_err(|e| ConstructError::CryptoError(e.to_string()))?;

        let key_id = self.next_prekey_id;
        self.next_prekey_id += 1;

        let prekey_store = PrekeyStore {
            key_pair,
            signature,
            created_at: crate::utils::time::current_timestamp(),
            key_id,
        };

        // Сохраняем старый prekey в историю
        if let Some(old_prekey) = self.current_signed_prekey.take() {
            self.old_prekeys.insert(old_prekey.key_id, old_prekey);
        }

        self.current_signed_prekey = Some(prekey_store);

        // Очищаем старые prekeys (используя конфигурируемый период)
        self.cleanup_old_prekeys(crate::config::Config::global().prekey_cleanup_period_secs);

        Ok(())
    }

    /// Получить prekey по ID
    pub fn get_prekey(&self, key_id: u32) -> Option<&PrekeyStore<P>> {
        if let Some(current) = &self.current_signed_prekey {
            if current.key_id == key_id {
                return Some(current);
            }
        }
        self.old_prekeys.get(&key_id)
    }

    /// Очистка старых prekeys
    fn cleanup_old_prekeys(&mut self, max_age_seconds: i64) {
        let now = crate::utils::time::current_timestamp();
        self.old_prekeys
            .retain(|_, prekey| now - prekey.created_at < max_age_seconds);
    }

    /// Экспорт регистрационного bundle
    pub fn export_registration_bundle(&self) -> Result<crate::crypto::RegistrationBundle> {
        let identity_public = self.identity_public_key()?.as_ref().to_vec();
        let verifying_key = self.verifying_key()?.as_ref().to_vec();
        let prekey = self.current_signed_prekey()?;

        Ok(crate::crypto::RegistrationBundle {
            identity_public,
            signed_prekey_public: prekey.key_pair.1.as_ref().to_vec(),
            signature: prekey.signature.clone(),
            verifying_key,
            suite_id: P::suite_id(),
        })
    }

    /// Экспорт публичного key bundle
    pub fn export_public_bundle(&self) -> Result<crate::crypto::PublicKeyBundle> {
        let identity_public = self.identity_public_key()?.as_ref().to_vec();
        let verifying_key = self.verifying_key()?.as_ref().to_vec();
        let prekey = self.current_signed_prekey()?;

        Ok(crate::crypto::PublicKeyBundle {
            identity_public,
            signed_prekey_public: prekey.key_pair.1.as_ref().to_vec(),
            signature: prekey.signature.clone(),
            verifying_key,
            suite_id: P::suite_id(),
        })
    }

    /// Подписать данные
    pub fn sign(&self, data: &[u8]) -> Result<Vec<u8>> {
        let (signing_key, _) = self.signing_key.as_ref().ok_or_else(|| {
            ConstructError::CryptoError("Signing key not initialized".to_string())
        })?;

        P::sign(signing_key, data).map_err(|e| ConstructError::CryptoError(e.to_string()))
    }

    /// Количество сохраненных старых prekeys
    pub fn old_prekeys_count(&self) -> usize {
        self.old_prekeys.len()
    }

    /// Получить signing key для экспорта
    pub fn signing_secret_key(&self) -> Result<&P::SignaturePrivateKey> {
        self.signing_key
            .as_ref()
            .map(|k| &k.0)
            .ok_or_else(|| ConstructError::CryptoError("Signing key not initialized".to_string()))
    }
}

impl<P: CryptoProvider> Default for KeyManager<P> {
    fn default() -> Self {
        Self::new()
    }
}
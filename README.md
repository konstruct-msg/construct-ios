# 🔐 Construct Messenger

**Secure end-to-end encrypted messenger с крипто-гибкостью и готовностью к постквантовой эре**

[![Rust](https://img.shields.io/badge/Rust-1.75+-orange.svg)](https://www.rust-lang.org/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-red.svg)](https://swift.org/)
[![UniFFI](https://img.shields.io/badge/UniFFI-0.28-blue.svg)](https://mozilla.github.io/uniffi-rs/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 🎯 О проекте

Construct Messenger - это современный мессенджер с **end-to-end шифрованием**, построенный на:

- **Double Ratchet Protocol** (Signal Protocol) для forward secrecy
- **X3DH** для асинхронного key agreement
- **Rust Core** для 90% криптографической логики
- **Crypto-Agility** для поддержки различных криптографических алгоритмов
- **Post-Quantum Ready** архитектура для гибридных схем (Kyber + Dilithium)

### Ключевые особенности

- ✅ **100% E2EE** - Сервер никогда не видит plaintext
- ✅ **Forward Secrecy** - Компрометация ключей не раскрывает историю
- ✅ **Crypto-Agility** - Поддержка множественных криптографических наборов
- ✅ **Zero unsafe** - Весь Rust код безопасен (0 `unsafe` блоков)
- ✅ **Multi-Platform** - Единое Rust ядро для iOS, Android, Web
- 🚧 **Post-Quantum** - Гибридные схемы (в разработке)

---

## 🏗️ Архитектура

```
┌─────────────────────────────────────────────────────┐
│                 Swift UI Layer (iOS)                │
│  - Thin wrapper over Rust                           │
│  - Core Data persistence                            │
│  - WebSocket client                                 │
└───────────────────────┬─────────────────────────────┘
                        │ UniFFI
┌───────────────────────▼─────────────────────────────┐
│              Rust Core (construct-core)             │
│  ✅ Double Ratchet Protocol                         │
│  ✅ X3DH key agreement                              │
│  ✅ Classic Suite (X25519 + Ed25519 + ChaCha20)     │
│  ✅ Crypto-Agility (pluggable crypto providers)     │
│  ✅ MessagePack serialization                       │
│  ✅ Session management                              │
└───────────────────────┬─────────────────────────────┘
                        │ WebSocket + MessagePack
┌───────────────────────▼─────────────────────────────┐
│            Rust Server (Actix + PostgreSQL)         │
│  - Message routing                                  │
│  - Key bundle storage                               │
│  - User authentication                              │
│  - NO access to message content (E2EE)              │
└─────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start

### Требования

- **Rust** 1.75+ ([rustup](https://rustup.rs/))
- **Xcode** 15+ (для iOS)
- **UniFFI** 0.28
- **PostgreSQL** 14+ (для сервера)

### Сборка iOS приложения

```bash
# 1. Соберите Rust библиотеку
cd packages/core
cargo build --release --target aarch64-apple-ios

# 2. Сгенерируйте Swift bindings
uniffi-bindgen generate \
  --library ../../target/aarch64-apple-ios/release/libconstruct_core.a \
  --language swift \
  --out-dir bindings/swift

# 3. Скопируйте в Xcode проект
cp ../../target/aarch64-apple-ios/release/libconstruct_core.a ../../
cp bindings/swift/construct_core.swift ../../ConstructMessenger/
cp bindings/swift/construct_coreFFI.h ../../ConstructMessenger/

# 4. Откройте Xcode и запустите
open ../../ConstructMessenger.xcodeproj
```

### Запуск сервера

```bash
# 1. Настройте PostgreSQL
createdb construct_messenger

# 2. Запустите миграции
cd packages/server
sqlx migrate run

# 3. Запустите сервер
cargo run --release
```

---

## 📚 Документация

### Начало работы
- [**ARCHITECTURE_RESPONSIBILITY.md**](docs/ARCHITECTURE_RESPONSIBILITY.md) - 🎯 **Ключевой принцип:** Swift = тонкий клиент, Rust = вся логика
- [**RUST_SWIFT_INTEGRATION.md**](docs/RUST_SWIFT_INTEGRATION.md) - Полное руководство по интеграции Rust + Swift
- [**XCODE_INTEGRATION.md**](XCODE_INTEGRATION.md) - Настройка Xcode проекта
- [**ROADMAP.md**](docs/ROADMAP.md) - План развития и постквантовая криптография
- [**TESTING.md**](TESTING.md) - Руководство по тестированию

### API и протокол
- [**API_V3_SPEC.md**](docs/API_V3_SPEC.md) - Спецификация API с crypto-agility
- [**api/CLIENT_API.md**](docs/api/CLIENT_API.md) - WebSocket API документация
- [**api/websocket-protocol.md**](docs/api/websocket-protocol.md) - Протокол коммуникации

### Архитектура
- [**architecture/00-OVERVIEW.md**](docs/architecture/00-OVERVIEW.md) - Обзор архитектуры
- [**architecture/01-RUST-AS-CORE.md**](docs/architecture/01-RUST-AS-CORE.md) - Философия Rust как ядра
- [**ARCHITECTURE_RESPONSIBILITY.md**](docs/ARCHITECTURE_RESPONSIBILITY.md) - Распределение ответственности

### Безопасность
- [**security/encryption.md**](docs/security/encryption.md) - Криптографический стек
- [**security/post-quantum-cryptography.md**](docs/security/post-quantum-cryptography.md) - PQ криптография
- [**security/key-management.md**](docs/security/key-management.md) - Управление ключами

---

## 🔐 Криптография

### Classic Suite (v1) - Production

| Компонент | Алгоритм | Назначение |
|-----------|----------|------------|
| Key Agreement | **X25519** (ECDH) | Ephemeral DH для ratcheting |
| Signatures | **Ed25519** | Подписи prekeys |
| AEAD | **ChaCha20-Poly1305** | Шифрование сообщений |
| KDF | **HKDF-SHA256** | Деривация ключей |

### Post-Quantum Hybrid Suite (v2) - В разработке

| Компонент | Алгоритм | Назначение |
|-----------|----------|------------|
| Key Agreement | **X25519 ⊕ Kyber768** | Гибридный KEM |
| Signatures | **Ed25519 + Dilithium3** | Гибридные подписи |
| AEAD | **ChaCha20-Poly1305** | Шифрование (без изменений) |

**Философия:** Hybrid = защита от квантовых компьютеров + защита от уязвимостей в новых алгоритмах

---

## 🛠️ Структура проекта

```
construct-messenger/
├── docs/                    # 📚 Документация
│   ├── api/                # API спецификации
│   ├── architecture/       # Архитектурные решения
│   └── security/           # Безопасность и криптография
│
├── packages/
│   ├── core/               # 🦀 Rust криптографическое ядро
│   │   ├── src/
│   │   │   ├── crypto/    # Криптографические модули
│   │   │   │   ├── classic_suite.rs
│   │   │   │   ├── crypto_provider.rs
│   │   │   │   ├── double_ratchet.rs
│   │   │   │   └── x3dh.rs
│   │   │   ├── uniffi_bindings.rs  # UniFFI wrapper
│   │   │   └── construct_core.udl  # UniFFI interface
│   │   ├── Cargo.toml
│   │   └── build.rs
│   │
│   └── server/             # 🦀 Rust WebSocket сервер
│       ├── src/
│       │   ├── handlers/  # Message handlers
│       │   ├── db.rs      # PostgreSQL
│       │   └── message.rs # Protocol types
│       └── Cargo.toml
│
├── ConstructMessenger/     # 📱 iOS Swift приложение
│   ├── ViewModels/        # MVVM view models
│   ├── Views/             # SwiftUI views
│   ├── Security/
│   │   └── CryptoManager.swift  # Thin wrapper
│   ├── Networking/
│   │   └── WebSocketManager.swift
│   └── Models/            # Core Data models
│
├── libconstruct_core.a    # Скомпилированная Rust библиотека
└── README.md              # 📖 Этот файл
```

---

## 🧪 Тестирование

### Rust Core

```bash
cd packages/core
cargo test --all-features
```

### iOS App

```bash
# В Xcode: ⌘U (Run Tests)
```

### Сервер

```bash
cd packages/server
cargo test
```

---

## 🤝 Участие в разработке

Мы приветствуем contributions! Пожалуйста, ознакомьтесь с:

1. [ROADMAP.md](docs/ROADMAP.md) - План развития
2. [RUST_SWIFT_INTEGRATION.md](docs/RUST_SWIFT_INTEGRATION.md) - Технические детали
3. Создайте Issue для обсуждения новых функций
4. Отправьте Pull Request

### Приоритетные области

- 🔴 **Критично:** Исправление расшифровки сообщений
- 🟠 **Важно:** Unit/integration тесты
- 🟡 **Полезно:** UI/UX улучшения
- 🟢 **Будущее:** Post-quantum crypto implementation

---

## 📊 Текущий статус

**Версия:** v0.1.0 (Early Alpha)
**Дата:** 26 декабря 2025

### ✅ Готово
- [x] Rust криптографическое ядро (Double Ratchet + X3DH)
- [x] UniFFI интеграция с iOS
- [x] WebSocket сервер с PostgreSQL
- [x] Базовый UI (SwiftUI)
- [x] Core Data persistence

### 🚧 В работе
- [ ] Расшифровка сообщений (debugging)
- [ ] Unit тесты
- [ ] Push notifications
- [ ] File attachments

### 📅 Планируется
**Q2 2026:**
- [ ] Post-quantum hybrid cryptography (Kyber768 + Dilithium3)
- [ ] Android приложение
- [ ] Web PWA

**2027:**
- [ ] Group messaging (Sender Keys)
- [ ] Voice/Video calls (WebRTC)

**2028+:**
- [ ] **Федерация серверов** (Email 2.0 с E2E шифрованием)
- [ ] Децентрализованная архитектура (alice@server1.com ↔ bob@server2.com)
- [ ] DNS-based server discovery
- [ ] Sealed sender для metadata privacy

---

## 📄 Лицензия

MIT License - смотрите [LICENSE](LICENSE) для деталей

---

## 🙏 Благодарности

- **Signal Foundation** за Double Ratchet Protocol
- **Mozilla** за UniFFI
- **Rust Community** за отличные crypto библиотеки
- **NIST** за стандартизацию постквантовой криптографии

---

## 📧 Контакты

- **Автор:** Maxim Eliseyev
- **Email:** [указать email]
- **Issues:** [GitHub Issues](https://github.com/your-repo/construct-messenger/issues)

---

**Сделано с ❤️ и Rust 🦀**


# API Specification #component/server #status/done #type/reference
> **Version**: 3.0 (2026-01-24) **Protocol**: REST API

## 1. Введение

Цель этого API — внедрение **крипто-гибкости (crypto-agility)**. Это позволит клиентам поддерживать несколько криптографических алгоритмов одновременно и согласовывать наиболее безопасный из них. Это является ключевым шагом для поддержки постквантовых (PQ) гибридных схем в будущем.

**Основным протоколом взаимодействия является REST API.** WebSocket API считается устаревшим и не должен использоваться в новых реализациях.

## 2. Основные концепции

### 2.1. Идентификатор набора шифров (`SuiteID`)

`SuiteID` — это целое число (`u16`), которое уникально идентифицирует набор криптографических примитивов (KEM, подпись, AEAD, хэш).

**Начальная таблица `SuiteID`:**

| ID  | KEM/DH | Signature | AEAD           | Hash    | Примечание                  |
|-----|--------|-----------|----------------|---------|-----------------------------|
| 1   | X25519 | Ed25519   | AES-256-GCM    | SHA-512 | **Базовый классический набор** |
| 2   | TBD    | TBD       | TBD            | TBD     | *Зарезервировано для PQ-гибрида* |

### 2.2. Подписанный пакет ключей (`SignedKeyBundle`)

Это центральный объект для установления доверия. Вместо того чтобы доверять серверу в том, что он отдает правильные ключи, клиент доверяет только пакету, который криптографически подписан долгосрочным **ключом идентификации** (`masterIdentityKey`) другого пользователя.

- **Процесс создания (на клиенте):**
  1. Клиент генерирует все необходимые публичные ключи для каждого набора шифров, который он поддерживает.
  2. Он упаковывает их в структуру `BundleData`.
  3. Эта структура канонически сериализуется (например, в JSON без пробелов) и подписывается `masterIdentityKey`.
- **Процесс проверки (на клиенте):**
  1. Клиент запрашивает пакет ключей другого пользователя.
  2. **Перед использованием** он проверяет подпись пакета с помощью `masterIdentityKey`. Если подпись неверна, пакет отбрасывается.

### 2.3. CSRF Protection (Cross-Site Request Forgery)

Сервер реализует защиту от CSRF атак для всех state-changing HTTP запросов (POST, PUT, DELETE, PATCH). Используется гибридный подход для поддержки разных типов клиентов:

*   **Для Web-клиентов (браузеры):** Требуется CSRF токен в заголовке `X-CSRF-Token` и/или cookie `csrf_token`. Токен получается через `GET /api/csrf-token`. Используется паттерн "Double Submit Cookie".
*   **Для Mobile-клиентов (iOS/Android) и API-клиентов:** CSRF токен не требуется. Вместо этого, для state-changing запросов **необходимо** отправлять заголовок `X-Requested-With: XMLHttpRequest`. Этот заголовок не может быть добавлен в cross-origin запросах браузерами, что обеспечивает достаточную защиту для не-браузерных клиентов.

**Правила:**
- CSRF защита применяется только к state-changing методам (POST, PUT, DELETE, PATCH).
- GET, HEAD, OPTIONS запросы не требуют CSRF токена.

## 3. Основные структуры данных (JSON)

(Note: All keys are camelCase)

### 3.1. `UploadableKeyBundle`
Структура, которую клиент загружает на сервер для регистрации или ротации ключей.

```json
{
  "master_identity_key": "Base64<Bytes>",
  "bundle_data": "Base64<Serialized_BundleData>",
  "signature": "Base64<Bytes>"
}
```
- `masterIdentityKey`: Долгосрочный публичный ключ Ed25519, которым все подписано.
- `bundleData`: Сериализованная структура `BundleData`, закодированная в Base64.
- `signature`: Ed25519 подпись от `bundleData`.

### 3.2. `BundleData`
Структура, которая сериализуется и подписывается. Содержит криптографический материал.

```json
{
  "userId": "String",
  "timestamp": "ISO8601_String",
  "supportedSuites": [
    {
      "suiteId": 1,
      "identityKey": "Base64<Bytes>",
      "signedPrekey": "Base64<Bytes>",
      "signedPrekeySignature": "Base64<Bytes>",
      "oneTimePrekeys": ["Base64<Bytes>", ...]
    }
  ]
}
```
- `oneTimePrekeys`: Опциональный, но рекомендуемый список одноразовых ключей.

## 4. REST API Endpoints

### 4.1. Аутентификация

#### `POST /api/v1/auth/register`
Регистрирует нового пользователя.

- **Аутентификация:** Не требуется.
- **Request Body:**
  ```json
  {
    "username": "String",
    "password": "String",
    "key_bundle": {
      "master_identity_key": "Base64<Bytes>",
      "bundle_data": "Base64<Serialized_BundleData>",
      "signature": "Base64<Bytes>"
    }
  }
  ```
- **Success Response (200 OK):**
  ```json
  {
    "userId": "String",
    "accessToken": "String",
    "refreshToken": "String",
    "expiresAt": "Int64"
  }
  ```
- **Error Responses:** `400 Bad Request`, `409 Conflict` (если пользователь уже существует).

#### `POST /api/v1/auth/login`
Аутентифицирует пользователя и возвращает токены.

- **Аутентификация:** Не требуется.
- **Request Body:**
  ```json
  {
    "username": "String",
    "password": "String"
  }
  ```
- **Success Response (200 OK):**
  ```json
  {
    "userId": "String",
    "accessToken": "String",
    "refreshToken": "String",
    "expiresAt": "Int64"
  }
  ```
- **Error Responses:** `400 Bad Request`, `401 Unauthorized`.

#### `POST /api/v1/auth/logout`
Завершает текущую сессию пользователя.

- **Аутентификация:** Требуется (`Authorization: Bearer <token>`).
- **Request Body:**
  ```json
  {
    "all_devices": "Bool"
  }
  ```
- **Success Response (200 OK):** Пустое тело.
- **Error Responses:** `401 Unauthorized`.

#### `POST /api/v1/auth/delete`
Удаляет аккаунт пользователя.

- **Аутентификация:** Требуется (`Authorization: Bearer <token>`).
- **Request Body:**
  ```json
  {
    "password": "String"
  }
  ```
- **Success Response (200 OK):** Пустое тело.
- **Error Responses:** `401 Unauthorized`, `403 Forbidden`.


### 4.2. Сообщения

#### `POST /api/v1/messages`
Отправляет E2E-зашифрованное сообщение.

- **Аутентификация:** Требуется (`Authorization: Bearer <token>`).
- **Request Body:**
  ```json
  {
    "recipientId": "String",
    "suiteId": "UInt16",
    "ephemeralPublicKey": "Base64<Bytes>",
    "messageNumber": "UInt32",
    "previousChainLength": "UInt32",
    "ciphertext": "Base64<nonce || ciphertext_with_tag>"
  }
  ```
- **Success Response (200 OK):**
  ```json
  {
    "message_id": "String",
    "status": "String"
  }
  ```
- **Error Responses:** `400 Bad Request`, `401 Unauthorized`.

#### `GET /api/v1/messages`
Получает сообщения для аутентифицированного пользователя, используя long polling.

- **Аутентификация:** Требуется (`Authorization: Bearer <token>`).
- **Query Parameters:**
  - `since` (optional, string): ID последнего полученного сообщения.
  - `timeout` (optional, int): Таймаут в секундах (default: 30).
  - `limit` (optional, int): Макс. кол-во сообщений (default: 50).
- **Success Response (200 OK):**
  ```json
  {
    "messages": [
      {
        "id": "String",
        "from": "String",
        "to": "String",
        "ephemeral_public_key": "Base64<Bytes>",
        "message_number": "UInt32",
        "content": "Base64<nonce || ciphertext_with_tag>",
        "suiteId": "UInt16",
        "timestamp": "UInt64"
      }
    ],
    "next_since": "String",
    "has_more": "Bool"
  }
  ```
- **Error Responses:** `401 Unauthorized`.

### 4.3. Управление ключами

#### `GET /api/v1/users/{userId}/public-key`
Получает публичный пакет ключей для указанного пользователя.

- **Аутентификация:** Требуется (`Authorization: Bearer <token>`).
- **Path Parameter:** `{userId}` - UUID пользователя.
- **Success Response (200 OK):** Массив `[KeyBundleObject, username]`
  ```json
  [
    {
        "bundleData": "Base64<Serialized_BundleData>",
        "masterIdentityKey": "Base64<Bytes>",
        "signature": "Base64<Bytes>"
    },
    "username"
  ]
  ```
- **Error Responses:** `401 Unauthorized`, `404 Not Found`.

#### `POST /api/v1/keys/rotate`
Загружает (ротирует) пакет ключей для аутентифицированного пользователя.

- **Аутентификация:** Требуется (`Authorization: Bearer <token>`).
- **Request Body:**
  ```json
  {
    "key_bundle": {
      "master_identity_key": "Base64<Bytes>",
      "bundle_data": "Base64<Serialized_BundleData>",
      "signature": "Base64<Bytes>"
    }
  }
  ```
- **Success Response (200 OK):** Пустое тело.
- **Error Responses:** `400 Bad Request`, `401 Unauthorized`.

### 4.4. Медиа

#### `POST /api/v1/media/token`
Запрашивает токен для загрузки медиафайла.

- **Аутентификация:** Требуется (`Authorization: Bearer <token>`).
- **Request Body:** Пустое тело.
- **Success Response (200 OK):**
  ```json
  {
    "request_id": "String",
    "upload_token": "String",
    "upload_url": "String",
    "max_file_size": "Int",
    "expires_at": "String"
  }
  ```
- **Error Responses:** `401 Unauthorized`.

## 5. Обмен данными профиля (Profile Data Sharing)

Данные профиля (`displayName` и `avatar`) **НЕ** хранятся на сервере. Обмен происходит напрямую между пользователями через E2E-зашифрованные сообщения.

### 5.1. Формат
Данные профиля отправляются как обычное E2E-зашифрованное сообщение, но внутри расшифрованного содержимого находится специальный JSON:

```json
{
  "type": "profile",
  "displayName": "String",
  "avatarData": "Base64_String (optional, legacy)",
  "avatarMediaId": "String (optional)",
  "avatarMediaUrl": "String (optional)",
  "avatarMediaKey": "String (optional)",
  "timestamp": "Int64"
}
```

### 5.2. Процесс обмена
1.  **Инициация:** Пользователь A решает поделиться своим профилем с пользователем B.
2.  **Шифрование:** Клиент пользователя A создает JSON профиля, шифрует его в рамках E2E сессии с пользователем B.
3.  **Отправка:** Зашифрованный JSON отправляется как обычное сообщение через `POST /api/v1/messages`.
4.  **Получение и хранение:** Клиент пользователя B, получив и расшифровав сообщение, парсит JSON и сохраняет данные профиля пользователя A локально.

## 6. X3DH Prologue для подписей (Key Substitution Attack Prevention)

### 6.1. Назначение

Для защиты от **key substitution attacks** (атак подмены ключей между разными криптографическими наборами), подпись `signed_prekey` включает **prologue** по аналогии с Noise Protocol. Это предотвращает возможность злоумышленнику подменить ключи из одного suite на ключи из другого suite.

### 6.2. Формат Prologue

Prologue имеет фиксированный формат:
`Prologue = "X3DH" (4 bytes ASCII) || suite_id (2 bytes, little-endian)`

**Общий размер:** 6 байт

### 6.3. Процесс подписания (на клиенте)

1. Клиент генерирует `signed_prekey_public` для выбранного suite
2. Создаёт prologue: `"X3DH" || suite_id` (6 байт)
3. Конкатенирует: `message_to_sign = prologue || signed_prekey_public`
4. Подписывает: `signature = Ed25519_sign(signing_key, message_to_sign)`
5. Включает `signature` и `suite_id` в `X3DHRegistrationBundle`
6. Отправляет bundle на сервер

### 6.4. Процесс проверки (на клиенте)

1. Клиент получает `X3DHPublicKeyBundle` с полем `suite_id`
2. Строит prologue из `suite_id`: `"X3DH" || suite_id`
3. Конкатенирует: `message_to_verify = prologue || signed_prekey_public`
4. Проверяет подпись: `Ed25519_verify(verifying_key, message_to_verify, signature)`
5. **Backward compatibility:** Если новый формат не проходит, пробует старый (без prologue) для совместимости со старыми клиентами

### 6.5. Важно для сервера

**⚠️ Сервер НЕ должен знать о prologue!**

Сервер работает только с **непрозрачными данными** (opaque blobs). Принцип: Zero-trust архитектура - сервер не доверяет криптографии, клиент проверяет всё сам.

- ✅ **Хранить `suite_id`** вместе с bundle.
- ✅ **Валидировать** `suite_id`, наличие полей, и их размеры.
- ❌ **НЕ валидировать криптографию** (подписи).

---

## 7. Domain Separation для Key Agreement (Legacy)

> **Примечание:** Это устаревшая концепция. Текущая реализация использует prologue для подписей (см. раздел 6).

Это **обязанность клиента**, сервер не участвует в этом процессе.

---

## Appendix A: Legacy WebSocket API (Deprecated)

**ВНИМАНИЕ:** Этот раздел описывает устаревший API, основанный на WebSocket. Он сохранен для обратной совместимости, но **не должен использоваться** для новых реализаций. Все новые клиенты должны использовать **REST API**, описанный в разделе 4.

### A.1. Формат сообщений

Все сообщения передаются в формате **MessagePack** с internally-tagged enum формате:

```json
{
  "type": "messageType",
  "payload": { /* данные сообщения */ }
}
```

### A.2. Клиентские сообщения (Client → Server)

#### Register
- **`{"type": "register", "payload": {"username", "password", "publicKey"}}`**

#### Login
- **`{"type": "login", "payload": {"username", "password"}}`**

#### Connect
- **`{"type": "connect", "payload": {"sessionToken"}}`**

#### GetPublicKey
- **`{"type": "getPublicKey", "payload": {"userId"}}`**

#### SendMessage
- **`{"type": "sendMessage", "payload": {"id", "from", "to", "ephemeralPublicKey", "messageNumber", "content", "timestamp"}}`**

### A.3. Серверные сообщения (Server → Client)

#### RegisterSuccess
- **`{"type": "registerSuccess", "payload": {"userId", "username", "sessionToken", "expires"}}`**

#### LoginSuccess
- **`{"type": "loginSuccess", "payload": {"userId", "username", "sessionToken", "expires"}}`**

#### ConnectSuccess
- **`{"type": "connectSuccess", "payload": {"userId", "username"}}`**

#### Message
- **`{"type": "message", "payload": {"id", "from", "to", "ephemeralPublicKey", "messageNumber", "content", "timestamp"}}`**

#### Error
- **`{"type": "error", "payload": {"code", "message"}}`**

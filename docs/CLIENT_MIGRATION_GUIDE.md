# Руководство по миграции клиента

**Дата обновления:** 2026-01-15  
**Версия сервера:** После Phase 2.5.4 (REST API Migration завершена)

Этот документ описывает изменения в API сервера, которые требуют обновления клиентского приложения.

---

## ✅ Миграция на REST API (Phase 2.5) - РЕАЛИЗОВАНО

**Статус:** ✅ Реализовано  
**Приоритет:** 🔴 КРИТИЧЕСКИЙ (для масштабируемости)

**REST API теперь является основным протоколом** для обмена сообщениями. WebSocket продолжает работать для обратной совместимости, но рекомендуется мигрировать на REST API.

**Новая архитектура:**
- **REST API** - основной протокол (stateless, легко масштабировать)
- **Long polling** - для получения сообщений (как WhatsApp, Signal)
- **WebSocket опционально** - только для real-time уведомлений (отложено)

**Реализованные endpoints:**
- ✅ `POST /api/v1/auth/register` - Регистрация через REST API
- ✅ `POST /api/v1/auth/login` - Вход через REST API
- ✅ `POST /api/v1/messages` - Отправка сообщений (мигрировано из `/messages/send`)
- ✅ `GET /api/v1/messages?since=<id>` - Получение сообщений через long polling
- ✅ `GET /api/v1/users/:id/public-key` - Получение публичного ключа (мигрировано из `/keys/:user_id`)
- ✅ `POST /api/v1/keys/upload` - Загрузка ключей (мигрировано из `/keys/upload`)

**Старые endpoints (legacy):**
- `POST /messages/send` - продолжает работать (обратная совместимость)
- `GET /keys/:user_id` - продолжает работать (обратная совместимость)
- `POST /keys/upload` - продолжает работать (обратная совместимость)

**Рекомендация:** Мигрируйте на новые `/api/v1/` endpoints. Старые endpoints будут поддерживаться для обратной совместимости, но рекомендуется перейти на новые.

**Детальный план:** См. `REST_API_MIGRATION_PLAN.md`

---

## 🏗️ Планируемая декомпозиция на микросервисы (Phase 2.6)

**Статус:** Планирование  
**Приоритет:** 🟡 ВАЖНО (для масштабируемости)

В будущем планируется декомпозиция сервера на микросервисы для лучшей масштабируемости и поддерживаемости.

**Целевая архитектура:**
- **API Gateway** (Port 80) - единая точка входа, rate limiting, authentication
- **Auth Service** (Port 8001) - registration, login, session management
- **Messaging Service** (Port 8002) - send/get messages, delivery
- **User Service** (Port 8003) - user profiles, public keys
- **Notification Service** (Port 8004) - push notifications (APNs/FCM)

**Преимущества:**
- Независимое масштабирование каждого сервиса
- Изоляция ошибок (падение одного сервиса не влияет на другие)
- Независимое развертывание и обновление
- Легче поддерживать и тестировать

**Для клиентов:**
- API endpoints останутся теми же (через API Gateway)
- Прозрачная миграция - клиенты не заметят изменений
- Возможны временные задержки во время миграции

**Детальный план:** См. `MICROSERVICES_ARCHITECTURE_PLAN.md`

---

---

## 🔴 Критичные изменения (требуют немедленного обновления)

### 0. Request Signing для критичных операций (опционально, но рекомендуется)

**Что изменилось:**
- Для критичных операций (`POST /keys/upload`) рекомендуется подписывать запросы Ed25519 ключом
- Подпись предотвращает tampering запросов и обеспечивает дополнительную аутентификацию
- Используется `master_identity_key` клиента (Ed25519) для подписи
- По умолчанию опционально, но рекомендуется для production (включается через `REQUEST_SIGNING_REQUIRED=true`)

**Что нужно сделать:**

1. **Реализовать функцию подписи запросов:**

   **TypeScript/JavaScript (Web):**
   ```typescript
   import { SigningKey } from '@noble/ed25519';
   
   interface RequestSignature {
     signature: string;    // Base64-encoded Ed25519 signature (64 bytes)
     publicKey: string;    // Base64-encoded Ed25519 public key (32 bytes)
     timestamp: number;    // Unix epoch seconds
   }
   
   async function signRequest(
     method: string,
     path: string,
     body: string,
     signingKey: SigningKey
   ): Promise<RequestSignature> {
     const timestamp = Math.floor(Date.now() / 1000);
     
     // Compute SHA256 hash of body (hex-encoded)
     const bodyHashBuffer = await crypto.subtle.digest(
       'SHA-256',
       new TextEncoder().encode(body)
     );
     const bodyHashHex = Array.from(new Uint8Array(bodyHashBuffer))
       .map(b => b.toString(16).padStart(2, '0'))
       .join('');
     
     // Create canonical request format: method:path:timestamp:body_hash
     const canonical = `${method}:${path}:${timestamp}:${bodyHashHex}`;
     const canonicalBytes = new TextEncoder().encode(canonical);
     
     // Sign with Ed25519
     const signature = await signingKey.sign(canonicalBytes);
     
     // Get public key (master_identity_key)
     const publicKey = signingKey.getPublicKey();
     
     return {
       signature: Buffer.from(signature).toString('base64'),
       publicKey: Buffer.from(publicKey).toString('base64'),
       timestamp
     };
   }
   ```

   **Swift (iOS):**
   ```swift
   import CryptoKit
   
   struct RequestSignature: Codable {
       let signature: String    // Base64-encoded Ed25519 signature
       let publicKey: String    // Base64-encoded Ed25519 public key
       let timestamp: Int64     // Unix epoch seconds
   }
   
   func signRequest(
       method: String,
       path: String,
       body: String,
       signingKey: Curve25519.Signing.PrivateKey
   ) throws -> RequestSignature {
       let timestamp = Int64(Date().timeIntervalSince1970)
       
       // Compute SHA256 hash of body
       let bodyData = body.data(using: .utf8)!
       let bodyHash = SHA256.hash(data: bodyData)
       let bodyHashHex = bodyHash.map { String(format: "%02x", $0) }.joined()
       
       // Create canonical request format
       let canonical = "\(method):\(path):\(timestamp):\(bodyHashHex)"
       let canonicalData = canonical.data(using: .utf8)!
       
       // Sign with Ed25519
       let signature = try signingKey.signature(for: canonicalData)
       
       // Get public key
       let publicKey = signingKey.publicKey
       
       return RequestSignature(
           signature: signature.rawRepresentation.base64EncodedString(),
           publicKey: publicKey.rawRepresentation.base64EncodedString(),
           timestamp: timestamp
       )
   }
   ```

   **Kotlin (Android):**
   ```kotlin
   import org.bouncycastle.crypto.signers.Ed25519Signer
   import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
   import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
   import java.security.MessageDigest
   import java.util.Base64
   
   data class RequestSignature(
       val signature: String,    // Base64-encoded Ed25519 signature
       val publicKey: String,    // Base64-encoded Ed25519 public key
       val timestamp: Long       // Unix epoch seconds
   )
   
   fun signRequest(
       method: String,
       path: String,
       body: String,
       signingKey: Ed25519PrivateKeyParameters
   ): RequestSignature {
       val timestamp = System.currentTimeMillis() / 1000
       
       // Compute SHA256 hash of body
       val bodyBytes = body.toByteArray(Charsets.UTF_8)
       val bodyHash = MessageDigest.getInstance("SHA-256").digest(bodyBytes)
       val bodyHashHex = bodyHash.joinToString("") { "%02x".format(it) }
       
       // Create canonical request format
       val canonical = "$method:$path:$timestamp:$bodyHashHex"
       val canonicalBytes = canonical.toByteArray(Charsets.UTF_8)
       
       // Sign with Ed25519
       val signer = Ed25519Signer()
       signer.init(true, signingKey)
       signer.update(canonicalBytes, 0, canonicalBytes.size)
       val signature = signer.generateSignature()
       
       // Get public key
       val publicKey = signingKey.generatePublicKey()
       
       return RequestSignature(
           signature = Base64.getEncoder().encodeToString(signature),
           publicKey = Base64.getEncoder().encodeToString(publicKey.encoded),
           timestamp = timestamp
       )
   }
   ```

2. **Включать подпись в заголовок запроса:**

   **TypeScript/JavaScript:**
   ```typescript
   async function uploadKeys(
     bundle: UploadableKeyBundle,
     signingKey: SigningKey,
     accessToken: string,
     csrfToken: string
   ) {
     // ⚠️ ВАЖНО: Сериализация должна быть детерминированной
     // Используйте JSON.stringify без пробелов и с одинаковым порядком полей
     // Или используйте библиотеку для детерминированной сериализации
     const body = JSON.stringify(bundle, null, 0); // null, 0 = без форматирования
     
     // Sign the request BEFORE making the HTTP call
     const signature = await signRequest('POST', '/keys/upload', body, signingKey);
     
     // Make request with signature header
     const response = await fetch('/keys/upload', {
       method: 'POST',
       headers: {
         'Authorization': `Bearer ${accessToken}`,
         'X-CSRF-Token': csrfToken,
         'X-Request-Signature': JSON.stringify(signature), // JSON с camelCase
         'Content-Type': 'application/json'
       },
       body: body // Используем тот же body, который был подписан
     });
     
     if (!response.ok) {
       const error = await response.json();
       if (error.error?.includes('Request signature')) {
         throw new Error('Request signature verification failed. Please check your master_identity_key.');
       }
       throw new Error(error.error || 'Failed to upload keys');
     }
     
     return await response.json();
   }
   ```
   
   **⚠️ Критически важно:**
   - Body, который подписывается, должен **точно совпадать** с body, отправляемым в запросе
   - Используйте детерминированную JSON сериализацию (без пробелов, одинаковый порядок полей)
   - Не изменяйте body после подписания
   - Если используете библиотеки для сериализации, убедитесь, что они детерминированы

**Endpoints, требующие подписи:**
- `POST /keys/upload` - требует request signature если `REQUEST_SIGNING_REQUIRED=true`

**Header Format:**
```
X-Request-Signature: {"signature":"base64...","publicKey":"base64...","timestamp":1234567890}
```

**Canonical Format для подписи:**
```
method:path:timestamp:body_hash
```
Где:
- `method` - HTTP метод (например, "POST")
- `path` - путь запроса (например, "/keys/upload")
- `timestamp` - Unix timestamp в секундах
- `body_hash` - SHA256 хэш тела запроса в hex формате (64 символа)

**Пример canonical строки:**
```
POST:/keys/upload:1705324800:a1b2c3d4e5f6...
```

**Важно:**
- ✅ `publicKey` в подписи **должен совпадать** с `master_identity_key` в bundle
- ✅ `timestamp` должен быть актуальным (в пределах 5 минут от текущего времени сервера)
- ✅ Body должен быть сериализован в **детерминированный JSON** (без пробелов, одинаковый порядок полей)
- ✅ Подпись создается над canonical форматом: `method:path:timestamp:body_hash`
- ✅ Body, который подписывается, должен **точно совпадать** с body, отправляемым в HTTP запросе
- ⚠️ Если сервер требует подпись (`REQUEST_SIGNING_REQUIRED=true`), запросы без подписи будут отклонены с ошибкой 400
- ⚠️ Если подпись неверна, сервер вернет ошибку 400 с сообщением "Request signature verification failed"

**Типичные ошибки:**
- ❌ Разные body для подписи и отправки (например, добавили/удалили поля после подписания)
- ❌ Разный формат JSON (с пробелами vs без пробелов)
- ❌ Несовпадение `publicKey` в подписи с `master_identity_key` в bundle
- ❌ Устаревший timestamp (более 5 минут)

**Обработка ошибок:**
```typescript
try {
  await uploadKeys(bundle, signingKey, accessToken, csrfToken);
} catch (error) {
  if (error.message.includes('Request signature')) {
    // Подпись неверна или отсутствует
    console.error('Request signing failed:', error);
    // Показать пользователю понятное сообщение
  }
}
```

---

## 🔴 Критичные изменения (требуют немедленного обновления)

### 1. Token Management: Access Tokens теперь короткоживущие

**Что изменилось:**
- Access tokens теперь имеют TTL **1 час** (вместо 30 дней)
- Добавлены **refresh tokens** с TTL 30 дней
- Требуется периодическое обновление access token через refresh token

**Что нужно сделать:**

1. **Хранить refresh token** наряду с access token
   ```typescript
   interface AuthTokens {
     accessToken: string;
     refreshToken: string;
     expiresAt: number; // Unix timestamp
   }
   ```

2. **Реализовать автоматическое обновление токена** перед истечением
   ```typescript
   // Проверять время до истечения (например, за 5 минут)
   if (expiresAt - Date.now() < 5 * 60 * 1000) {
     await refreshAccessToken();
   }
   ```

3. **Добавить endpoint для обновления токена**
   ```typescript
   async function refreshAccessToken(): Promise<AuthTokens> {
     const response = await fetch('/auth/refresh', {
       method: 'POST',
       headers: { 'Content-Type': 'application/json' },
       body: JSON.stringify({
         refreshToken: storedRefreshToken
       })
     });
     
     const data = await response.json();
     // Сохранить новые токены
     return {
       accessToken: data.accessToken,
       refreshToken: data.refreshToken,
       expiresAt: data.expiresAt
     };
   }
   ```

4. **Обрабатывать ошибки refresh token**
   - Если refresh token истек или отозван → требовать повторный логин
   - Если refresh token невалиден → требовать повторный логин

**Endpoint:**
- `POST /auth/refresh` - обновление access token

**Request:**
```json
{
  "refreshToken": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9..."
}
```

**Response:**
```json
{
  "accessToken": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...",
  "refreshToken": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expiresAt": 1705320000
}
```

---

### 2. CSRF Protection: Требуется CSRF token для state-changing операций

**Что изменилось:**
- Для POST/PUT/DELETE запросов требуется CSRF защита
- Для браузерных клиентов: CSRF token в заголовке или cookie
- Для мобильных/API клиентов: заголовок `X-Requested-With`

**Что нужно сделать:**

1. **Для браузерных клиентов (Web):**
   ```typescript
   // 1. Получить CSRF token при загрузке приложения
   async function getCsrfToken(): Promise<string> {
     const response = await fetch('/api/csrf-token', {
       credentials: 'include' // Важно: включить cookies
     });
     const data = await response.json();
     return data.csrfToken;
   }
   
   // 2. Включать CSRF token в каждый POST/PUT/DELETE запрос
   async function sendMessage(message: EncryptedMessage) {
     const csrfToken = await getCsrfToken();
     await fetch('/messages/send', {
       method: 'POST',
       headers: {
         'Authorization': `Bearer ${accessToken}`,
         'X-CSRF-Token': csrfToken, // Или из cookie
         'Content-Type': 'application/json'
       },
       credentials: 'include', // Для cookie-based CSRF
       body: JSON.stringify(message)
     });
   }
   ```

2. **Для мобильных/API клиентов:**
   ```typescript
   // Просто добавьте заголовок X-Requested-With
   await fetch('/messages/send', {
     method: 'POST',
     headers: {
       'Authorization': `Bearer ${accessToken}`,
       'X-Requested-With': 'XMLHttpRequest', // Защита от CSRF
       'Content-Type': 'application/json'
     },
     body: JSON.stringify(message)
   });
   ```

**Endpoints:**
- `GET /api/csrf-token` - получение CSRF token (для браузерных клиентов)

**Response:**
```json
{
  "csrfToken": "abc123def456..."
}
```

---

### 3. Replay Protection: Требуются nonce и timestamp для критичных операций

**Что изменилось:**
- Для `/keys/upload` и `/messages/send` рекомендуется (опционально) передавать `nonce` и `timestamp`
- Timestamp должен быть в пределах 5 минут от текущего времени
- Nonce предотвращает replay атаки

**Что нужно сделать:**

1. **Генерировать nonce для каждого запроса**
   ```typescript
   import { randomBytes } from 'crypto';
   
   function generateNonce(): string {
     return randomBytes(16).toString('base64');
   }
   ```

2. **Добавить nonce и timestamp в запросы**
   ```typescript
   // Для загрузки ключей
   interface UploadKeyBundleRequest {
     masterIdentityKey: string;
     bundleData: string;
     signature: string;
     nonce?: string;        // Рекомендуется
     timestamp?: number;    // Рекомендуется (Unix epoch seconds)
   }
   
   // Для отправки сообщений
   interface EncryptedMessageV3 {
     recipientId: string;
     suiteId: number;
     ciphertext: string;
     nonce?: string;        // Рекомендуется
     timestamp?: number;    // Рекомендуется (Unix epoch seconds)
   }
   ```

3. **Пример использования:**
   ```typescript
   async function uploadKeys(bundle: KeyBundle) {
     const nonce = generateNonce();
     const timestamp = Math.floor(Date.now() / 1000);
     
     await fetch('/keys/upload', {
       method: 'POST',
       headers: {
         'Authorization': `Bearer ${accessToken}`,
         'X-CSRF-Token': csrfToken,
         'Content-Type': 'application/json'
       },
       body: JSON.stringify({
         ...bundle,
         nonce,
         timestamp
       })
     });
   }
   ```

**Важно:**
- Если nonce/timestamp не переданы, сервер все равно работает (backward compatible)
- Но для лучшей безопасности рекомендуется их использовать
- Timestamp должен быть актуальным (в пределах 5 минут)

---

## 🟡 Важные изменения (рекомендуется обновить)

### 4. Logout: Новый endpoint для soft logout

**Что изменилось:**
- Добавлен endpoint `POST /auth/logout` для инвалидации токенов
- Поддерживается logout со всех устройств

**Что нужно сделать:**

```typescript
async function logout(allDevices: boolean = false) {
  await fetch('/auth/logout', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      allDevices: allDevices
    })
  });
  
  // Удалить токены из локального хранилища
  localStorage.removeItem('accessToken');
  localStorage.removeItem('refreshToken');
}
```

**Endpoint:**
- `POST /auth/logout` - soft logout

**Request:**
```json
{
  "allDevices": false  // true = logout со всех устройств
}
```

---

### 5. Rate Limiting: Улучшенная защита от злоупотреблений

**Что изменилось:**
- Добавлен IP-based rate limiting
- Комбинированный rate limiting (user_id + IP)
- Более строгие лимиты для авторизованных операций

**Что нужно сделать:**

1. **Обрабатывать ошибки rate limiting**
   ```typescript
   try {
     await sendMessage(message);
   } catch (error) {
     if (error.code === 'RATE_LIMIT_EXCEEDED') {
       // Показать пользователю сообщение
       showError('Слишком много запросов. Подождите немного.');
       // Реализовать exponential backoff
       await delay(calculateBackoff(attemptCount));
     }
   }
   ```

2. **Реализовать exponential backoff** при rate limiting
   ```typescript
   function calculateBackoff(attempt: number): number {
     return Math.min(1000 * Math.pow(2, attempt), 30000); // Max 30 seconds
   }
   ```

**HTTP Status Codes:**
- `429 Too Many Requests` - rate limit exceeded
- `403 Forbidden` - CSRF protection failed

---

## 🟢 Опциональные улучшения

### 6. Улучшенная обработка ошибок

**Новые коды ошибок:**
- `TOKEN_REVOKED` - токен был отозван (logout)
- `RATE_LIMIT_EXCEEDED` - превышен лимит запросов
- `CSRF_TOKEN_INVALID` - невалидный CSRF token
- `REPLAY_DETECTED` - обнаружена replay атака

**Рекомендуется:**
```typescript
interface ApiError {
  error: string;
  code: string;
}

async function handleApiError(response: Response) {
  if (response.status === 401) {
    const error: ApiError = await response.json();
    if (error.code === 'TOKEN_REVOKED') {
      // Требовать повторный логин
      redirectToLogin();
    } else if (error.code === 'TOKEN_EXPIRED') {
      // Попытаться обновить токен
      await refreshAccessToken();
    }
  } else if (response.status === 429) {
    // Rate limiting
    showRateLimitError();
  } else if (response.status === 403 && error.code === 'CSRF_TOKEN_INVALID') {
    // Обновить CSRF token и повторить запрос
    await refreshCsrfToken();
  }
}
```

---

## 📋 Чеклист для разработчиков клиента

### Обязательные изменения:
- [ ] Реализовать хранение refresh token
- [ ] Реализовать автоматическое обновление access token
- [ ] Добавить endpoint `/auth/refresh`
- [ ] Добавить CSRF protection для браузерных клиентов
- [ ] Добавить заголовок `X-Requested-With` для мобильных клиентов
- [ ] Обработать новые коды ошибок (`TOKEN_REVOKED`, `RATE_LIMIT_EXCEEDED`)

### Рекомендуемые изменения:
- [ ] Добавить nonce и timestamp в критичные запросы (`/keys/upload`, `/messages/send`)
- [ ] Реализовать Request Signing для критичных операций (если `REQUEST_SIGNING_REQUIRED=true`)
  - [ ] Подпись запросов Ed25519 для `POST /keys/upload`
  - [ ] Добавить заголовок `X-Request-Signature`
  - [ ] Обработать ошибки request signing

### Критичные изменения (Phase 2.5 - REST API Migration):
- [ ] **Миграция на REST API endpoints:**
  - [ ] `POST /api/v1/auth/register` - Регистрация через REST (вместо WebSocket)
  - [ ] `POST /api/v1/auth/login` - Вход через REST (вместо WebSocket)
  - [ ] `POST /api/v1/messages` - Отправка сообщений (вместо `/messages/send`)
  - [ ] `GET /api/v1/messages?since=<id>` - Long polling для получения сообщений
  - [ ] `GET /api/v1/users/:id/public-key` - Получение ключей (вместо `/keys/:user_id`)
  - [ ] `POST /api/v1/keys/upload` - Загрузка ключей (вместо `/keys/upload`)
- [ ] **Реализовать Long Polling для получения сообщений:**
  - [ ] Периодически вызывать `GET /api/v1/messages?timeout=30`
  - [ ] Обрабатывать параметры `since`, `timeout`, `limit`
  - [ ] Использовать `next_since` для следующего запроса
  - [ ] Обрабатывать пустые ответы (timeout)
- [ ] **Уведомления:**
  - [ ] Использовать APNs/FCM для системных push-уведомлений (когда приложение закрыто)
  - [ ] WebSocket опционально для real-time уведомлений (когда приложение открыто)
  - [ ] См. `NOTIFICATIONS_ARCHITECTURE.md` для деталей
- [ ] **Важно:** Поиск пользователей (`GET /api/v1/users/search`) НЕ реализован по соображениям приватности
  - Пользователи добавляются только через ссылки или QR-коды

### Опциональные улучшения:
- [ ] Кэширование CSRF token
- [ ] Автоматический retry при временных ошибках
- [ ] Мониторинг времени жизни токенов

---

## 🔄 Порядок миграции

1. **Фаза 1: Token Management (критично)**
   - Реализовать refresh token механизм
   - Обновить логику аутентификации
   - Протестировать обновление токенов

2. **Фаза 2: CSRF Protection**
   - Добавить получение CSRF token
   - Обновить все POST/PUT/DELETE запросы
   - Протестировать в браузере и мобильном приложении

3. **Фаза 3: Replay Protection (опционально)**
   - Добавить nonce генерацию
   - Добавить timestamp в запросы
   - Протестировать критичные операции

4. **Фаза 4: Улучшения**
   - Добавить logout endpoint
   - Улучшить обработку ошибок
   - Добавить мониторинг

---

## 📝 Примеры кода

### Полный пример аутентификации с refresh token:

```typescript
class AuthManager {
  private accessToken: string | null = null;
  private refreshToken: string | null = null;
  private expiresAt: number = 0;
  private refreshPromise: Promise<void> | null = null;

  async login(username: string, password: string): Promise<void> {
    // Ваш существующий код логина
    const response = await fetch('/auth/login', { ... });
    const data = await response.json();
    
    // Сохранить оба токена
    this.accessToken = data.accessToken;
    this.refreshToken = data.refreshToken;
    this.expiresAt = data.expiresAt;
    
    // Сохранить в localStorage
    localStorage.setItem('accessToken', this.accessToken);
    localStorage.setItem('refreshToken', this.refreshToken);
    localStorage.setItem('expiresAt', this.expiresAt.toString());
  }

  async getAccessToken(): Promise<string> {
    // Проверить, нужно ли обновить токен
    if (!this.accessToken || this.isTokenExpiringSoon()) {
      await this.refreshTokenIfNeeded();
    }
    return this.accessToken!;
  }

  private isTokenExpiringSoon(): boolean {
    const fiveMinutes = 5 * 60 * 1000;
    return this.expiresAt - Date.now() < fiveMinutes;
  }

  private async refreshTokenIfNeeded(): Promise<void> {
    // Предотвратить множественные одновременные refresh
    if (this.refreshPromise) {
      return this.refreshPromise;
    }

    this.refreshPromise = this.doRefreshToken();
    try {
      await this.refreshPromise;
    } finally {
      this.refreshPromise = null;
    }
  }

  private async doRefreshToken(): Promise<void> {
    if (!this.refreshToken) {
      throw new Error('No refresh token available');
    }

    try {
      const response = await fetch('/auth/refresh', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refreshToken: this.refreshToken })
      });

      if (!response.ok) {
        // Refresh token истек или отозван
        this.logout();
        throw new Error('Refresh token expired');
      }

      const data = await response.json();
      this.accessToken = data.accessToken;
      this.refreshToken = data.refreshToken;
      this.expiresAt = data.expiresAt;

      // Обновить в localStorage
      localStorage.setItem('accessToken', this.accessToken);
      localStorage.setItem('refreshToken', this.refreshToken);
      localStorage.setItem('expiresAt', this.expiresAt.toString());
    } catch (error) {
      this.logout();
      throw error;
    }
  }

  async logout(): Promise<void> {
    if (this.accessToken) {
      try {
        await fetch('/auth/logout', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${this.accessToken}`,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({ allDevices: false })
        });
      } catch (error) {
        // Игнорировать ошибки при logout
      }
    }

    this.accessToken = null;
    this.refreshToken = null;
    this.expiresAt = 0;
    localStorage.removeItem('accessToken');
    localStorage.removeItem('refreshToken');
    localStorage.removeItem('expiresAt');
  }
}
```

### Пример запроса с CSRF protection:

```typescript
class ApiClient {
  private csrfToken: string | null = null;
  private authManager: AuthManager;

  async getCsrfToken(): Promise<string> {
    if (!this.csrfToken) {
      const response = await fetch('/api/csrf-token', {
        credentials: 'include'
      });
      const data = await response.json();
      this.csrfToken = data.csrfToken;
    }
    return this.csrfToken;
  }

  async sendMessage(message: EncryptedMessage): Promise<void> {
    const accessToken = await this.authManager.getAccessToken();
    const csrfToken = await this.getCsrfToken();
    const nonce = this.generateNonce();
    const timestamp = Math.floor(Date.now() / 1000);

    const response = await fetch('/messages/send', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'X-CSRF-Token': csrfToken,
        'Content-Type': 'application/json',
        'X-Requested-With': 'XMLHttpRequest' // Для дополнительной защиты
      },
      credentials: 'include',
      body: JSON.stringify({
        ...message,
        nonce,
        timestamp
      })
    });

    if (response.status === 403) {
      // CSRF token истек, обновить
      this.csrfToken = null;
      return this.sendMessage(message); // Retry
    }

    if (!response.ok) {
      throw new Error(`API error: ${response.status}`);
    }
  }

  private generateNonce(): string {
    return crypto.getRandomValues(new Uint8Array(16))
      .reduce((str, byte) => str + byte.toString(16).padStart(2, '0'), '');
  }
}
```

---

## 🆕 Новые REST API Endpoints (Phase 2.5)

### 1. POST /api/v1/auth/register

**Назначение:** Регистрация нового пользователя через REST API

**Request:**
```json
{
  "username": "string",
  "password": "string",
  "key_bundle": {
    "master_identity_key": "base64",
    "bundle_data": "base64",
    "signature": "base64",
    "nonce": "string",
    "timestamp": 1234567890
  }
}
```

**Response:**
```json
{
  "user_id": "uuid",
  "access_token": "jwt",
  "refresh_token": "jwt",
  "expires_at": 1234567890
}
```

**Пример использования:**
```typescript
async function register(username: string, password: string, keyBundle: KeyBundle) {
  const response = await fetch('/api/v1/auth/register', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    },
    body: JSON.stringify({
      username,
      password,
      key_bundle: keyBundle
    })
  });
  
  if (!response.ok) {
    throw new Error('Registration failed');
  }
  
  const data = await response.json();
  // Сохранить токены
  return data;
}
```

**Безопасность:**
- Rate limiting: 5 запросов в час на IP
- Password validation: минимум 8 символов
- Replay protection для key bundle

---

### 2. POST /api/v1/auth/login

**Назначение:** Вход в систему через REST API

**Request:**
```json
{
  "username": "string",
  "password": "string"
}
```

**Response:**
```json
{
  "user_id": "uuid",
  "access_token": "jwt",
  "refresh_token": "jwt",
  "expires_at": 1234567890
}
```

**Пример использования:**
```typescript
async function login(username: string, password: string) {
  const response = await fetch('/api/v1/auth/login', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    },
    body: JSON.stringify({ username, password })
  });
  
  if (!response.ok) {
    throw new Error('Login failed');
  }
  
  const data = await response.json();
  // Сохранить токены
  return data;
}
```

**Безопасность:**
- Rate limiting для защиты от brute force
- Audit logging всех попыток входа

---

### 3. POST /api/v1/messages

**Назначение:** Отправка сообщения через REST API (мигрировано из `/messages/send`)

**Request:**
```json
{
  "recipient_id": "uuid",
  "suite_id": 1,
  "ciphertext": "base64",
  "nonce": "string",
  "timestamp": 1234567890
}
```

**Response:**
```json
{
  "message_id": "uuid",
  "status": "queued|delivered"
}
```

**Пример использования:**
```typescript
async function sendMessage(
  recipientId: string,
  ciphertext: string,
  accessToken: string
) {
  const response = await fetch('/api/v1/messages', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    },
    body: JSON.stringify({
      recipient_id: recipientId,
      suite_id: 1,
      ciphertext,
      nonce: generateNonce(),
      timestamp: Math.floor(Date.now() / 1000)
    })
  });
  
  if (!response.ok) {
    throw new Error('Failed to send message');
  }
  
  return await response.json();
}
```

---

### 4. GET /api/v1/messages?since=<id>

**Назначение:** Получение новых сообщений через long polling

**Параметры:**
- `since` (optional, string): Message ID для получения сообщений после этого ID
- `timeout` (optional, int): Timeout для long polling в секундах (default: 30, max: 60)
- `limit` (optional, int): Максимальное количество сообщений (default: 50, max: 100)

**Response:**
```json
{
  "messages": [
    {
      "id": "uuid",
      "sender_id": "uuid",
      "recipient_id": "uuid",
      "ciphertext": "base64",
      "timestamp": 1234567890,
      "suite_id": 1,
      "nonce": "base64",
      "delivery_status": "delivered"
    }
  ],
  "next_since": "uuid",
  "has_more": false
}
```

**Поведение:**
1. Если есть новые сообщения - возвращает их сразу
2. Если нет новых сообщений - ждет до `timeout` секунд (long polling)
3. Если за время ожидания пришли сообщения - возвращает их
4. Если timeout истек - возвращает пустой массив

**Пример использования (Long Polling):**
```typescript
class MessagePoller {
  private lastMessageId: string | null = null;
  private polling = false;

  async startPolling(accessToken: string, onMessages: (messages: Message[]) => void) {
    this.polling = true;
    
    while (this.polling) {
      try {
        const params = new URLSearchParams({
          timeout: '30',
          limit: '50'
        });
        
        if (this.lastMessageId) {
          params.append('since', this.lastMessageId);
        }
        
        const response = await fetch(`/api/v1/messages?${params}`, {
          method: 'GET',
          headers: {
            'Authorization': `Bearer ${accessToken}`,
            'X-Requested-With': 'XMLHttpRequest'
          }
        });
        
        if (!response.ok) {
          if (response.status === 401) {
            // Token expired, refresh it
            await this.refreshToken();
            continue;
          }
          throw new Error(`Polling failed: ${response.status}`);
        }
        
        const data = await response.json();
        
        if (data.messages.length > 0) {
          onMessages(data.messages);
          this.lastMessageId = data.next_since || data.messages[data.messages.length - 1].id;
        }
      } catch (error) {
        console.error('Polling error:', error);
        // Exponential backoff
        await this.delay(5000);
      }
    }
  }

  stopPolling() {
    this.polling = false;
  }

  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
```

**Безопасность:**
- Требует JWT authentication
- Возвращает только сообщения для текущего пользователя
- Rate limiting: максимум 1 запрос в секунду на пользователя

---

### 5. GET /api/v1/users/:id/public-key

**Назначение:** Получение публичного ключа пользователя (мигрировано из `/keys/:user_id`)

**Пример использования:**
```typescript
async function getUserPublicKey(userId: string, accessToken: string) {
  const response = await fetch(`/api/v1/users/${userId}/public-key`, {
    method: 'GET',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'X-Requested-With': 'XMLHttpRequest'
    }
  });
  
  if (!response.ok) {
    throw new Error('Failed to get public key');
  }
  
  return await response.json();
}
```

---

### 6. POST /api/v1/keys/upload

**Назначение:** Загрузка ключей (мигрировано из `/keys/upload`)

**Пример использования:**
```typescript
async function uploadKeys(
  keyBundle: KeyBundle,
  accessToken: string,
  signingKey: SigningKey
) {
  const body = JSON.stringify(keyBundle);
  
  // Sign request if required
  const signature = await signRequest('POST', '/api/v1/keys/upload', body, signingKey);
  
  const response = await fetch('/api/v1/keys/upload', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      'X-Request-Signature': JSON.stringify(signature),
      'X-Requested-With': 'XMLHttpRequest'
    },
    body
  });
  
  if (!response.ok) {
    throw new Error('Failed to upload keys');
  }
  
  return await response.json();
}
```

---

## 📱 Уведомления

### Архитектура уведомлений

**Когда приложение открыто:**
- Используйте **WebSocket** для мгновенной доставки сообщений (если доступен)
- Или используйте **long polling** (`GET /api/v1/messages`) для получения сообщений

**Когда приложение закрыто/в фоне:**
- Используйте **APNs (iOS)** или **FCM (Android)** для системных push-уведомлений
- При нажатии на уведомление приложение открывается и получает сообщения через REST API

**Детальная информация:** См. `NOTIFICATIONS_ARCHITECTURE.md`

---

## ⚠️ Breaking Changes

### Удалено/изменено:
- ❌ Access tokens больше не живут 30 дней (теперь 1 час)
- ⚠️ Старые access tokens продолжат работать до истечения, но новые будут короткоживущими
- ⚠️ **Поиск пользователей НЕ реализован** - пользователи добавляются только через ссылки или QR-коды

### Обратная совместимость:
- ✅ Старые клиенты без refresh token механизма продолжат работать до истечения токенов
- ✅ CSRF protection опциональна для мобильных клиентов (достаточно `X-Requested-With`)
- ✅ Nonce и timestamp опциональны (но рекомендуются)
- ✅ Старые endpoints (`/messages/send`, `/keys/:user_id`, `/keys/upload`) продолжают работать
- ⚠️ Рекомендуется мигрировать на новые `/api/v1/` endpoints

---

## 📞 Поддержка

При возникновении проблем:
1. Проверьте логи сервера для деталей ошибок
2. Убедитесь, что используете последнюю версию API
3. Проверьте, что все заголовки установлены правильно

---

---

## 📚 Дополнительные ресурсы

- `REST_API_MIGRATION_PLAN.md` - Детальный план миграции на REST API
- `NOTIFICATIONS_ARCHITECTURE.md` - Архитектура системы уведомлений
- `MICROSERVICES_ARCHITECTURE_PLAN.md` - План декомпозиции на микросервисы

---

**Последнее обновление:** 2026-01-15  
**Версия:** Phase 2.5.4 (REST API Migration завершена)

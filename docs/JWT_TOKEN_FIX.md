# Исправление проблемы с JWT токенами (401 Unauthorized)

## Проблема

Клиент получает ошибку `401 Unauthorized` с сообщением:
```
Failed to verify HS256 token
```

При этом токен отправляется правильно (586 символов, начинается с `eyJ0eXAiOiJKV1QiLCJh...`), и токен еще не истек.

## Причина

**Несоответствие алгоритмов JWT между сервисами:**

1. **При создании токена (login/register)** - используется **RS256** (если установлены `JWT_PRIVATE_KEY` и `JWT_PUBLIC_KEY`)
2. **При проверке токена (gateway/user-service)** - используется **HS256** (если установлен только `JWT_SECRET`)

Токен создается с алгоритмом RS256, но проверяется как HS256, что приводит к ошибке верификации.

## Решение

### Вариант 1: Использовать RS256 везде (рекомендуется)

**Для всех сервисов (auth-service, gateway, user-service, messaging-service, notification-service):**

1. Убедитесь, что установлены переменные окружения:
   ```bash
   JWT_PRIVATE_KEY=/path/to/private.pem
   JWT_PUBLIC_KEY=/path/to/public.pem
   # JWT_SECRET можно оставить для обратной совместимости со старыми токенами
   ```

2. Проверьте, что все сервисы используют **одни и те же** RSA ключи:
   ```bash
   # На auth-service
   cat $JWT_PUBLIC_KEY | sha256sum
   
   # На gateway/user-service
   cat $JWT_PUBLIC_KEY | sha256sum
   # Должны совпадать!
   ```

3. Убедитесь, что `JWT_ISSUER` одинаковый на всех сервисах:
   ```bash
   # По умолчанию: "construct-server"
   # Если изменен, должен быть одинаковым везде
   JWT_ISSUER=construct-server
   ```

### Вариант 2: Использовать HS256 везде (legacy, не рекомендуется)

**Для всех сервисов:**

1. Убедитесь, что установлена переменная окружения:
   ```bash
   JWT_SECRET=<ваш-секрет>
   ```

2. **Удалите** `JWT_PRIVATE_KEY` и `JWT_PUBLIC_KEY` из всех сервисов:
   ```bash
   unset JWT_PRIVATE_KEY
   unset JWT_PUBLIC_KEY
   ```

3. Убедитесь, что `JWT_SECRET` **одинаковый** на всех сервисах:
   ```bash
   # На auth-service
   echo $JWT_SECRET | sha256sum
   
   # На gateway/user-service
   echo $JWT_SECRET | sha256sum
   # Должны совпадать!
   ```

4. Убедитесь, что `JWT_ISSUER` одинаковый на всех сервисах.

### Вариант 3: Смешанный режим (временное решение)

Если нужно поддерживать оба алгоритма во время миграции:

1. На **auth-service** (создание токенов):
   ```bash
   JWT_PRIVATE_KEY=/path/to/private.pem
   JWT_PUBLIC_KEY=/path/to/public.pem
   JWT_SECRET=<старый-секрет>  # Для обратной совместимости
   ```

2. На **gateway/user-service** (проверка токенов):
   ```bash
   JWT_PRIVATE_KEY=/path/to/private.pem
   JWT_PUBLIC_KEY=/path/to/public.pem
   JWT_SECRET=<тот-же-старый-секрет>  # Для legacy токенов
   ```

   Сервер автоматически попробует RS256, а затем HS256 (если RS256 не прошел).

## Проверка конфигурации

### 1. Проверьте логи при старте сервиса

При инициализации `AuthManager` должны быть логи:

**Для RS256:**
```
Initializing JWT with RS256 algorithm (RSA keypair)
Legacy HS256 support enabled for backward compatibility  # если JWT_SECRET установлен
```

**Для HS256:**
```
Using legacy HS256 algorithm. Consider migrating to RS256 with JWT_PRIVATE_KEY/JWT_PUBLIC_KEY
```

### 2. Проверьте алгоритм токена

Декодируйте токен (без проверки подписи) чтобы увидеть алгоритм:

```bash
# Токен из логов клиента
TOKEN="eyJ0eXAiOiJKV1QiLCJh..."

# Извлечь header
echo $TOKEN | cut -d. -f1 | base64 -d | jq

# Должно показать:
# {
#   "typ": "JWT",
#   "alg": "RS256"  # или "HS256"
# }
```

### 3. Проверьте issuer

```bash
# Извлечь payload
echo $TOKEN | cut -d. -f2 | base64 -d | jq

# Проверить поле "iss":
# {
#   "sub": "user-id",
#   "iss": "construct-server",  # должен совпадать с JWT_ISSUER
#   ...
# }
```

## Быстрое исправление для Fly.io

Если используете Fly.io, проверьте секреты:

```bash
# Проверить секреты на auth-service
fly secrets list -a construct-auth-service

# Проверить секреты на gateway
fly secrets list -a construct-api-gateway

# Установить одинаковые секреты
fly secrets set JWT_PRIVATE_KEY="$(cat private.pem)" -a construct-auth-service
fly secrets set JWT_PUBLIC_KEY="$(cat public.pem)" -a construct-auth-service
fly secrets set JWT_ISSUER="construct-server" -a construct-auth-service

fly secrets set JWT_PRIVATE_KEY="$(cat private.pem)" -a construct-api-gateway
fly secrets set JWT_PUBLIC_KEY="$(cat public.pem)" -a construct-api-gateway
fly secrets set JWT_ISSUER="construct-server" -a construct-api-gateway
```

## Генерация RSA ключей (если нужно)

Если нужно сгенерировать новые RSA ключи:

```bash
# Генерация приватного ключа
openssl genrsa -out private.pem 2048

# Генерация публичного ключа
openssl rsa -in private.pem -pubout -out public.pem

# Проверка
openssl rsa -in private.pem -text -noout
openssl rsa -pubin -in public.pem -text -noout
```

## После исправления

1. Перезапустите все сервисы
2. Попросите пользователей **перелогиниться** (старые токены могут быть с другим алгоритмом)
3. Проверьте логи - ошибки "Failed to verify HS256 token" должны исчезнуть

## Дополнительная диагностика

Если проблема сохраняется, добавьте логирование на сервере:

В файле `/Users/maximeliseyev/Code/construct-server/src/routes/extractors.rs`:

```rust
fn extract_user_id_from_jwt(ctx: &AppContext, headers: &HeaderMap) -> Result<Uuid, AppError> {
    // ... existing code ...
    
    // Extract token (format: "Bearer <token>")
    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or_else(|| AppError::Auth("Invalid Authorization header format".to_string()))?;

    // ✅ DEBUG: Log token info
    tracing::info!(
        token_length = token.len(),
        token_prefix = &token[..token.len().min(30)],
        "Attempting to verify JWT token"
    );

    // Verify and decode JWT
    let claims = ctx
        .auth_manager
        .verify_token(token)
        .map_err(|e| {
            tracing::error!(
                error = %e,
                token_length = token.len(),
                "JWT verification failed"
            );
            AppError::Auth(format!("Invalid or expired token: {}", e))
        })?;
    
    // ... rest of code ...
}
```

Это поможет увидеть, какой токен приходит на сервер и почему он не проходит проверку.

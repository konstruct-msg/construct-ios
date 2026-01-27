# Быстрая настройка DNS для ams.kostruct.cc

**Проблема:** `ams.kostruct.cc` не разрешается DNS (Could not resolve host)

## 🔍 Текущая ситуация

```bash
# Проверка DNS (должно быть пусто)
dig ams.kostruct.cc +short

# Проверка доступности (должна быть ошибка)
curl -I https://ams.kostruct.cc
# Ожидаемая ошибка: Could not resolve host
```

## ✅ Решение: Настройка DNS через Fly.io

### Шаг 1: Проверить, что приложение работает на Fly.io

```bash
# Проверить статус приложения
fly status

# Проверить, что fallback сервер работает
curl -I https://construct-api-gateway.fly.dev
# Должен вернуть: HTTP/2 200 или 301/302
```

### Шаг 2: Добавить домен в Fly.io

```bash
# Войти в Fly.io (если не авторизован)
fly auth login

# Перейти в директорию с приложением (если нужно)
# cd /path/to/your/fly/app

# Добавить домен (Fly.io создаст SSL сертификат автоматически)
fly certs add ams.kostruct.cc
```

**Вывод команды покажет:**
```
The following DNS configuration has been suggested:

  CNAME ams.kostruct.cc -> construct-api-gateway.fly.dev
```

### Шаг 3: Настроить DNS у регистратора домена

1. Войдите в панель управления вашего регистратора домена (где куплен `kostruct.cc`)
2. Найдите раздел DNS / DNS Management / Zone Records
3. Добавьте новую запись:

   **Тип:** CNAME  
   **Имя/Хост:** `ams` (или `ams.kostruct.cc` - зависит от регистратора)  
   **Значение/Цель:** `construct-api-gateway.fly.dev`  
   **TTL:** 3600 (или по умолчанию)

4. Сохраните изменения

### Шаг 4: Проверить настройку DNS

```bash
# Подождать 1-5 минут для распространения DNS

# Проверка DNS
dig ams.kostruct.cc +short
# Должно вернуть: construct-api-gateway.fly.dev.

# Или с CNAME
dig ams.kostruct.cc CNAME +short
# Должно вернуть: construct-api-gateway.fly.dev.

# Проверка доступности
curl -I https://ams.kostruct.cc
# Должен вернуть: HTTP/2 200 или 301/302
```

### Шаг 5: Проверить SSL сертификат

```bash
# Проверить статус сертификата в Fly.io
fly certs show ams.kostruct.cc

# Проверить сертификат через openssl
echo | openssl s_client -connect ams.kostruct.cc:443 -servername ams.kostruct.cc 2>/dev/null | \
  openssl x509 -noout -subject -dates
```

## ⏱️ Время распространения DNS

- **Минимальное:** 1-5 минут
- **Обычное:** 15-30 минут
- **Максимальное:** до 48 часов (редко)

Проверяйте каждые 5-10 минут:
```bash
# Быстрая проверка
dig ams.kostruct.cc +short && echo "✅ DNS настроен" || echo "⏳ Еще не распространился"
```

## 🔄 Если DNS не распространяется

### Проверка с разных DNS серверов

```bash
# Google DNS
dig @8.8.8.8 ams.kostruct.cc +short

# Cloudflare DNS
dig @1.1.1.1 ams.kostruct.cc +short

# Системный DNS
dig ams.kostruct.cc +short
```

### Проверка онлайн

Откройте в браузере:
- https://dnschecker.org/#CNAME/ams.kostruct.cc
- https://www.whatsmydns.net/#CNAME/ams.kostruct.cc

## 🚨 Типичные проблемы

### Проблема: "CNAME already exists"

**Решение:** Удалите старую CNAME запись и создайте новую

### Проблема: "Invalid CNAME target"

**Решение:** Убедитесь, что значение точно: `construct-api-gateway.fly.dev` (с точкой в конце или без - зависит от регистратора)

### Проблема: DNS настроен, но сертификат не выдан

**Решение:**
```bash
# Проверить статус
fly certs show ams.kostruct.cc

# Если статус "pending", подождать (может занять до 24 часов)
# Если ошибка, проверить DNS еще раз
```

## ✅ Финальная проверка

После настройки DNS выполните:

```bash
# 1. DNS работает
dig ams.kostruct.cc +short && echo "✅ DNS OK" || echo "❌ DNS FAILED"

# 2. HTTPS доступен
curl -I -s https://ams.kostruct.cc | grep -q "200\|301\|302" && echo "✅ HTTPS OK" || echo "❌ HTTPS FAILED"

# 3. WebSocket endpoint доступен
curl -i -N -s \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  https://ams.kostruct.cc/ws | grep -q "101" && echo "✅ WebSocket OK" || echo "❌ WebSocket FAILED"
```

## 📝 Примечания

- Пока DNS не настроен, приложение будет работать через fallback: `construct-api-gateway.fly.dev`
- После настройки DNS оба URL будут работать
- Fly.io автоматически выдает SSL сертификат через Let's Encrypt

---

**Следующие шаги после настройки DNS:**
1. Проверить, что WebSocket endpoint `/ws` работает на сервере
2. Обновить клиентское приложение (если нужно)
3. Протестировать подключение

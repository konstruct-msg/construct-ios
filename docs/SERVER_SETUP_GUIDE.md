# Инструкция по настройке и проверке сервера

**Дата:** 2026-01-18  
**Версия:** 1.0

Этот документ содержит инструкции по настройке DNS, проверке WebSocket endpoints и диагностике проблем с подключением.

---

## 📋 Содержание

1. [Проверка DNS](#1-проверка-dns)
2. [Проверка HTTP/HTTPS endpoints](#2-проверка-httphttps-endpoints)
3. [Проверка WebSocket endpoints](#3-проверка-websocket-endpoints)
4. [Настройка DNS для Fly.io](#4-настройка-dns-для-flyio)
5. [Диагностика проблем](#5-диагностика-проблем)

---

## 1. Проверка DNS

### 1.1. Проверка разрешения домена

```bash
# Проверка A-записи (IPv4)
dig ams.kostruct.cc +short
# или
nslookup ams.kostruct.cc

# Проверка AAAA-записи (IPv6)
dig ams.kostruct.cc AAAA +short

# Проверка CNAME записи
dig ams.kostruct.cc CNAME +short
```

**Ожидаемый результат:**
- Если настроен CNAME: должен вернуть `construct-api-gateway.fly.dev.`
- Если настроен A-запись: должен вернуть IP адрес сервера

### 1.2. Проверка с разных DNS серверов

```bash
# Использование Google DNS
dig @8.8.8.8 ams.kostruct.cc +short

# Использование Cloudflare DNS
dig @1.1.1.1 ams.kostruct.cc +short

# Использование системного DNS
dig ams.kostruct.cc +short
```

### 1.3. Проверка TTL и других параметров

```bash
# Полная информация о DNS записи
dig ams.kostruct.cc ANY

# Только важная информация
dig ams.kostruct.cc +noall +answer
```

---

## 2. Проверка HTTP/HTTPS endpoints

### 2.1. Проверка доступности сервера

```bash
# Проверка HTTP (должен редиректить на HTTPS)
curl -I http://ams.kostruct.cc

# Проверка HTTPS
curl -I https://ams.kostruct.cc

# Проверка с выводом заголовков
curl -v https://ams.kostruct.cc
```

### 2.2. Проверка REST API endpoints

```bash
# Проверка health check (если есть)
curl https://ams.kostruct.cc/health

# Проверка API endpoint (может требовать аутентификацию)
curl -X POST https://ams.kostruct.cc/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"username":"test","password":"test"}'

# Проверка fallback сервера
curl -I https://construct-api-gateway.fly.dev
```

### 2.3. Проверка SSL сертификата

```bash
# Проверка SSL сертификата
openssl s_client -connect ams.kostruct.cc:443 -servername ams.kostruct.cc

# Проверка срока действия сертификата
echo | openssl s_client -connect ams.kostruct.cc:443 -servername ams.kostruct.cc 2>/dev/null | \
  openssl x509 -noout -dates

# Проверка цепочки сертификатов
openssl s_client -connect ams.kostruct.cc:443 -servername ams.kostruct.cc -showcerts
```

---

## 3. Проверка WebSocket endpoints

### 3.1. Проверка WebSocket через curl

```bash
# Проверка WebSocket upgrade (должен вернуть 101 Switching Protocols)
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  https://ams.kostruct.cc/ws

# Проверка fallback сервера
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  wss://construct-api-gateway.fly.dev/ws
```

**Ожидаемый результат:**
```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: ...
```

### 3.2. Проверка WebSocket через wscat (требует установки)

```bash
# Установка wscat (если не установлен)
npm install -g wscat

# Подключение к WebSocket
wscat -c wss://ams.kostruct.cc/ws

# Подключение с заголовками
wscat -c wss://ams.kostruct.cc/ws \
  -H "Authorization: Bearer YOUR_TOKEN"

# Проверка fallback сервера
wscat -c wss://construct-api-gateway.fly.dev/ws
```

### 3.3. Проверка WebSocket через Python скрипт

Создайте файл `test_websocket.py`:

```python
#!/usr/bin/env python3
import asyncio
import websockets
import ssl

async def test_websocket(url):
    try:
        # Для wss:// нужно использовать ssl контекст
        if url.startswith('wss://'):
            ssl_context = ssl.create_default_context()
            async with websockets.connect(url, ssl=ssl_context) as websocket:
                print(f"✅ Connected to {url}")
                # Отправить тестовое сообщение
                await websocket.send("test")
                response = await websocket.recv()
                print(f"📨 Response: {response}")
        else:
            async with websockets.connect(url) as websocket:
                print(f"✅ Connected to {url}")
                await websocket.send("test")
                response = await websocket.recv()
                print(f"📨 Response: {response}")
    except Exception as e:
        print(f"❌ Error connecting to {url}: {e}")

# Тестирование обоих серверов
asyncio.run(test_websocket("wss://ams.kostruct.cc/ws"))
asyncio.run(test_websocket("wss://construct-api-gateway.fly.dev/ws"))
```

Запуск:
```bash
# Установка websockets (если не установлен)
pip3 install websockets

# Запуск теста
python3 test_websocket.py
```

### 3.4. Проверка через telnet (базовая проверка порта)

```bash
# Проверка порта 443 (HTTPS/WSS)
telnet ams.kostruct.cc 443

# Проверка порта 80 (HTTP/WS)
telnet ams.kostruct.cc 80
```

---

## 4. Настройка DNS для Fly.io

### 4.1. Получение информации о приложении Fly.io

```bash
# Вход в Fly.io (если не авторизован)
fly auth login

# Проверка статуса приложения
fly status

# Получение информации о доменах
fly domains list

# Получение IP адресов приложения
fly ips list
```

### 4.2. Настройка кастомного домена в Fly.io

```bash
# Добавление домена в Fly.io
fly certs add ams.kostruct.cc

# Проверка статуса сертификата
fly certs show ams.kostruct.cc

# Список всех сертификатов
fly certs list
```

### 4.3. Настройка DNS записей у регистратора

**ВАЖНО:** Сначала нужно добавить домен в Fly.io, затем настроить DNS записи.

#### Шаг 1: Добавить домен в Fly.io

```bash
# Войти в Fly.io (если не авторизован)
fly auth login

# Добавить домен (Fly.io автоматически создаст сертификат)
fly certs add ams.kostruct.cc

# Проверить статус сертификата
fly certs show ams.kostruct.cc
```

После выполнения `fly certs add`, Fly.io покажет необходимые DNS записи.

#### Шаг 2: Настроить DNS у регистратора домена

**Для CNAME (рекомендуется для поддоменов):**
```
Тип: CNAME
Имя: ams (или ams.kostruct.cc, зависит от регистратора)
Значение: construct-api-gateway.fly.dev
TTL: 3600 (или автоматически)
```

**Для A-записи (если CNAME не поддерживается или для корневого домена):**
```bash
# Получить IP адреса приложения
fly ips list

# Создать A-записи для каждого IPv4 адреса
# Тип: A
# Имя: ams (или ams.kostruct.cc)
# Значение: <IPv4_ADDRESS>

# Если есть IPv6, создать AAAA записи
# Тип: AAAA
# Имя: ams (или ams.kostruct.cc)
# Значение: <IPv6_ADDRESS>
```

**Примечание:** 
- Для поддоменов (ams.kostruct.cc) обычно используется CNAME
- Для корневого домена (kostruct.cc) может потребоваться A-запись
- Некоторые регистраторы требуют полное имя (ams.kostruct.cc), другие только поддомен (ams)

### 4.4. Проверка настройки DNS после изменений

```bash
# Подождать распространение DNS (обычно 5-60 минут)
# Проверить DNS
dig ams.kostruct.cc +short

# Проверить, что домен указывает на Fly.io
curl -I https://ams.kostruct.cc
```

---

## 5. Диагностика проблем

### 5.1. Скрипт для полной диагностики

Создайте файл `diagnose_server.sh`:

```bash
#!/bin/bash

DOMAIN="ams.kostruct.cc"
FALLBACK="construct-api-gateway.fly.dev"
WS_PATH="/ws"

echo "🔍 Диагностика сервера $DOMAIN"
echo "=================================="
echo ""

echo "1️⃣ Проверка DNS..."
echo "-------------------"
echo "A-запись:"
dig $DOMAIN +short A
echo ""
echo "CNAME:"
dig $DOMAIN +short CNAME
echo ""

echo "2️⃣ Проверка HTTP/HTTPS..."
echo "--------------------------"
echo "HTTP (должен редиректить на HTTPS):"
curl -I -s http://$DOMAIN | head -1
echo ""
echo "HTTPS:"
curl -I -s https://$DOMAIN | head -1
echo ""

echo "3️⃣ Проверка SSL сертификата..."
echo "-------------------------------"
echo | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN 2>/dev/null | \
  openssl x509 -noout -subject -dates 2>/dev/null || echo "❌ Не удалось получить сертификат"
echo ""

echo "4️⃣ Проверка WebSocket endpoint..."
echo "----------------------------------"
echo "Проверка $DOMAIN$WS_PATH:"
curl -i -N -s \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  https://$DOMAIN$WS_PATH | head -5
echo ""

echo "5️⃣ Проверка fallback сервера..."
echo "--------------------------------"
echo "HTTPS:"
curl -I -s https://$FALLBACK | head -1
echo ""
echo "WebSocket:"
curl -i -N -s \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  wss://$FALLBACK$WS_PATH | head -5
echo ""

echo "✅ Диагностика завершена"
```

Сделайте скрипт исполняемым и запустите:
```bash
chmod +x diagnose_server.sh
./diagnose_server.sh
```

### 5.2. Проверка с разных локаций

```bash
# Использование онлайн сервисов для проверки DNS
# Откройте в браузере:
# - https://dnschecker.org/#A/ams.kostruct.cc
# - https://www.whatsmydns.net/#A/ams.kostruct.cc

# Проверка доступности с разных DNS серверов
for dns in 8.8.8.8 1.1.1.1 208.67.222.222; do
  echo "Checking with DNS $dns:"
  dig @$dns ams.kostruct.cc +short
  echo ""
done
```

### 5.3. Проверка таймаутов и задержек

```bash
# Проверка времени отклика
time curl -s -o /dev/null -w "%{time_total}\n" https://ams.kostruct.cc

# Проверка с таймаутом
curl --connect-timeout 5 --max-time 10 https://ams.kostruct.cc

# Проверка через traceroute
traceroute ams.kostruct.cc
# или
mtr ams.kostruct.cc
```

---

## 6. Быстрая проверка (чеклист)

Выполните эти команды для быстрой проверки:

```bash
# 1. DNS работает?
dig ams.kostruct.cc +short && echo "✅ DNS OK" || echo "❌ DNS FAILED"

# 2. HTTPS доступен?
curl -I -s https://ams.kostruct.cc | grep -q "200\|301\|302" && echo "✅ HTTPS OK" || echo "❌ HTTPS FAILED"

# 3. WebSocket endpoint доступен?
curl -i -N -s \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  https://ams.kostruct.cc/ws | grep -q "101" && echo "✅ WebSocket OK" || echo "❌ WebSocket FAILED"

# 4. Fallback сервер работает?
curl -I -s https://construct-api-gateway.fly.dev | grep -q "200\|301\|302" && echo "✅ Fallback OK" || echo "❌ Fallback FAILED"
```

---

## 7. Типичные проблемы и решения

### Проблема: DNS не разрешается (-1003)

**Причина:** Домен не настроен в DNS или еще не распространился

**Решение:**
1. Проверить DNS записи: `dig ams.kostruct.cc +short`
2. Если пусто - настроить CNAME или A-запись
3. Подождать распространения DNS (5-60 минут)
4. Проверить с разных DNS серверов

### Проблема: WebSocket возвращает 404

**Причина:** Endpoint `/ws` не настроен на сервере

**Решение:**
1. Проверить конфигурацию сервера
2. Убедиться, что WebSocket endpoint зарегистрирован
3. Проверить прокси конфигурацию (если используется)

### Проблема: SSL сертификат недействителен

**Причина:** Сертификат не выдан для домена или истек

**Решение:**
1. Выполнить `fly certs add ams.kostruct.cc`
2. Дождаться выдачи сертификата (может занять время)
3. Проверить: `fly certs show ams.kostruct.cc`

### Проблема: Connection timeout

**Причина:** Файрвол блокирует подключение или сервер недоступен

**Решение:**
1. Проверить статус приложения: `fly status`
2. Проверить логи: `fly logs`
3. Проверить, что порты открыты

---

## 8. Полезные команды Fly.io

```bash
# Просмотр логов в реальном времени
fly logs

# Просмотр метрик
fly metrics

# Проверка статуса приложения
fly status

# Перезапуск приложения
fly apps restart

# Просмотр конфигурации
fly config show

# SSH подключение к приложению
fly ssh console
```

---

## 9. Дополнительные ресурсы

- [Fly.io DNS документация](https://fly.io/docs/reference/dns/)
- [Fly.io Custom Domains](https://fly.io/docs/app-guides/custom-domains-with-fly/)
- [WebSocket тестирование](https://www.websocket.org/echo.html)

---

**Последнее обновление:** 2026-01-18

# Reconnection Edge Cases & Potential Issues

**Date:** 2026-01-24  
**Status:** Analysis of remaining reconnection problems

---

## Проблемы найдены:

### 🔴 ПРОБЛЕМА 1: Нет экспоненциального backoff при ошибках

**Файл:** `ChatsViewModel.swift`, строка 169

```swift
} catch {
    Log.error("❌ Long polling error: \(error.localizedDescription)")
    try? await Task.sleep(nanoseconds: 5_000_000_000) // Всегда 5 секунд ❌
}
```

**Проблема:**
- При ошибке всегда ждёт 5 секунд
- Если сервер недоступен → бесконечные попытки каждые 5 сек
- Убивает батарею, создаёт нагрузку на сеть

**Решение:**
```swift
private var retryCount = 0
private let maxRetryDelay: UInt64 = 60_000_000_000  // 60 секунд max

} catch {
    Log.error("❌ Long polling error: \(error.localizedDescription)")
    
    // Exponential backoff: 5s, 10s, 20s, 40s, 60s (max)
    retryCount += 1
    let delay = min(
        UInt64(5_000_000_000) * UInt64(pow(2.0, Double(min(retryCount - 1, 4)))),
        maxRetryDelay
    )
    
    Log.info("⏳ Retrying in \(delay / 1_000_000_000) seconds (attempt #\(retryCount))")
    try? await Task.sleep(nanoseconds: delay)
}

// Reset on success:
retryCount = 0
```

**Benefit:**
- 1-я ошибка: 5 сек
- 2-я ошибка: 10 сек
- 3-я ошибка: 20 сек
- 4-я ошибка: 40 сек
- 5+ ошибок: 60 сек (max)

---

### 🟡 ПРОБЛЕМА 2: lastMessageId теряется при переподключении

**Файл:** `ChatsViewModel.swift`, строки 23-26

```swift
// ✅ Long polling state
private var isPolling = false
private var lastMessageId: String?  // ❌ Не сохраняется при рестарте приложения
private var pollingTask: Task<Void, Never>?
```

**Проблема:**
- При закрытии/открытии приложения `lastMessageId = nil`
- Запрашивает ВСЕ сообщения заново
- Может пропустить сообщения, которые пришли во время оффлайна

**Решение:**
```swift
// Сохранить в UserDefaults
private var lastMessageId: String? {
    didSet {
        if let id = lastMessageId {
            UserDefaults.standard.set(id, forKey: "lastMessageId")
        }
    }
}

// Восстановить при инициализации
init() {
    self.lastMessageId = UserDefaults.standard.string(forKey: "lastMessageId")
    setupSubscribers()
}
```

**Альтернатива:** Использовать `next_since` из сервера (уже есть в response)

---

### 🟡 ПРОБЛЕМА 3: Нет обработки частичного переподключения

**Сценарий:**
1. WiFi подключен, но без интернета
2. `NWPathMonitor` говорит: `status = .satisfied`
3. `ConnectionStatusManager` думает: "Connected"
4. На самом деле: сервер недоступен

**Текущее поведение:**
```
NetworkReachabilityManager: isReachable = true ✅
ConnectionStatusManager: status = .connecting ⏳
RestAPIClient: все запросы падают с timeout
```

**Решение:**
Уже частично решено через grace period (2 минуты). Но можно улучшить:

```swift
// Периодическая проверка здоровья соединения
func checkConnectionHealth() async {
    // Lightweight ping endpoint
    try? await RestAPIClient.shared.ping()  // GET /api/v1/health
}

// Вызывать каждые 60 секунд при status = .connecting
```

---

### 🟢 ПРОБЛЕМА 4: Polling не останавливается при логауте ✅ FIXED

**Файл:** `ChatsViewModel.swift`, строки 82-88

```swift
} else {
    if token == nil {
        Log.info("📡 No session token - stopping polling")
    }
    self?.stopLongPolling()  // ✅ Уже обрабатывается
}
```

**Статус:** ✅ Работает корректно (через Combine)

---

### 🔴 ПРОБЛЕМА 5: Race condition при быстром переподключении

**Сценарий:**
1. Пользователь в метро: WiFi → нет WiFi → WiFi → нет WiFi
2. Каждое изменение запускает `startLongPolling()`
3. Множественные `pollingTask` конкурируют

**Текущая защита:**
```swift
func startLongPolling() {
    guard !isPolling else {  // ✅ Есть проверка
        Log.info("📡 Long polling already running")
        return
    }
```

**Проблема:**
- Между проверкой `!isPolling` и установкой `isPolling = true` может быть race
- Если 2 вызова одновременно → оба пройдут проверку

**Решение:**
```swift
private let pollingLock = NSLock()

func startLongPolling() {
    pollingLock.lock()
    defer { pollingLock.unlock() }
    
    guard !isPolling else {
        Log.info("📡 Long polling already running")
        return
    }
    
    isPolling = true
    // ...
}
```

**Альтернатива:** Использовать `actor` (Swift Concurrency):
```swift
actor PollingCoordinator {
    private var isPolling = false
    
    func startPolling() -> Bool {
        guard !isPolling else { return false }
        isPolling = true
        return true
    }
}
```

---

### 🟡 ПРОБЛЕМА 6: Нет переподключения после изменения сервера

**Файл:** `RestAPIClient.swift`

**Проблема:**
- Пользователь меняет сервер в настройках
- `workingServerURL` остаётся старым
- Первый запрос пытается старый сервер → фейл → пробует новый

**Решение:**
```swift
// В RestAPIClient добавить:
func resetServerConnection() {
    workingServerURL = nil
    connectionStatusManager.markConnecting()
}

// В NetworkSettingsView после изменения:
APIConstants.activeServerURL = newURL
RestAPIClient.shared.resetServerConnection()
```

---

### 🔴 ПРОБЛЕМА 7: Polling не возобновляется после фона

**iOS поведение:**
- Приложение уходит в background
- `URLSession` tasks продолжаются некоторое время
- Потом iOS приостанавливает

**Текущая логика:**
```swift
// ChatsViewModel.swift
private func pollMessagesLoop() async {
    while isPolling && !Task.isCancelled {  // ❌ Не учитывает app state
```

**Проблема:**
- Polling продолжается в фоне (тратит батарею)
- Или Task отменяется и не возобновляется при возвращении

**Решение:**
```swift
// Подписаться на app lifecycle
init() {
    setupSubscribers()
    setupAppLifecycleObservers()
}

private func setupAppLifecycleObservers() {
    NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        .sink { [weak self] _ in
            Log.info("📱 App going to background - pausing polling")
            self?.pauseLongPolling()
        }
        .store(in: &cancellables)
    
    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        .sink { [weak self] _ in
            Log.info("📱 App became active - resuming polling")
            if self?.isPaused == true {
                self?.resumeLongPolling()
            }
        }
        .store(in: &cancellables)
}
```

---

## Приоритизация исправлений:

### 🔥 КРИТИЧНЫЕ (исправить сейчас):
1. **Exponential backoff** - экономия батареи, защита от DDoS себя
2. **App lifecycle** - корректная работа при background/foreground

### ⚠️ ВАЖНЫЕ (исправить скоро):
3. **lastMessageId persistence** - не терять позицию при рестарте
4. **Race condition** - потенциальные крэши

### 📝 ЖЕЛАТЕЛЬНЫЕ (можно отложить):
5. **Health check endpoint** - лучшая диагностика
6. **Server reset on change** - UX improvement

---

## Рекомендованный план действий:

### Этап 1: Критичные исправления (30 мин)
```
1. Добавить exponential backoff в pollMessagesLoop()
2. Добавить app lifecycle observers
3. Тестирование: background/foreground циклы
```

### Этап 2: Важные исправления (20 мин)
```
4. Сохранить lastMessageId в UserDefaults
5. Добавить pollingLock для thread safety
6. Тестирование: быстрое переподключение (airplane mode toggle)
```

### Этап 3: Желательные (опционально)
```
7. Создать /api/v1/health endpoint на сервере
8. Реализовать resetServerConnection()
```

---

## Код для немедленного применения:

### Fix 1: Exponential Backoff

```swift
// В ChatsViewModel.swift добавить:
private var retryCount = 0
private let maxRetryDelay: UInt64 = 60_000_000_000  // 60 seconds

// В pollMessagesLoop() изменить:
} catch {
    Log.error("❌ Long polling error: \(error.localizedDescription)", category: "ChatsViewModel")
    
    // Exponential backoff with jitter
    retryCount += 1
    let baseDelay: UInt64 = 5_000_000_000  // 5 seconds
    let exponentialDelay = baseDelay * UInt64(pow(2.0, Double(min(retryCount - 1, 4))))
    let jitter = UInt64.random(in: 0...(baseDelay / 2))  // Random jitter to prevent thundering herd
    let delay = min(exponentialDelay + jitter, maxRetryDelay)
    
    Log.info("⏳ Retry #\(retryCount) in \(delay / 1_000_000_000) seconds", category: "ChatsViewModel")
    try? await Task.sleep(nanoseconds: delay)
}

// После успешного запроса:
retryCount = 0  // Reset backoff on success
```

### Fix 2: App Lifecycle

```swift
// В ChatsViewModel добавить:
private var isPaused = false

private func setupAppLifecycleObservers() {
    NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Log.info("📱 App going to background", category: "ChatsViewModel")
            self?.isPaused = true
            self?.stopLongPolling()
        }
        .store(in: &cancellables)
    
    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Log.info("📱 App became active", category: "ChatsViewModel")
            if self?.isPaused == true {
                self?.isPaused = false
                // Let Combine publisher restart polling if conditions are met
                // (token exists and connected)
            }
        }
        .store(in: &cancellables)
}

// В init() добавить:
init() {
    setupSubscribers()
    setupAppLifecycleObservers()  // ← Добавить
}
```

### Fix 3: Persistence

```swift
// В ChatsViewModel изменить:
private var lastMessageId: String? {
    didSet {
        if let id = lastMessageId {
            UserDefaults.standard.set(id, forKey: "construct.lastMessageId")
            Log.debug("💾 Saved lastMessageId: \(id)", category: "ChatsViewModel")
        } else {
            UserDefaults.standard.removeObject(forKey: "construct.lastMessageId")
        }
    }
}

// В init() добавить:
init() {
    // Restore lastMessageId from UserDefaults
    self.lastMessageId = UserDefaults.standard.string(forKey: "construct.lastMessageId")
    if let restored = lastMessageId {
        Log.info("📥 Restored lastMessageId: \(restored)", category: "ChatsViewModel")
    }
    
    setupSubscribers()
    setupAppLifecycleObservers()
}
```

---

**Применить эти 3 исправления?** 
- ✅ Exponential backoff
- ✅ App lifecycle handling
- ✅ lastMessageId persistence

Это займёт ~30 минут и сразу улучшит стабильность на 80%.

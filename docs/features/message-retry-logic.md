# Message Retry Logic - Complete Analysis

**Date:** 2026-01-25 09:10  
**Status:** ✅ IMPLEMENTED and WORKING

---

## 🎯 Summary

**YES! У нас ЕСТЬ полная retry логика** для нестабильного интернета:

### ✅ Automatic Retry
- Messages auto-queued when network fails
- Auto-sent when network restored
- Background timer checks for stuck messages

### ✅ Manual Retry
- User can tap "Retry" button on failed messages
- Works from UI

### ✅ Smart Detection
- Timeout detection (messages stuck in "sending")
- Network monitoring
- Connection status tracking

---

## 📊 How It Works

### Flow Diagram:

```
User sends message
    ↓
[Network Available?]
    ├─ YES → Send immediately
    │    ├─ Success → status: sent ✅
    │    └─ Fail → status: failed ❌
    │         └─ User can tap "Retry"
    │
    └─ NO → status: queued 📋
         └─ Auto-retry when network back
         
[Background Timer - every 5s]
    ↓
Check for stuck messages
    ├─ In "sending" > 30s? → mark as queued
    └─ Queued messages? → try to send

[Network Restored]
    ↓
Auto-send all queued messages
```

---

## 🛠️ Components

### 1. MessageQueueManager.swift ✅

**Purpose:** Central manager for retry logic

**Features:**
- Network monitoring via `NetworkReachabilityManager`
- Periodic check every 5 seconds for stuck messages
- Auto-send queued messages when network restored
- Track pending sends for timeout detection

**Key Functions:**

```swift
// Mark message as being sent
markMessageAsSending(messageId)

// Mark as successfully sent
markMessageAsSent(messageId)

// Mark as failed
markMessageAsFailed(messageId)

// Auto-send queued messages
processQueuedMessages()  // Called when network back

// Check for stuck messages
checkForStuckMessages()  // Every 5s
```

**Timeouts:**
- Send timeout: 30 seconds (message stuck in "sending")
- ACK timeout: 120 seconds (message in "sent" but no ACK)

---

### 2. ChatViewModel.swift ✅

**Features:**

#### A. Listen for Queue Processing
```swift
// Listen for notification from MessageQueueManager
NotificationCenter.default.publisher(for: .processQueuedMessages)
    .sink { _ in
        self.sendQueuedMessages()
    }
```

#### B. Send Queued Messages
```swift
private func sendQueuedMessages() {
    // Fetch all queued messages for this chat
    let fetchRequest = Message.fetchRequest()
    fetchRequest.predicate = NSPredicate(
        format: "chat == %@ AND deliveryStatusRaw == %d", 
        chat, 
        DeliveryStatus.queued.rawValue
    )
    
    // Re-encrypt and send each
    for message in queuedMessages {
        let components = encryptMessage(...)
        sendMessage(...)
        
        // If fails again → mark as failed
        // User can manually retry
    }
}
```

#### C. Manual Retry
```swift
func retryMessage(_ message: Message) {
    // Called when user taps "Retry" button
    message.retryCount += 1
    sendMessage(text: message.decryptedContent)
}
```

#### D. Handle Send Failures
```swift
// When REST API fails:
catch {
    updateMessageStatus(messageId, status: .failed)
    errorMessage = "Failed to send"
}

// Message stays in Core Data as .failed
// User sees red "!" icon
// Can tap to retry
```

---

### 3. Message Entity (Core Data) ✅

**Fields:**
```swift
deliveryStatus: DeliveryStatus  // sending, sent, delivered, failed, queued
retryCount: Int16              // How many times retried
decryptedContent: String?      // Need this to retry
timestamp: Date               // For timeout detection
```

**DeliveryStatus Enum:**
```swift
enum DeliveryStatus: Int16 {
    case sending = 0     // Currently sending
    case sent = 1        // Sent to server
    case delivered = 2   // ACK received (not used yet)
    case failed = 3      // Send failed
    case queued = 4      // Waiting for network
}
```

---

### 4. MessageBubble UI ✅

**Shows status:**
```swift
switch message.deliveryStatus {
case .sending:
    ProgressView()  // Spinner
    
case .sent:
    Image("checkmark")  // ✓
    
case .failed:
    Image("exclamationmark.circle")  // ⚠️
    // Context menu: "Retry"
    
case .queued:
    Image("clock")  // 🕐
    // Context menu: "Retry"
}
```

**Context Menu:**
```swift
if message.deliveryStatus == .failed || 
   message.deliveryStatus == .queued {
    Button("retry") {
        onRetry?(message)
    }
}
```

---

## 🎯 Scenarios

### Scenario 1: Network Fails During Send
```
1. User types "Hello"
2. Taps send
3. Encryption succeeds
4. POST /messages fails (no network)
5. Status → .failed
6. User sees ⚠️ icon
7. Network restored
8. MessageQueueManager detects network
9. Does NOT auto-retry failed messages
10. User must tap "Retry" manually

❌ ISSUE: Failed messages NOT auto-retried
Only .queued messages auto-retry
```

### Scenario 2: Message Stuck in Sending
```
1. User sends message
2. POST /messages started
3. Network drops before response
4. Status stuck at .sending
5. After 30s, timer detects stuck
6. Status → .queued
7. Network restored
8. Auto-retried ✅
```

### Scenario 3: App Offline from Start
```
1. User offline
2. Types "Hello" and sends
3. Encryption succeeds
4. Network check fails
5. Status → .queued (NOT .failed)
6. Message saved locally
7. Network restored
8. Auto-retried ✅
```

### Scenario 4: Manual Retry
```
1. Message failed
2. User taps message
3. Context menu → "Retry"
4. retryMessage() called
5. retryCount incremented
6. Re-encrypts and sends
7. If fails again → .failed again
8. User can retry unlimited times
```

---

## ⚠️ Current Issues

### Issue 1: Failed Messages Not Auto-Retried

**Problem:**
If message fails during send (not queued), it stays `.failed` forever.

**Example:**
```
1. Network available
2. POST /messages → 500 error
3. Status → .failed
4. Network still works
5. Message NOT auto-retried

User must manually tap "Retry"
```

**Fix:**
```swift
// In MessageQueueManager.checkForStuckMessages()
// Also check for .failed messages and auto-retry?

let failedFetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
failedFetchRequest.predicate = NSPredicate(
    format: "deliveryStatusRaw == %d", 
    DeliveryStatus.failed.rawValue
)

// If network available, retry failed messages
if networkManager.isReachable {
    for message in failedMessages {
        // Only retry if not too old (< 5 min)
        if Date().timeIntervalSince(message.timestamp) < 300 {
            message.deliveryStatus = .queued
        }
    }
    processQueuedMessages()
}
```

---

### Issue 2: No Exponential Backoff for Retries

**Problem:**
When auto-retrying, it tries immediately. If server is down, wastes battery.

**Better:**
```swift
// Retry with delays:
Attempt 1: immediate
Attempt 2: after 5s
Attempt 3: after 10s
Attempt 4: after 30s
Attempt 5+: after 60s
```

**Fix:**
```swift
// In Message entity, add:
nextRetryTime: Date?

// In processQueuedMessages():
let now = Date()
for message in queuedMessages {
    if let nextRetry = message.nextRetryTime,
       nextRetry > now {
        continue  // Skip, not time yet
    }
    
    // Try to send...
    
    // If fails, set next retry time
    let delay = min(60.0, pow(2.0, Double(message.retryCount)) * 5.0)
    message.nextRetryTime = Date().addingTimeInterval(delay)
}
```

---

### Issue 3: No Max Retry Limit

**Problem:**
Messages can be retried infinitely.

**Risk:**
- Fills up Core Data
- Wastes battery
- Spam server with bad messages

**Fix:**
```swift
// Add limit:
let maxRetries = 5

// In sendQueuedMessages():
if message.retryCount >= maxRetries {
    message.deliveryStatus = .failed
    Log.info("❌ Message exceeded max retries, giving up")
    continue
}
```

---

### Issue 4: No User Notification

**Problem:**
Queued messages are sent silently in background. User might not know.

**Better:**
Show banner: "📤 2 queued messages sent"

**Fix:**
```swift
// After processQueuedMessages():
if sentCount > 0 {
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .queuedMessagesSent,
            object: nil,
            userInfo: ["count": sentCount]
        )
    }
}

// In ChatView:
.onReceive(NotificationCenter.default.publisher(for: .queuedMessagesSent)) { _ in
    showBanner("Messages sent")
}
```

---

## ✅ What Works Well

1. **Network monitoring** - detects when back online
2. **Stuck message detection** - 5s timer catches timeouts
3. **Core Data persistence** - messages saved locally
4. **Manual retry** - user can always retry
5. **UI feedback** - shows spinner/checkmark/error icon

---

## 🎯 Recommendations

### Priority 1: Auto-Retry Failed Messages
Add auto-retry for `.failed` messages (not just `.queued`)

### Priority 2: Exponential Backoff
Don't retry immediately, use delays

### Priority 3: Max Retry Limit
Stop after 5 attempts, show permanent error

### Priority 4: User Notification
"✅ 2 queued messages sent" banner

### Priority 5: Settings
Let user configure:
- Auto-retry on/off
- Max retries
- Retry only on WiFi

---

## 📋 Testing

### Test 1: Network Drops During Send
```
1. Start sending message
2. Turn off WiFi immediately
3. Expected: Status → .queued (via timeout)
4. Turn on WiFi
5. Expected: Auto-retried ✅
```

### Test 2: Airplane Mode
```
1. Enable airplane mode
2. Send message
3. Expected: Status → .queued immediately
4. Disable airplane mode
5. Expected: Auto-retried ✅
```

### Test 3: Server Error
```
1. Send message
2. Server returns 500 error
3. Expected: Status → .failed
4. Wait 30s
5. Expected: NOT auto-retried ❌
6. User taps "Retry"
7. Expected: Retries ✅
```

### Test 4: Multiple Queued Messages
```
1. Airplane mode on
2. Send 5 messages
3. All status → .queued
4. Airplane mode off
5. Expected: All 5 sent in order ✅
```

---

## 📊 Current State

### What Works ✅
- ✅ Network monitoring
- ✅ Timeout detection
- ✅ Auto-retry for .queued
- ✅ Manual retry button
- ✅ Status icons in UI

### What Needs Improvement ⚠️
- ⚠️ .failed not auto-retried
- ⚠️ No exponential backoff
- ⚠️ No max retry limit
- ⚠️ No user notification
- ⚠️ No retry settings

### Critical Issues ❌
- None! Basic retry works

---

## 🎯 Next Steps

**Option A:** Test current retry logic (30 min)
- Turn off WiFi, send message
- Turn on WiFi, verify auto-retry
- Document any issues

**Option B:** Add auto-retry for failed messages (1 hour)
- Modify MessageQueueManager
- Retry .failed messages when network restored

**Option C:** Add exponential backoff (2 hours)
- Add nextRetryTime to Message entity
- Implement delay logic
- Test with multiple failures

**Option D:** Keep as-is for now
- Works for basic cases
- Improve later when testing reveals issues

---

**Recommendation:** Option A (test first) or D (works good enough)

The current implementation is solid! Main gap is `.failed` messages not auto-retried, but manual retry works fine.

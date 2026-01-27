# Construct Messenger - Improvement Roadmap

**Date Created:** 2026-01-24  
**Status:** Planning Phase  
**Priority:** Stability, Energy Efficiency, Privacy

---

## 🎯 Executive Summary

This document outlines architectural improvements for Construct Messenger focusing on:
1. **Stability** - Offline support, retry logic, state management
2. **Energy Efficiency** - Adaptive polling, push notifications, connection pooling
3. **Privacy** - Traffic obfuscation, padding, timing analysis resistance
4. **Scalability** - Gradual rollout strategy, backward compatibility

---

## 📊 Priority Matrix

| Feature | Stability | Energy | Security | Complexity | Priority | ETA |
|---------|-----------|--------|----------|-----------|----------|-----|
| Offline Queue | 🟢 High | 🟢 High | 🟢 High | Low | **P0** | 1-2 days |
| APNs Push Notifications | 🟢 High | 🟢 High | 🟢 High | Medium | **P0** | 3-5 days |
| State Machine (Phase 3) | 🟢 High | 🟡 Medium | 🟢 High | High | **P1** | 1-2 weeks |
| Message Padding | 🟡 Medium | 🟢 High | 🟢 High | Low | **P1** | 1-2 days |
| Adaptive Polling | 🟡 Medium | 🟢 High | 🟡 Medium | Low | **P1** | 1 day |
| WebSocket (optional) | 🟢 High | 🟢 High | 🟡 Medium | High | **P2** | 2-3 weeks |
| Timing Obfuscation | 🟡 Medium | 🟡 Medium | 🟢 High | Medium | **P2** | 3-5 days |
| Dummy Traffic | 🟡 Medium | 🔴 Low | 🟢 High | Medium | **P3** | 2-3 days |
| Protocol Mimicry | 🟡 Medium | 🟡 Medium | 🟢 High | High | **P3** | 2-4 weeks |

---

## 🔋 Phase 1: Energy Efficiency & Stability (P0)

### 1.1 Offline Message Queue

**Problem:**
- Messages sent without network are lost
- No retry mechanism
- Poor UX in flaky network conditions

**Solution:**

```swift
// Message.swift
enum MessageDeliveryState {
    case draft              // Created locally, not sent yet
    case queued             // Waiting for network
    case sending            // Currently being sent
    case sent(serverId: String)  // Acknowledged by server
    case delivered          // Delivered to recipient
    case read               // Read by recipient
    case failed(error: Error, retryCount: Int)
}

// OfflineQueueManager.swift
@MainActor
class OfflineQueueManager: ObservableObject {
    @Published var pendingMessages: [Message] = []
    private let maxRetries = 5
    
    func enqueue(_ message: Message) {
        message.state = .queued
        pendingMessages.append(message)
        saveToCoreData(message)
        
        // Try to send immediately
        Task {
            await processPendingMessages()
        }
    }
    
    func processPendingMessages() async {
        guard ConnectionStatusManager.shared.isConnected else {
            return // Wait for network
        }
        
        for message in pendingMessages where message.state == .queued {
            await sendWithRetry(message)
        }
    }
    
    private func sendWithRetry(_ message: Message) async {
        var retryCount = 0
        
        while retryCount < maxRetries {
            do {
                message.state = .sending
                let response = try await RestAPIClient.shared.sendMessage(message)
                
                message.state = .sent(serverId: response.messageId)
                pendingMessages.removeAll { $0.id == message.id }
                updateCoreData(message)
                return
                
            } catch NetworkError.offline, NetworkError.timeout {
                // Exponential backoff: 2^n seconds
                let delay = pow(2.0, Double(retryCount))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                retryCount += 1
                
            } catch {
                // Permanent error (validation, auth, etc.)
                message.state = .failed(error: error, retryCount: retryCount)
                updateCoreData(message)
                Log.error("❌ Message send failed permanently: \(error)")
                return
            }
        }
        
        // Max retries exceeded
        message.state = .failed(
            error: NetworkError.timeout,
            retryCount: maxRetries
        )
        updateCoreData(message)
    }
}
```

**Implementation Steps:**
1. Add `deliveryState` to Core Data Message entity
2. Create `OfflineQueueManager.swift`
3. Subscribe to `ConnectionStatusManager.$connectionStatus`
4. Auto-resume queue when connection restored
5. Add UI indicators (sending spinner, retry button)

**Testing:**
- Enable Airplane Mode
- Send 5 messages
- Disable Airplane Mode
- Verify all 5 messages sent with exponential backoff

---

### 1.2 APNs Push Notifications

**Goal:** Wake app when new messages arrive instead of constant polling

**Architecture:**

```
┌─────────┐         ┌──────────┐         ┌─────────┐         ┌──────────┐
│ Sender  │──msg──▶ │  Server  │──push──▶│  APNs   │──wake──▶│ Receiver │
└─────────┘         └──────────┘         └─────────┘         └──────────┘
                           │
                           │ Store encrypted msg
                           ▼
                      ┌─────────┐
                      │  Redis  │
                      └─────────┘
```

**Server-Side (Rust):**

```rust
// shared/src/construct_server/apns/mod.rs

use a2::{Client, DefaultNotificationBuilder, NotificationOptions};

pub struct ApnsService {
    client: Client,
}

impl ApnsService {
    pub async fn send_message_notification(
        &self,
        recipient_id: &str,
        device_token: &str,
    ) -> Result<()> {
        // ✅ CRITICAL: No message content in push!
        // Only wake the app, it will fetch encrypted messages
        let payload = json!({
            "aps": {
                "content-available": 1,  // Silent push
                "badge": 1,              // Update badge count
                "sound": "",             // Silent (or "default.caf")
            },
            "messageId": "encrypted",    // Don't leak metadata
        });

        let mut builder = DefaultNotificationBuilder::new()
            .set_body(&payload.to_string())
            .set_sound("default")
            .set_badge(1);

        let options = NotificationOptions {
            apns_topic: Some("cc.konstruct.messenger"),
            ..Default::default()
        };

        self.client.send(builder.build(device_token, options)).await?;
        Ok(())
    }
}

// In messaging-service send_message handler:
async fn send_message(...) -> Result<()> {
    // 1. Store encrypted message
    redis.store_message(&envelope).await?;
    
    // 2. Get recipient's device tokens
    let tokens = db.get_device_tokens(&recipient_id).await?;
    
    // 3. Send silent push (wake app)
    for token in tokens {
        apns.send_message_notification(&recipient_id, &token).await?;
    }
    
    Ok(())
}
```

**Client-Side (Swift):**

```swift
// AppDelegate.swift

func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    // Register for push notifications
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        if granted {
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
    }
    return true
}

func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    
    // Send to server
    Task {
        try? await RestAPIClient.shared.registerDeviceToken(token)
    }
}

func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    // Silent push received - fetch new messages
    Task {
        do {
            let messages = try await RestAPIClient.shared.pollMessages(timeout: 0)
            if !messages.isEmpty {
                await ChatsViewModel.shared.processMessages(messages)
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
        } catch {
            completionHandler(.failed)
        }
    }
}
```

**Energy Impact:**
- **Before:** Long-polling every 30 seconds = ~2,880 requests/day
- **After:** Push-triggered fetch = ~10-50 requests/day (only when messages arrive)
- **Savings:** ~98% reduction in network requests ✅

**Privacy Considerations:**
- ✅ Push notification contains NO message content
- ✅ Push notification contains NO sender info
- ✅ Only triggers app wake → fetch → decrypt locally
- ❌ Apple knows when you receive messages (metadata leak)
- **Mitigation:** Use dummy pushes (see Phase 3)

---

### 1.3 Adaptive Polling Intervals

**Goal:** Reduce polling frequency based on battery and usage patterns

```swift
// AdaptivePollingManager.swift

class AdaptivePollingManager {
    enum PollingStrategy {
        case aggressive  // 5s  - When charging
        case normal      // 15s - Good battery
        case conservative // 30s - Medium battery
        case minimal     // 60s - Low battery
        case background  // 120s - App in background
    }
    
    func getCurrentStrategy() -> PollingStrategy {
        let batteryLevel = UIDevice.current.batteryLevel
        let batteryState = UIDevice.current.batteryState
        let appState = UIApplication.shared.applicationState
        
        // Background → minimal polling
        if appState == .background {
            return .background
        }
        
        // Charging → aggressive
        if batteryState == .charging || batteryState == .full {
            return .aggressive
        }
        
        // Battery-based
        switch batteryLevel {
        case 0..<0.2:
            return .minimal      // < 20% → 60s
        case 0.2..<0.5:
            return .conservative // 20-50% → 30s
        default:
            return .normal       // > 50% → 15s
        }
    }
    
    func getPollingInterval() -> TimeInterval {
        switch getCurrentStrategy() {
        case .aggressive:  return 5.0
        case .normal:      return 15.0
        case .conservative: return 30.0
        case .minimal:     return 60.0
        case .background:  return 120.0
        }
    }
}

// Usage in ChatsViewModel:
private func pollMessagesLoop() async {
    while isPolling && !Task.isCancelled {
        do {
            let messages = try await RestAPIClient.shared.pollMessages(...)
            await processMessages(messages)
            
            // ✅ Adaptive interval
            let interval = AdaptivePollingManager.shared.getPollingInterval()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            
        } catch {
            // Exponential backoff on errors
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
        }
    }
}
```

---

## 🎭 Phase 2: Privacy & Traffic Obfuscation (P1-P2)

### 2.1 Message Size Padding

**Problem:**
- Message size leaks information
- "Hi" vs "Meet me at the corner of 5th and Main at 3pm" → obviously different

**Solution:**

```rust
// Server-side: shared/src/construct_server/e2e.rs

const PADDING_SIZES: [usize; 6] = [
    128,    // Short messages (< 128 bytes)
    512,    // Medium messages
    2048,   // Long messages
    8192,   // Very long messages
    32768,  // Images metadata
    131072, // Large files metadata (128 KB)
];

pub fn pad_message(plaintext: &[u8]) -> Vec<u8> {
    let plaintext_len = plaintext.len();
    
    // Find next power-of-2 size bucket
    let target_size = PADDING_SIZES.iter()
        .find(|&&size| size >= plaintext_len)
        .copied()
        .unwrap_or(*PADDING_SIZES.last().unwrap());
    
    let mut padded = Vec::with_capacity(target_size);
    
    // Original message
    padded.extend_from_slice(plaintext);
    
    // Padding length (4 bytes, little-endian)
    let padding_len = target_size - plaintext_len - 4;
    padded.extend_from_slice(&(padding_len as u32).to_le_bytes());
    
    // Random padding
    let mut rng = rand::thread_rng();
    let padding: Vec<u8> = (0..padding_len).map(|_| rng.gen()).collect();
    padded.extend_from_slice(&padding);
    
    assert_eq!(padded.len(), target_size);
    padded
}

pub fn unpad_message(padded: &[u8]) -> Result<Vec<u8>> {
    if padded.len() < 4 {
        anyhow::bail!("Message too short to contain padding length");
    }
    
    // Extract padding length from last 4 bytes of original message section
    // (it's before the padding, after the actual message)
    let padding_len_pos = padded.len() - 4;
    let padding_len_bytes = &padded[padding_len_pos..padding_len_pos + 4];
    let padding_len = u32::from_le_bytes(padding_len_bytes.try_into()?) as usize;
    
    // Actual message length
    let message_len = padded.len() - padding_len - 4;
    
    Ok(padded[..message_len].to_vec())
}
```

**Client-side:** Padding/unpadding happens automatically in Rust core (construct-core)

**Privacy Gain:**
- ✅ Attacker cannot distinguish "Hi" from "Hello there"
- ✅ All messages in same bucket look identical (128, 512, 2048 bytes)
- ❌ Still leaks rough size category (short vs long)

---

### 2.2 Timing Obfuscation

**Problem:**
- Immediate message send → attacker knows user is online NOW
- Burst of messages → knows conversation is happening

**Solution: Random Delay Queue**

```swift
// TimingObfuscator.swift

class TimingObfuscator {
    private var queue: [Message] = []
    private var timer: Timer?
    
    private let minDelay: TimeInterval = 5.0  // 5 seconds
    private let maxDelay: TimeInterval = 30.0 // 30 seconds
    
    func enqueueMessage(_ message: Message, immediate: Bool = false) {
        if immediate {
            // User explicitly wants to send now (e.g., urgent message)
            Task {
                try? await RestAPIClient.shared.sendMessage(message)
            }
            return
        }
        
        queue.append(message)
        scheduleNextSend()
    }
    
    private func scheduleNextSend() {
        guard timer == nil else { return }
        
        // Random delay between min and max
        let delay = TimeInterval.random(in: minDelay...maxDelay)
        
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.flushQueue()
        }
    }
    
    private func flushQueue() {
        guard !queue.isEmpty else {
            timer = nil
            return
        }
        
        // Send all queued messages
        let messagesToSend = queue
        queue.removeAll()
        
        Task {
            for message in messagesToSend {
                try? await RestAPIClient.shared.sendMessage(message)
            }
        }
        
        timer = nil
    }
}
```

**UI Consideration:**
- Show "Sending in 15s..." with countdown
- Allow "Send Now" button for urgent messages

---

### 2.3 Dummy Traffic (Cover Traffic)

**Problem:**
- Long periods of silence → attacker knows user is inactive
- Burst after silence → knows conversation started

**Solution: Periodic Dummy Messages**

```swift
// DummyTrafficGenerator.swift

class DummyTrafficGenerator {
    private let dummyRecipientId = "00000000-0000-0000-0000-000000000000"
    private var timer: Timer?
    
    func start() {
        // Send dummy message every 60-120 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            self?.sendDummyMessage()
        }
    }
    
    private func sendDummyMessage() {
        let dummyContent = generateRandomBytes(count: Int.random(in: 100...500))
        
        // Server recognizes dummy recipient and discards
        Task {
            try? await RestAPIClient.shared.sendMessage(
                recipientId: dummyRecipientId,
                content: dummyContent.base64EncodedString(),
                isDummy: true  // Flag for server
            )
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
```

**Server-side:**

```rust
// In send_message handler
if message.recipient_id == "00000000-0000-0000-0000-000000000000" {
    // Dummy message - discard silently
    tracing::debug!("Discarding dummy message");
    return Ok(StatusCode::OK);
}

// Normal message processing
...
```

**Energy Trade-off:**
- ❌ Increases network usage by ~50-100 requests/hour
- ✅ Makes traffic analysis much harder
- **Recommendation:** Make it opt-in (Settings → Privacy → Cover Traffic)

---

## 🔌 Phase 3: WebSocket (Optional, P2)

### WebSocket Scaling Challenges & Solutions

**Your Concern:**
> "Мы отказались от WebSocket потому что с ним были сложности с масштабированием"

**Common WebSocket Scaling Issues:**

1. **Sticky Sessions** - User must connect to same server
2. **Memory Usage** - Each connection consumes memory
3. **Broadcasting** - Hard to send message to user connected to different server

**Solution: Redis Pub/Sub + Horizontal Scaling**

```
┌─────────┐         ┌──────────────┐         ┌─────────┐
│ User A  │◀───WS──▶│  Server 1    │◀───┐    │ User C  │
└─────────┘         └──────────────┘    │    └─────────┘
                           │             │         │
                           ▼             │         ▼
                    ┌─────────────┐      │  ┌──────────────┐
                    │ Redis Pub/  │◀─────┴─▶│  Server 2    │
                    │ Sub         │         └──────────────┘
                    └─────────────┘                │
                           ▲                       │
                           │                       ▼
                    ┌──────────────┐         ┌─────────┐
                    │  Server 3    │◀───WS──▶│ User B  │
                    └──────────────┘         └─────────┘
```

**How it works:**

```rust
// Server 1 receives message for User B
async fn send_message(msg: EncryptedMessage) -> Result<()> {
    // 1. Store in Redis Stream (persistence)
    redis.xadd("messages:user_b", &msg).await?;
    
    // 2. Publish to Redis Pub/Sub (real-time delivery)
    redis.publish("user:user_b:messages", &msg).await?;
    
    Ok(())
}

// Server 2 (where User B is connected) receives pub/sub notification
async fn handle_pubsub_message(channel: String, msg: Vec<u8>) {
    let user_id = extract_user_id(&channel); // "user_b"
    
    // Find WebSocket connection for this user
    if let Some(ws) = websocket_manager.get_connection(&user_id) {
        ws.send(msg).await?;
    }
}
```

**Advantages over Long-Polling:**
- ✅ Instant delivery (no 30s timeout wait)
- ✅ Less battery drain (1 connection vs many HTTP requests)
- ✅ Lower latency (<100ms vs 0-30s)

**Disadvantages:**
- ❌ More complex infrastructure
- ❌ Doesn't work through some corporate firewalls
- ❌ Requires load balancer with sticky sessions OR Redis Pub/Sub

**Gradual Rollout Strategy:**

```swift
// Client supports BOTH Long-Polling AND WebSocket

class ConnectionManager {
    enum TransportMode {
        case webSocket
        case longPolling
    }
    
    @AppStorage("preferredTransport") private var preferredTransport: String = "longPolling"
    
    func connect() async {
        // Try WebSocket first if enabled
        if preferredTransport == "webSocket" {
            do {
                try await connectWebSocket()
                currentMode = .webSocket
                Log.info("✅ Connected via WebSocket")
                return
            } catch {
                Log.warning("⚠️ WebSocket failed, falling back to long-polling")
            }
        }
        
        // Fallback to long-polling (always works)
        await startLongPolling()
        currentMode = .longPolling
    }
}
```

**Server Feature Flag:**

```rust
// config.toml
[features]
websocket_enabled = false  # Start with false (long-polling only)

# Later, enable for 10% of users (canary deployment)
websocket_rollout_percentage = 10
```

**Recommendation:**
- ✅ Keep long-polling as default (stable, works everywhere)
- ✅ Add WebSocket as opt-in beta feature (Settings → Advanced → Enable WebSocket)
- ✅ Monitor metrics (latency, battery, errors) for 2 weeks
- ✅ If successful, gradually increase rollout (10% → 50% → 100%)
- ✅ Always keep long-polling as fallback

---

## 📈 Metrics & Monitoring

### Key Metrics to Track

```swift
// MetricsCollector.swift

struct MessageMetrics {
    // Delivery
    var messageSentCount: Int = 0
    var messageDeliveredCount: Int = 0
    var messageFailedCount: Int = 0
    var averageDeliveryTime: TimeInterval = 0
    
    // Battery
    var pollingRequestsPerHour: Int = 0
    var pushNotificationsReceived: Int = 0
    var batteryLevelWhenStarted: Float = 0
    var batteryLevelNow: Float = 0
    
    // Errors
    var decryptionFailures: Int = 0
    var networkErrors: Int = 0
    var queuedMessagesCount: Int = 0
}

class MetricsCollector {
    static let shared = MetricsCollector()
    
    func recordMessageSent() {
        metrics.messageSentCount += 1
        sendToAnalytics("message_sent")
    }
    
    func recordDeliveryTime(_ duration: TimeInterval) {
        metrics.averageDeliveryTime = 
            (metrics.averageDeliveryTime + duration) / 2
        sendToAnalytics("delivery_time", value: duration)
    }
    
    private func sendToAnalytics(_ event: String, value: Double? = nil) {
        // Send to your analytics (anonymized!)
        // DO NOT send message content, user IDs, etc.
    }
}
```

---

## 🚀 Implementation Timeline

### Week 1-2: Foundation (P0)
- [ ] Implement Offline Queue
- [ ] Add message delivery states to Core Data
- [ ] Create exponential backoff retry logic
- [ ] UI indicators for message states

### Week 3-4: Push Notifications (P0)
- [ ] Server: APNs integration
- [ ] Server: Device token registration endpoint
- [ ] Client: Register for push notifications
- [ ] Client: Handle silent push → fetch messages
- [ ] Testing: Verify E2E encryption not broken

### Week 5-6: Optimization (P1)
- [ ] Adaptive polling intervals
- [ ] Battery monitoring
- [ ] Message size padding
- [ ] Metrics collection

### Week 7-10: Privacy Features (P2)
- [ ] Timing obfuscation
- [ ] Dummy traffic (opt-in)
- [ ] WebSocket (beta, opt-in)
- [ ] A/B testing framework

### Week 11-12: State Machine (P1)
- [ ] Migrate to explicit state machine
- [ ] Offline mode state
- [ ] Reconnection state with backoff
- [ ] Comprehensive state transition tests

---

## ✅ Success Criteria

### Stability
- ✅ 99.9% message delivery rate
- ✅ < 0.1% decryption failures
- ✅ Offline queue handles 100+ messages
- ✅ Auto-recovery from network failures

### Energy Efficiency
- ✅ 50% reduction in network requests
- ✅ < 2% battery drain per hour (idle)
- ✅ Push notifications working for 95%+ users

### Privacy
- ✅ Message sizes padded to buckets
- ✅ Timing obfuscation reduces correlation by 80%
- ✅ No plaintext in server logs
- ✅ No plaintext in push notifications

---

## 🔒 Security Considerations

### What NOT to include in Push Notifications
- ❌ Message content (even encrypted)
- ❌ Sender name or ID
- ❌ Message length
- ❌ Conversation ID

### What CAN be in Push
- ✅ Generic "New message" text
- ✅ Badge count (total unread)
- ✅ Sound/vibration

### Privacy-Preserving Analytics
```swift
// ✅ GOOD
analytics.log("message_sent", metadata: [
    "suiteId": 1,
    "messageSize": "512-2048",  // Bucket, not exact
    "deliveryTime": "< 1s"       // Range, not exact
])

// ❌ BAD
analytics.log("message_sent", metadata: [
    "userId": "abc123",          // NO!
    "recipientId": "def456",     // NO!
    "content": "encrypted...",   // NO!
    "messageId": "msg789"        // NO!
])
```

---

## 📚 References

- [APNs Best Practices](https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server)
- [Signal Protocol](https://signal.org/docs/)
- [WebSocket Scaling](https://www.nginx.com/blog/websocket-nginx/)
- [Traffic Analysis Resistance](https://arxiv.org/abs/2004.13646)
- [iOS Energy Efficiency](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/)

---

## 🤝 Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-01-24 | Use Long-Polling as primary transport | Stable, works everywhere, proven at scale |
| 2026-01-24 | Add WebSocket as opt-in beta | Better UX but complex infrastructure |
| 2026-01-24 | Prioritize APNs over polling optimization | 98% reduction in requests vs 50% |
| 2026-01-24 | Make dummy traffic opt-in | Significant battery impact, privacy-conscious users only |

---

**Next Review:** 2026-02-24 (1 month)
**Owner:** Engineering Team
**Stakeholders:** Product, Security, Infrastructure

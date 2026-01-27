# Construct Messenger: Stabilization Roadmap (Hybrid Approach)

**Date:** 2026-01-24  
**Strategy:** Make it work → Test it → Improve it  
**Timeline:** 2-4 weeks to stability

---

## Phase 1: GET IT WORKING (This Week)

### Current Status ✅
- [x] Server deployed with fixes (stream_id, rate limit)
- [x] Client compiled with fixes (session sync, backoff, lifecycle)
- [ ] End-to-end message delivery verified

### Critical Path Test (Do This NOW)

#### Test 1: Fresh Install Scenario
**Goal:** Verify basic messaging works

**Setup:**
1. Two physical devices (or simulator + device)
2. Latest app build with all fixes
3. Clean install (delete app first)

**Steps:**
```
Device A (Simulator or iPhone 1):
1. Open app
2. Register new account: testuser_a_[timestamp]
3. Go to Settings → copy contact link
4. Send link to Device B (Messages, Email, etc.)

Device B (Physical iPhone):
1. Open app  
2. Register new account: testuser_b_[timestamp]
3. Scan QR code or paste contact link from Device A
4. Wait for chat to open
5. Type "Hello from B" → Send
6. Check Device A for message

Device A:
7. Should see "Hello from B" appear
8. Reply "Hello from A" → Send
9. Check Device B for reply

Expected Success:
✅ Messages appear within 30 seconds
✅ No "Decryption failed" errors
✅ Both users see each other's messages
```

**Log Collection:**
```
Device A - Xcode Console:
- Search for: "Poll response"
- Search for: "Decryption"
- Search for: "Session"

Device B - Device Console (if physical):
- Connect to Mac → Window → Devices and Simulators
- Select device → View Device Logs
- Filter by "ConstructMessenger"

Server Logs:
- fly logs -a messaging-service
- Look for user_hash of both users
- Check for "Successfully read X messages"
```

---

#### Test 2: Existing Chat Scenario
**Goal:** Verify session recovery works

**Setup:**
1. Use accounts from Test 1
2. Don't delete app

**Steps:**
```
1. Force quit app on both devices
2. Wait 2 minutes
3. Reopen app on Device A
4. Send "Test after restart" to Device B
5. Check Device B receives it

Expected:
✅ lastMessageId restored from UserDefaults
✅ Only NEW message fetched (not all history)
✅ Message decrypts successfully
```

---

#### Test 3: Session Desync Recovery
**Goal:** Verify session reinitialization works

**Setup:**
1. Have working chat from Test 1
2. One device only

**Steps:**
```
Device A:
1. Settings → Advanced → Delete All Sessions (if implemented)
   OR: Delete app → Reinstall → Login with SAME account
2. Open chat with Device B
3. Send "After session reset"

Device B:
4. Should receive message after ~2 seconds
5. Check logs for "Deleting corrupted session"
6. Check logs for "Receiving session initialized"

Expected:
✅ First message fails to decrypt
✅ Session auto-deleted
✅ Public key fetched
✅ New session initialized
✅ Message appears after reinitialization
```

---

### Debug Decision Tree

```
Test 1 Failed?
├─ No messages appear
│  ├─ Check: Server logs show "Successfully read X messages"?
│  │  ├─ NO → Server issue (Redis stream not working)
│  │  └─ YES → Client polling issue
│  └─ Check: Client logs show "Poll response: X messages"?
│     ├─ NO → Long-polling timeout or auth issue
│     └─ YES → Continue to next check
│
├─ Messages appear but "Decryption failed"
│  ├─ Check: "Existing session found - deleting before init"?
│  │  ├─ YES → Good, fix is working
│  │  └─ NO → Session sync fix not applied
│  └─ Check: "Receiving session initialized"?
│     ├─ YES → Should decrypt after this
│     └─ NO → Public key fetch failed
│
└─ Connection status shows "Connecting"
   └─ Check: Last successful request timestamp
      ├─ Within 2 min → Grace period working (normal)
      └─ > 2 min ago → Server unreachable
```

---

## Phase 2: ADD MINIMAL TESTS (Week 2)

### Test Infrastructure (Choose One)

#### Option A: Shell Script Test (Simplest)
```bash
#!/bin/bash
# test_e2e.sh

echo "🧪 E2E Message Test"

# Register User A
echo "Registering User A..."
USER_A=$(curl -X POST https://ams.konstruct.cc/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test_a","password":"test123","keyBundle":{...}}')

# Register User B
echo "Registering User B..."
USER_B=$(curl -X POST https://ams.konstruct.cc/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test_b","password":"test123","keyBundle":{...}}')

# User A sends message to User B
echo "Sending message..."
curl -X POST https://ams.konstruct.cc/api/v1/messages \
  -H "Authorization: Bearer $TOKEN_A" \
  -d '{"to":"user_b_id","content":"...encrypted..."}'

# User B polls for messages
echo "Polling for message..."
RESPONSE=$(curl https://ams.konstruct.cc/api/v1/messages \
  -H "Authorization: Bearer $TOKEN_B")

# Check if message received
if echo "$RESPONSE" | grep -q "messages"; then
  echo "✅ TEST PASSED"
  exit 0
else
  echo "❌ TEST FAILED"
  exit 1
fi
```

**Run before every deploy:**
```bash
./test_e2e.sh && deploy.sh || echo "Tests failed, deploy cancelled"
```

---

#### Option B: Rust Integration Test (Better)
```rust
// messaging-service/tests/integration_test.rs

#[tokio::test]
async fn test_message_delivery() {
    // 1. Setup test users
    let user_a = create_test_user("test_a").await;
    let user_b = create_test_user("test_b").await;
    
    // 2. User A sends message
    let message = send_message(&user_a, &user_b, "Hello").await;
    assert!(message.is_ok());
    
    // 3. User B polls
    let messages = poll_messages(&user_b).await.unwrap();
    
    // 4. Verify message received
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].from, user_a.id);
}
```

**Run with:**
```bash
cargo test --test integration_test
```

---

#### Option C: iOS XCTest (Most Complete)
```swift
// ConstructMessengerTests/MessagingE2ETests.swift

func testMessageDelivery() async throws {
    // 1. Create two users
    let userA = try await createTestUser("test_a")
    let userB = try await createTestUser("test_b")
    
    // 2. Initialize sessions
    try await userA.initializeSession(with: userB)
    
    // 3. Send message
    try await userA.sendMessage("Hello", to: userB)
    
    // 4. Poll for message
    let messages = try await userB.pollMessages()
    
    // 5. Verify
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages[0].decryptedContent, "Hello")
}
```

---

### Monitoring Setup (Week 2)

**Add structured logging:**
```rust
// In messaging-service

use tracing_subscriber::fmt::format::FmtSpan;

tracing_subscriber::fmt()
    .json() // JSON output for log aggregation
    .with_span_events(FmtSpan::CLOSE)
    .init();

// In every request:
tracing::info!(
    user_hash = %user_hash,
    message_id = %message_id,
    latency_ms = ?start.elapsed().as_millis(),
    "Message delivered"
);
```

**Simple dashboard (Grafana):**
```
Metrics to track:
- Messages sent per hour
- Messages delivered per hour
- Delivery latency (p50, p95, p99)
- Decryption failures per hour
- Session reinitializations per hour
```

---

## Phase 3: IMPROVE (Week 3-4)

### Priority Improvements

1. **Health Check Endpoint**
```rust
// GET /health
async fn health_check(
    State(state): State<AppState>,
) -> Result<Json<HealthResponse>, AppError> {
    // Check Redis
    let redis_ok = state.redis.ping().await.is_ok();
    
    // Check DB
    let db_ok = sqlx::query("SELECT 1")
        .fetch_one(&state.db_pool)
        .await.is_ok();
    
    // Check Kafka
    let kafka_ok = state.kafka.metadata().await.is_ok();
    
    Ok(Json(HealthResponse {
        status: if redis_ok && db_ok && kafka_ok { "healthy" } else { "unhealthy" },
        redis: redis_ok,
        database: db_ok,
        kafka: kafka_ok,
    }))
}
```

2. **Message Tracing**
```rust
// Add trace_id to every message
struct ChatMessage {
    id: String,
    trace_id: String,  // NEW: follows message through system
    // ...
}

// Log with trace_id at every step:
// Client → Gateway → Kafka → Redis → Delivery
```

3. **Automatic Session Recovery**
```swift
// In CryptoManager.swift
func decryptMessage(_ message: ChatMessage) throws -> String {
    do {
        return try core.decryptMessage(...)
    } catch {
        // Auto-recover
        Log.info("⚡ Auto-recovering session for \(message.from)")
        try autoRecoverSession(for: message.from, firstMessage: message)
        
        // Retry decrypt
        return try core.decryptMessage(...)
    }
}
```

4. **Fix APNs Push Notification**
```rust
// messaging_service/handlers.rs
let tokens: Vec<DeviceTokenRow> = sqlx::query_as!(
    DeviceTokenRow,
    "SELECT device_token_encrypted, user_id 
     FROM device_tokens 
     WHERE user_id = $1 AND enabled = true",
    recipient_id
)
.fetch_all(&context.db_pool)
.await?;

// Decrypt tokens
for row in tokens {
    let token = decrypt_device_token(&row.device_token_encrypted)?;
    // Send push...
}
```

---

## Success Metrics

### Week 1 Target:
- ✅ 3/3 manual tests pass
- ✅ Can send/receive messages reliably
- ✅ Session desync auto-recovers

### Week 2 Target:
- ✅ 1 automated test running
- ✅ Basic logging in place
- ✅ Deploy script with test gate

### Week 3-4 Target:
- ✅ Health endpoint responding
- ✅ APNs push working
- ✅ 95%+ message delivery rate

---

## Next Steps (Immediate)

### 1. Run Test 1 (Fresh Install)
- Do it now with latest builds
- Document exact results
- Share logs if fails

### 2. Create Simple Deploy Script
```bash
#!/bin/bash
# deploy.sh

set -e

echo "Building..."
cargo build --release -p messaging-service

echo "Deploying to Fly.io..."
fly deploy -c messaging-service/fly.toml

echo "Checking health..."
sleep 5
curl https://ams.konstruct.cc/health || echo "Warning: Health check failed"

echo "✅ Deploy complete"
```

### 3. Start Issue Tracking
Create GitHub issues for:
- [ ] #1: Add health check endpoint
- [ ] #2: Add first integration test
- [ ] #3: Fix APNs device token encryption
- [ ] #4: Add structured logging

---

## When Things Break (They Will)

### Debug Protocol:
1. **Check health endpoint** (once added)
2. **Check server logs** (`fly logs`)
3. **Check client logs** (Xcode console)
4. **Check recent deploys** (`fly releases`)
5. **Rollback if needed** (`fly deploy --image <previous>`)

### Communication:
- Document every bug in GitHub Issues
- Include logs, steps to reproduce
- Tag with priority (P0=broken, P1=important, P2=nice)

---

## Long-Term Vision (After Stability)

Once messaging works reliably:
1. **Add MLS for group chats** (3-4 weeks)
2. **Add web client** (2-3 weeks)
3. **Optimize for scale** (ongoing)
4. **Add advanced features** (read receipts, typing indicators)

But FIRST: Make 1-to-1 messaging bulletproof.

---

**Your immediate task: Run Test 1 and report results.**

If it works → celebrate and move to Test 2  
If it fails → share logs and we debug together

Deal? 🚀

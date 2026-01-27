# Message Delivery Failure: Decryption Issue

**Date:** 2026-01-24  
**Status:** 🔴 CRITICAL - Messages not displaying  
**Root Cause:** Session desynchronization between sender and receiver

---

## Symptom Analysis

### What We See in Logs

**Server (messaging-service):**
```
✅ Message persisted to Kafka partition=0 offset=38
✅ Message sent successfully sender_hash=dcde0b0f recipient_hash=3ff70210
✅ Successfully read 1 messages from Redis stream for user user_hash=3ff70210
```

**Client (iOS - Recipient):**
```
✅ Received 1 messages
❌ Decryption failed (CryptoException.decryptionFailed)
🔄 Deleting corrupted session for af70cf9a-b176-4df3-b6bf-00196a6f173e
🔄 Requesting reinitialization...
✅ Response status: 200 from /users/af70cf9a-b176-4df3-b6bf-00196a6f173e/public-key
❓ But message still not displayed
```

### Flow Breakdown

```
1. User A sends message to User B
   ├─ A has sending session initialized
   ├─ Message encrypted with A's session state
   └─ Message sent to server ✅

2. Server stores & forwards message
   ├─ Kafka: persisted ✅
   ├─ Redis Stream: added ✅
   └─ B polls and receives encrypted message ✅

3. User B tries to decrypt
   ├─ B checks hasSession() → TRUE (has old/corrupted session)
   ├─ Tries to decrypt with existing session
   ├─ FAILS: "Decryption failed" ❌
   ├─ Auto-deletes corrupted session
   ├─ Fetches fresh public key bundle
   └─ Initializes NEW receiving session
   
4. Problem: First message lost
   ├─ initReceivingSession() requires the FIRST encrypted message
   ├─ But we already tried to decrypt it (failed)
   └─ Message is not re-processed after reinitialization ❌
```

---

## Root Causes

### 1. **Session State Mismatch**
```
Sender (A):                      Receiver (B):
├─ initSendingSession()         ├─ Has OLD/CORRUPTED session
├─ messageNumber = 0            ├─ Expected messageNumber ≠ 0
├─ Encrypts with NEW session    ├─ Tries to decrypt with OLD session
└─ Sends message                └─ FAILS
```

**Why this happens:**
- User A reinstalls app → new session created
- User B still has old session in Keychain
- Message numbers don't match → decryption fails

### 2. **Pending Message Not Reprocessed**

**Code: `ChatsViewModel.swift:557-576`**
```swift
} else {
    guard let content = try? CryptoManager.shared.decryptMessage(message) else {
        Log.error("❌ Failed to decrypt incoming message")
        
        // Request fresh public key
        Task {
            let publicKeyBundle = try await RestAPIClient.shared.getPublicKey(userId: otherUserId)
            await MainActor.run {
                self.handlePublicKeyBundleForIncomingMessage(publicKeyBundle, message: message, otherUserId: otherUserId)
                //                                                             ^^^^^^^^ Message passed! ✅
            }
        }
        return  // ❌ Exits early - no retry after reinitialization
    }
}
```

**Actually this IS correct!** The `message` is passed to `handlePublicKeyBundleForIncomingMessage()`.

But let's check if the reinitialization works...

### 3. **initReceivingSession() vs Corrupted Session**

**Code: `ChatsViewModel.swift:671-675`**
```swift
let decryptedContent = try CryptoManager.shared.initReceivingSession(
    for: data.userId,
    recipientBundle: bundleWithSuite,
    firstMessage: message  // ← This is the FIRST message after init
)
```

**Problem:** `initReceivingSession()` expects:
- A fresh session (no existing session)
- The FIRST encrypted message from sender

But if sender already sent multiple messages:
- Message 1: Encrypted with messageNumber=0
- Message 2: Encrypted with messageNumber=1
- ...

If we reinitialize with Message 2 (messageNumber=1), it will FAIL because session expects messageNumber=0.

---

## The Real Problem: Double Ratchet Desync

### Double Ratchet Algorithm Requirement
```
Sender:                          Receiver:
message_number = 0 → encrypt →   decrypt with session expecting message_number = 0 ✅
message_number = 1 → encrypt →   decrypt with session state updated to 1 ✅
message_number = 2 → encrypt →   decrypt with session state updated to 2 ✅
```

**If receiver reinitializes:**
```
Sender continues:                Receiver reinitializes:
message_number = 3 → encrypt →   initReceivingSession expects message_number = 0 ❌
                                 MISMATCH → decryption fails
```

---

## Solutions

### Option 1: Force Both Sides to Reinitialize (Recommended)

**When decryption fails:**
1. Receiver deletes session ✅ (already done)
2. **NEW:** Receiver sends "Session Reset Request" to sender
3. Sender deletes their session
4. Sender re-fetches receiver's public key
5. Sender re-encrypts pending messages with NEW session
6. Both sides now in sync

**Implementation:**
```swift
// In ChatsViewModel.swift after session delete
} else {
    guard let content = try? CryptoManager.shared.decryptMessage(message) else {
        Log.error("❌ Failed to decrypt - sending session reset signal")
        
        // ✅ Send special control message to trigger sender's session reset
        Task {
            try? await RestAPIClient.shared.sendSessionResetRequest(to: otherUserId)
        }
        
        // Delete our session
        // Fetch fresh bundle
        // Wait for sender to resend with new session
    }
}
```

### Option 2: Out-of-Order Message Handling

**Use message header to detect desync:**
```swift
// Check if message number is unexpected
if expectedMessageNumber != receivedMessageNumber {
    // Session desync detected
    Log.warning("⚠️ Message number mismatch: expected \(expected), got \(received)")
    
    // Request session reset from sender
    // OR: Buffer out-of-order messages and request missing ones
}
```

### Option 3: Session Version Tracking (Best Long-Term)

**Add session version to messages:**
```
Message format:
{
    sessionVersion: "v2-1706116800",  // New field
    messageNumber: 5,
    encryptedContent: "..."
}
```

**Receiver checks:**
```swift
if message.sessionVersion != currentSessionVersion {
    // Different session - reinitialize
    // Sender and receiver can detect mismatches immediately
}
```

---

## Immediate Fix (Quick & Dirty)

### Problem Right Now
Receiver has corrupted session. When first message arrives:
1. hasSession() returns TRUE (corrupted session exists)
2. Decryption fails
3. Session deleted
4. Public key fetched
5. `initReceivingSession()` called with the message
6. **But sender's session state is ahead** → still fails

### Workaround
**Tell both users to delete the chat and start fresh:**
1. User A: Delete chat with User B
2. User B: Delete chat with User A
3. Both: Clear all sessions from Keychain
4. Start new chat
5. First message will initialize clean sessions

### Code Fix: Retry with Empty Session

```swift
// In CryptoManager.swift - initReceivingSession()
func initReceivingSession(...) throws -> String {
    // Before calling Rust core, verify no existing session
    if userSessions[contactId] != nil {
        Log.warning("⚠️ Deleting existing session before reinit")
        try? deleteSession(for: contactId)
    }
    
    // Now initialize fresh
    let sessionId = try core.initReceivingSession(...)
    // ...
}
```

---

## Debugging Steps

### Step 1: Check Current Session State

**Add logging in CryptoManager.swift:**
```swift
func hasSession(for userId: String) -> Bool {
    let has = userSessions[userId] != nil
    let state = has ? "EXISTS" : "MISSING"
    Log.debug("🔑 Session check for \(userId): \(state)", category: "CryptoManager")
    if has, let sessionId = userSessions[userId] {
        Log.debug("   Session ID: \(sessionId)", category: "CryptoManager")
    }
    return has
}
```

### Step 2: Log Message Numbers

**Add to decryptMessage():**
```swift
func decryptMessage(_ message: ChatMessage) throws -> String {
    Log.debug("🔓 Decrypting message \(message.id) with messageNumber=\(message.messageNumber)", category: "CryptoManager")
    // ...
}
```

### Step 3: Test Session Sync

**Manual test:**
1. User A sends message → Check logs for messageNumber
2. User B receives → Check logs for expected messageNumber
3. If mismatch → session desync confirmed

---

## Server-Side Check

**Also verify device_token issue is not blocking:**
```
WARN Failed to send push notification (non-fatal)
error=column "device_token" does not exist
```

This is the **APNs push bug** we identified earlier. It's non-fatal but should be fixed:

**File:** `shared/src/construct_server/messaging_service/handlers.rs`

Need to change:
```rust
// ❌ Current:
SELECT device_token FROM device_tokens WHERE user_id = $1

// ✅ Should be:
SELECT device_token_encrypted FROM device_tokens WHERE user_id = $1 AND enabled = true
```

---

## Action Plan

### Immediate (Next 30 min):
1. **Manual workaround:**
   - Both users delete chat
   - Clear Keychain sessions (Settings → Reset Keychain)
   - Start fresh chat
   - Test if messages work

2. **Add debug logging:**
   - Session state checks
   - Message numbers
   - Verify sync

### Short-term (Next session):
3. **Fix initReceivingSession:**
   - Force delete existing session before reinit
   - Better error messages
   
4. **Fix server APNs:**
   - Query device_token_encrypted
   - Use 'enabled' not 'is_active'

### Long-term (Future):
5. **Session reset protocol:**
   - Control message for "session reset needed"
   - Both sides reinitialize
   
6. **Session versioning:**
   - Add sessionVersion to messages
   - Detect mismatches early

---

**MOST LIKELY ROOT CAUSE:**  
One user reinstalled app or cleared data → created new session → other user's session is now out of sync → all messages fail to decrypt.

**QUICKEST FIX:**  
Both users delete the chat and start fresh.

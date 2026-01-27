# UI Update Issue - Quick Fix

**Date:** 2026-01-24  
**Issue:** Spinner stays forever, message doesn't appear in UI

---

## Quick Diagnosis

### Check iOS Logs For:

1. **Message received?**
   ```
   📥 Poll response: X messages  ← Should be > 0
   ```

2. **Message decrypted?**
   ```
   ✅ Message decrypted (messageNumber: X)  ← Must see this
   ```

3. **Message saved?**
   ```
   ✅ Chat saved successfully  ← Must see this
   ```

**If all 3 present → UI binding issue**  
**If missing any → earlier problem**

---

## Most Likely Cause: Sender UI Not Updating

**File:** `ChatViewModel.swift`

The message is sent to server, but **sender's UI** doesn't update status from "sending" to "sent".

**Quick fix - add after successful send:**

```swift
// After: try await RestAPIClient.shared.sendChatMessage(message)

// ✅ Force UI update
await MainActor.run {
    // Reload message from Core Data to get saved state
    context.refresh(dbMessage, mergeChanges: true)
    
    // Force SwiftUI refresh
    self.objectWillChange.send()
}
```

---

## Deploy Server Fix First

```bash
cd ~/Code/construct-server
cargo build --release -p messaging-service
fly deploy -c messaging-service/fly.toml
```

This will fix the APNs error (now gracefully skipped instead of crashing).

---

## Then Test Again

1. Send message
2. Check logs
3. Report what you see

**Share this from iOS console:**
- Lines with "📥 Poll response"
- Lines with "🔓 Decrypting"  
- Lines with "✅ Chat saved"
- Any "❌" errors

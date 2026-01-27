# Bug Fix: Connection Status Flickering

**Date:** 2026-01-24  
**Issue:** Connection indicator constantly showing "Connecting" (orange) instead of staying "Connected" (green)

---

## Problem

User reports seeing "Connecting..." status and orange indicator **too frequently**, even when connection is working fine.

### Root Causes

#### 1. **Every failed request changes status to "Connecting"** ❌
```swift
// ConnectionStatusManager.swift (OLD)
if self.connectionStatus == .connected {
    self.connectionStatus = .connecting  // Changes on ANY error!
}
```

**Impact:**
- Long-polling timeout (normal behavior) → "Connecting"
- Temporary network glitch → "Connecting"
- Server returns 204 No Content → "Connecting" (if treated as error)
- Status flickers constantly between green and orange

#### 2. **Long-polling timeout treated as error** ❌
```swift
// RestAPIClient.swift (OLD)
case .timedOut:
    // Try next server ← WRONG for long-polling!
    lastError = urlError
    continue
```

**Long-polling design:**
- Client: `GET /messages?timeout=30` → waits 30 seconds
- Server: If no messages, **timeout is expected**
- Client was treating timeout as connection failure

#### 3. **No grace period for temporary issues** ❌
One failed request immediately changes status, even if:
- Previous request succeeded 5 seconds ago
- Network is still reachable
- Server is actually fine (just temporary hiccup)

---

## Solution

### Fix 1: Add Grace Period for Status Changes ✅

**File:** `ConnectionStatusManager.swift`

```swift
func markRequestFailed(error: String? = nil, isCritical: Bool = false) {
    // Only mark as disconnected if network is unreachable
    if !self.reachabilityManager.isReachable {
        self.connectionStatus = .disconnected
    } else if isCritical {
        // Critical errors (auth failures, etc.) change status immediately
        if self.connectionStatus == .connected {
            self.connectionStatus = .connecting
        }
    } else {
        // Non-critical errors: Stay "Connected" if had success in last 2 minutes
        // Prevents flickering on temporary network hiccups
        if self.connectionStatus == .connected {
            let gracePeriod: TimeInterval = 120  // 2 minutes
            if !self.isConnectionStale(threshold: gracePeriod) {
                // Had successful request recently - stay connected
                return
            } else {
                // No successful request in 2 minutes - mark as connecting
                self.connectionStatus = .connecting
            }
        }
    }
}
```

**Benefits:**
- Stay "Connected" if last success was within 2 minutes
- Prevents flickering from temporary errors
- Only critical failures (all servers down, auth failed) change status immediately

### Fix 2: Long-Polling Timeout is NOT an Error ✅

**File:** `RestAPIClient.swift`

```swift
catch let urlError as URLError {
    // ✅ SPECIAL CASE: Long-polling timeout is NORMAL, not an error
    if isLongPolling && urlError.code == .timedOut {
        Log.debug("⏱️ Long-polling timeout (normal) - no new messages")
        // Mark as successful connection
        connectionStatusManager.markRequestSucceeded()
        // Return empty response
        return PollMessagesResponse(messages: [], nextSince: nil, hasMore: false)
    }
    
    // Regular timeout handling for non-long-polling requests
    switch urlError.code {
    case .timedOut:
        // Try next server...
```

**Benefits:**
- Long-polling timeout → marks as **successful**
- Status stays "Connected" (green indicator)
- No unnecessary server fallback attempts

### Fix 3: Distinguish Critical vs Non-Critical Errors ✅

**File:** `RestAPIClient.swift`

```swift
// Critical failure: All servers unreachable
connectionStatusManager.markRequestFailed(
    error: "Failed to connect to server", 
    isCritical: true  // ← Immediate status change
)
```

**Error Categories:**

| Type | isCritical | Behavior |
|------|-----------|----------|
| All servers down | ✅ Yes | Immediate "Connecting" status |
| Auth 401 | ✅ Yes | Immediate "Connecting" + session clear |
| Single server timeout | ❌ No | Stay "Connected" if recent success |
| Long-polling timeout | N/A | Mark as **success** |
| Temporary network glitch | ❌ No | Stay "Connected" if recent success |

---

## Expected Behavior After Fix

### Scenario 1: Normal Long-Polling
```
1. User opens app → Status: "Connecting..."
2. First request succeeds → Status: "Connected" ✅
3. Long-polling timeout (30s) → Status: "Connected" ✅ (stays green!)
4. Next request → Status: "Connected" ✅
```

### Scenario 2: Temporary Network Glitch
```
1. User has active session → Status: "Connected"
2. WiFi hiccup for 5 seconds → Status: "Connected" ✅ (grace period)
3. Next request succeeds → Status: "Connected" ✅
```

### Scenario 3: Actual Connection Loss
```
1. User loses internet → Status: "Disconnected" ❌ (reachability check)
2. Internet back → Status: "Connecting..." ⏳
3. First successful request → Status: "Connected" ✅
```

### Scenario 4: Server Maintenance
```
1. All servers down for 3 minutes
2. Last success > 2 minutes ago
3. Grace period expired → Status: "Connecting..." ⏳
4. Server back online → Status: "Connected" ✅
```

---

## Testing

### Manual Test 1: Long-Polling Timeout
**Steps:**
1. Open app and login
2. Let app sit idle for 2 minutes (no messages)
3. Observe status indicator

**Before:** 🟠 Flickering orange "Connecting..."  
**After:** 🟢 Stays green "Connected"

### Manual Test 2: Network Hiccup
**Steps:**
1. Open app and login (status = Connected)
2. Turn off WiFi for 3 seconds
3. Turn WiFi back on
4. Observe status

**Before:** 🟠 Changes to "Connecting" and stays orange  
**After:** 🟢 Briefly "Disconnected", then quickly back to "Connected"

### Manual Test 3: Server Unreachable
**Steps:**
1. Open app
2. Put device in airplane mode
3. Try to login

**Expected:** 🔴 Shows "Disconnected" immediately (reachability check)

### Logs to Verify

#### Success (normal operation):
```
📡 State change: token=present, status=Connected, push=true
⏱️ Long-polling timeout (normal) - no new messages
🟢 Connection status: Connected
```

#### Temporary error (within grace period):
```
⚠️ Non-critical error, but staying Connected (last success was recent)
```

#### Critical failure:
```
🔴 Connection status changed: Connected -> Connecting
   Error: Failed to connect to server
```

---

## Performance Impact

### Before:
```
Every 30s: Long-polling timeout
→ Status changes to "Connecting"
→ UI updates (orange indicator)
→ User sees flickering
→ May trigger unnecessary retries
```

### After:
```
Every 30s: Long-polling timeout
→ Treated as success
→ Status stays "Connected"
→ UI stable (green indicator)
→ No unnecessary retries
```

**CPU/Battery Impact:**
- ✅ Reduced UI updates (no constant status changes)
- ✅ Fewer unnecessary logging calls
- ✅ Better UX (no visual flickering)

---

## Files Modified

```
ConstructMessenger/Networking/ConnectionStatusManager.swift
├── markRequestFailed(): Added isCritical parameter
├── Added 2-minute grace period for non-critical errors
└── Stay "Connected" if recent success exists

ConstructMessenger/Networking/RestAPIClient.swift
├── Long-polling timeout handling: Return empty response (not error)
├── Mark long-polling timeout as SUCCESS
└── Pass isCritical=true for all-servers-failed case
```

---

## Related Issues

**Server Side:**
- Rate limit was 1 req/sec → Fixed to 100 req/min
- Invalid stream ID errors → Fixed to use stream_id

**Client Side:**
- This fix: Connection status flickering
- Username restoration bug (already fixed)

**Future Work:**
- Implement exponential backoff for reconnection attempts
- Add State Machine for more robust connection management
- Consider heartbeat mechanism separate from long-polling

---

**Status:** ✅ FIXED  
**Priority:** High (UX improvement)  
**Testing:** Manual testing required on device

# Message Bug Fixes

**Date:** 2026-01-26  
**Issues Fixed:**
1. Messages showing "Encrypted" instead of decrypted text
2. Deleted messages reappearing after app restart

---

## Issue 1: "Encrypted" Text in Messages

### Problem

Messages were displaying "Encrypted" instead of actual decrypted content when:
- App received message in background
- User then opened the chat

### Root Cause

**Background fetch** saved messages with `decryptedContent = nil` when session didn't exist yet:

```swift
// BackgroundFetchManager.swift:326
if CryptoManager.shared.hasSession(for: otherUserId) {
    decryptedContent = try CryptoManager.shared.decryptMessage(messageData)
} else {
    // ⚠️ Message saved with decryptedContent = nil
    Log.info("⚠️ No session for user, message will be decrypted later")
}

// Message saved with nil decryptedContent
message.decryptedContent = decryptedContent  // nil!
```

**Then ChatsViewModel** checked "already exists?" and **didn't update**:

```swift
// ChatsViewModel.swift:869 (OLD)
if (try? context.fetch(fetchRequest).first) != nil {
    return // ❌ Already exists - SKIP UPDATE
}
```

### Fix

**File:** `ConstructMessenger/ViewModels/ChatsViewModel.swift`

**Changed `saveMessage()` to update existing messages:**

```swift
if let existingMessage = try? context.fetch(fetchRequest).first {
    // ✅ Update decryptedContent if it's nil
    if existingMessage.decryptedContent == nil {
        Log.debug("🔄 Updating decrypted content for message")
        existingMessage.decryptedContent = decryptedContent
        try context.save()
    }
    return
}
```

**Result:** Messages decrypted when user opens chat, even if background fetch saved them encrypted.

---

## Issue 2: Deleted Messages Reappearing

### Problem

Deleted messages returned after:
- Exiting and reopening app
- Navigating away and back to chat

### Root Cause

**Race condition between deletion and reload:**

1. User deletes message
2. Code removes from `messages` array (line 335, OLD)
3. Code deletes from Core Data (line 337)
4. Code saves context (line 340)
5. **BUT** `NSManagedObjectContextObjectsDidChange` triggers (line 78)
6. Triggers `reloadMessages()` (line 81)
7. Reloads ALL messages from DB **before deletion saved**
8. Deleted message comes back! ❌

**OLD Code:**
```swift
// 1. Remove from array FIRST
messages.removeAll { $0.id == messageId }

// 2. Delete from context
viewContext.delete(message)

// 3. Save
try viewContext.save()  // ⚠️ Too late! Already reloaded
```

### Fix

**File:** `ConstructMessenger/ViewModels/ChatViewModel.swift`

**Changed order: Save FIRST, then update array:**

```swift
// ✅ 1. Delete from Core Data FIRST
viewContext.delete(message)

// ✅ 2. Process pending changes
viewContext.processPendingChanges()

// ✅ 3. Save immediately
try viewContext.save()

// ✅ 4. Sync parent context (if nested)
if let parent = viewContext.parent {
    parent.performAndWait {
        try? parent.save()
    }
}

// ✅ 5. THEN remove from array
messages.removeAll { $0.id == messageId }
```

**Added logging:**
```swift
Log.debug("🗑️ Deleting message: \(messageId)")
Log.info("✅ Message deleted from Core Data: \(messageId)")
Log.debug("🔄 Reloading messages: DB has \(count), current array has \(count)")
```

**Result:** 
- Deletion persists to Core Data before UI updates
- Parent context synced (for nested contexts)
- `reloadMessages()` doesn't resurrect deleted messages

---

## Testing

### Test "Encrypted" Fix:

1. Send message from device A to device B while B is **closed**
2. Open device B (background fetch runs)
3. Open chat with device A
4. **Expected:** Message shows decrypted text ✅
5. **Before:** Message showed "Encrypted" ❌

### Test Deletion Fix:

1. Delete a message in chat
2. Exit app completely
3. Reopen app
4. Open same chat
5. **Expected:** Message stays deleted ✅
6. **Before:** Message reappeared ❌

---

## Files Modified

1. **ChatsViewModel.swift** (Lines 863-903)
   - `saveMessage()` - Update existing messages with nil decryptedContent

2. **ChatViewModel.swift** (Lines 320-409)
   - `deleteMessage()` - Save before updating array, sync parent context
   - `deleteMessages()` - Same fix for batch deletion
   - `reloadMessages()` - Added logging

---

## Technical Notes

### Core Data Context Hierarchy

App uses **nested contexts**:
```
PersistentContainer
  └─ viewContext (main queue)
       └─ backgroundContext (for background fetch)
```

**Important:** Changes in child context don't propagate to parent until:
```swift
child.save()
parent.performAndWait {
    try? parent.save()
}
```

### NSManagedObjectContextObjectsDidChange

Fires whenever objects change in context, including:
- Insert
- Update
- Delete

**Timing:** Fires **immediately** after `delete()`, **before** `save()`

**Solution:** Process deletion fully before triggering reload

---

## Related Issues

- [x] Messages showing "Encrypted"
- [x] Deleted messages reappearing
- [x] Background fetch not decrypting
- [x] Core Data sync issues

---

**Status:** ✅ Fixed and tested

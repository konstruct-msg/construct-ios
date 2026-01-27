# Multi-Account Support Implementation

**Date:** 2026-01-26  
**Issue:** Users can see other users' chats after logout/login - **CRITICAL SECURITY BUG**  
**Solution:** Add `ownerId` field to filter data by logged-in user

---

## Changes Made

### 1. ✅ Core Data Model Updated

**File:** `ConstructMessenger.xcdatamodel/contents`

**Added `ownerId` field to:**
- `Chat` entity
- `Message` entity  
- `User` entity

**Migration:** Automatic lightweight migration enabled (already configured)

---

### 2. ✅ Extension Helpers Created

**File:** `Models/CoreData/MultiAccountExtensions.swift`

**New methods:**

```swift
// Fetch only current user's data
Chat.fetchRequestForCurrentUser()
Message.fetchRequestForCurrentUser()
User.fetchRequestForCurrentUser()

// Set owner when creating
chat.setOwnerToCurrentUser()
message.setOwnerToCurrentUser()
user.setOwnerToCurrentUser()
```

---

## Migration Guide

### Step 1: Update ALL Fetch Requests

**FIND:**
```swift
let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
```

**REPLACE WITH:**
```swift
let fetchRequest = Chat.fetchRequestForCurrentUser()
```

**Same for Message and User!**

---

### Step 2: Set Owner When Creating Objects

**When creating Chat:**
```swift
let chat = Chat(context: context)
chat.id = UUID().uuidString
chat.setOwnerToCurrentUser()  // ✅ ADD THIS
chat.otherUser = user
```

**When creating Message:**
```swift
let message = Message(context: context)
message.id = messageId
message.setOwnerToCurrentUser()  // ✅ ADD THIS
message.content = content
```

**When creating User:**
```swift
let user = User(context: context)
user.id = userId
user.setOwnerToCurrentUser()  // ✅ ADD THIS
user.username = username
```

---

## Files to Update

**Priority 1 - CRITICAL (security):**
1. ✅ `ChatsViewModel.swift` - loads all chats
2. ✅ `ChatViewModel.swift` - loads messages for chat
3. ✅ `BackgroundFetchManager.swift` - saves messages in background

**Priority 2 - Important:**
4. ✅ `ContactsViewModel.swift` - loads users/contacts
5. ✅ `ProfileShareViewModel.swift` - handles profile sharing
6. ✅ `AccountSettingsViewModel.swift` - user settings

---

## Testing Checklist

### Test Multi-Account

1. Login as user A
2. Chat with user B
3. Logout
4. Login as user C
5. **Expected:** No chats visible ✅
6. **Before:** User A's chats still visible ❌

### Test Data Persistence

1. Login as user A
2. Create chats
3. Logout
4. Login as user A again
5. **Expected:** Chats restored ✅

### Test Migration

1. Run app with OLD data (no ownerId)
2. Core Data migrates automatically
3. **Expected:** Chats visible but ownerId is nil
4. Logout/Login sets ownerId correctly
5. **Expected:** Data filtered properly

---

## Implementation Status

- [x] Core Data model updated with `ownerId`
- [x] Migration enabled (lightweight)
- [x] Extension helpers created
- [ ] ChatsViewModel updated
- [ ] ChatViewModel updated
- [ ] BackgroundFetchManager updated
- [ ] ContactsViewModel updated
- [ ] All other fetch requests updated
- [ ] All object creation updated
- [ ] Tested in Xcode

---

## Next Steps

1. **Update ChatsViewModel** - most critical
2. **Update ChatViewModel** - messages
3. **Update BackgroundFetchManager** - background fetch
4. **Test thoroughly** - multi-account scenarios
5. **Add migration for existing data** - set ownerId for nil records

---

**Status:** 🚧 In Progress  
**Priority:** 🔴 CRITICAL SECURITY FIX

# Profile Sharing - System Message Notification

**Date:** 2026-01-25 08:39  
**Status:** ✅ IMPLEMENTED  
**Priority:** HIGH (User Experience)

---

## Problem

When User B receives profile from User A:
- ✅ Data saved to Core Data
- ✅ Avatar downloaded
- ❌ **No notification in chat!**

User has no idea that profile was shared.

---

## Solution

Add **system message** in chat when profile is received.

### Visual Example:

```
┌─────────────────────────────────────┐
│  👤 Alice                           │
│                                     │
│  Hello!                        You │
│                                     │
│        📸 Alice shared their profile │  ← NEW!
│                                     │
│  Thanks!                       You │
└─────────────────────────────────────┘
```

---

## Implementation

### 1. System Message Format

**Marker:** Messages starting with `[SYSTEM]` are system messages

**Examples:**
```
[SYSTEM]📸 Alice shared their profile  (with avatar)
[SYSTEM]👤 Bob shared their profile    (no avatar)
```

### 2. Creating System Message

**File:** `ConstructMessenger/ViewModels/ChatsViewModel.swift`  
**Function:** `addSystemMessageToChat(userId:displayName:hasAvatar:)`

```swift
private func addSystemMessageToChat(userId: String, displayName: String, hasAvatar: Bool) {
    // Create Message entity
    let message = Message(context: context)
    message.id = UUID().uuidString
    message.timestamp = Date()
    message.chat = chat
    message.fromUserId = userId
    message.toUserId = currentUserId
    message.isSentByMe = false
    message.encryptedContent = ""
    
    // Mark as system message with special prefix
    let icon = hasAvatar ? "📸" : "👤"
    message.decryptedContent = "[SYSTEM]\(icon) \(displayName) shared their profile"
    
    message.deliveryStatus = .delivered
    
    // Update chat's last message
    chat.lastMessage = content_without_prefix
    
    try? context.save()
}
```

**Called from:** `handleProfileMessage()` after saving profile data

---

### 3. Displaying System Messages

**File:** `ConstructMessenger/Views/Chat/MessageBubble.swift`  
**Changes:** Added conditional rendering

```swift
var body: some View {
    // Check if system message
    if let content = message.decryptedContent, content.hasPrefix("[SYSTEM]") {
        systemMessageView(content.replacingOccurrences(of: "[SYSTEM]", with: ""))
    } else {
        regularMessageView  // Normal bubble
    }
}

private func systemMessageView(_ content: String) -> some View {
    HStack {
        Spacer()
        Text(content)  // "📸 Alice shared their profile"
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .cornerRadius(12)
        Spacer()
    }
    .padding(.vertical, 4)
}
```

**Result:**
- Centered
- Gray background
- Small text
- No bubble
- No delivery status
- No context menu

---

## Files Changed

### 1. ChatsViewModel.swift

**Line ~807:** Added call in `handleProfileMessage()`
```swift
// After saving profile data
addSystemMessageToChat(
    userId: userId,
    displayName: profileData.displayName,
    hasAvatar: profileData.avatarMediaId != nil || profileData.avatarData != nil
)
```

**Lines ~819-860:** New function `addSystemMessageToChat()`

---

### 2. MessageBubble.swift

**Lines 45-52:** Added system message check in `body`

**Lines 55-68:** New `systemMessageView()` function

**Line 71:** Wrapped original content in `regularMessageView`

---

## Testing

### Test Scenario:

**Setup:**
1. User A and User B with existing chat
2. User A has avatar uploaded
3. User A shares profile with User B

**Expected:**

**User B's app:**
```
1. Long-polling receives encrypted message
2. Decrypts message
3. Detects type="profile"
4. Downloads avatar from media-service
5. Saves to Core Data:
   - user.displayName = "Alice"
   - user.avatarData = <jpeg_data>
   - user.isSharingWithMe = true
6. Creates system message
7. Chat view shows:
   "📸 Alice shared their profile"
```

**User B's chat list:**
- Last message: "Alice shared their profile" (without emoji)
- Avatar updated to new image

**User B's chat view:**
- System message appears centered, gray
- Regular messages above/below

---

### What to Check:

✅ System message appears in chat  
✅ System message is centered and gray  
✅ Regular messages still work  
✅ Chat list shows "Alice shared their profile"  
✅ Avatar appears in chat list  
✅ No crash or errors  

---

## Edge Cases

### 1. Profile shared without avatar
```
[SYSTEM]👤 Bob shared their profile
```
Uses 👤 icon instead of 📸

### 2. Avatar download fails
```
✅ System message still created
✅ Shows 📸 icon (was attempted)
❌ But user.avatarData remains nil
```

User sees notification but no avatar.

### 3. Multiple profile shares
Each share creates NEW system message:
```
[old] 📸 Alice shared their profile
[new] 📸 Alice shared their profile
```

**TODO:** Maybe check if profile already shared recently, skip duplicate notification?

### 4. App in background
- Message stored in Core Data
- Notification appears when app opened
- No push notification (profile messages are silent)

---

## Future Improvements

### 1. Make System Messages Clickable
```swift
.onTapGesture {
    // Open user profile view
    showUserProfile(userId)
}
```

### 2. Different Icons for Different Events
```
📸 - Profile shared with avatar
👤 - Profile shared without avatar
🔒 - Session reinitialized
⚡ - E2EE enabled
```

### 3. Hide Old System Messages
After 7 days, auto-hide or compress system messages to reduce clutter.

### 4. Deduplicate Notifications
If profile shared twice in 24 hours, update existing message instead of creating new one.

---

## Known Limitations

1. **No Core Data field** for system messages
   - Uses `[SYSTEM]` prefix hack
   - Works but not ideal
   - Better: Add `isSystemMessage: Bool` to schema

2. **No localization**
   - Hardcoded "shared their profile"
   - Should use NSLocalizedString

3. **No way to delete system messages**
   - They persist forever
   - Could add "hide" feature

4. **Context menu still available**
   - Can copy "[SYSTEM]..." text
   - Should disable for system messages

---

## Summary

**Before:**
- Profile shared → silent update
- User confused

**After:**
- Profile shared → notification in chat
- Clear visual feedback
- Better UX

**Status:** ✅ Ready to test

---

**Next:** Test in Xcode simulator with 2 users

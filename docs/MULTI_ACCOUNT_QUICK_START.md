# Multi-Account Support - Quick Start

## ✅ What's Done

1. **Core Data model** - added `ownerId` field
2. **Extensions** - helper methods ready to use
3. **Compilation** - ✅ No errors!

## 🚀 How to Use

### When Fetching Data

**OLD:**
```swift
let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
```

**NEW:**
```swift
let fetchRequest = Chat.fetchRequestForCurrentUser()
```

**If you need additional predicates:**
```swift
let fetchRequest = Chat.fetchRequestForCurrentUser()
// Combine with AND
let ownerPredicate = fetchRequest.predicate!
let otherPredicate = NSPredicate(format: "otherUser.id == %@", userId)
fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, otherPredicate])
```

### When Creating Objects

**Chat:**
```swift
let chat = Chat(context: context)
chat.id = UUID().uuidString
chat.setOwnerToCurrentUser()  // ✅ ADD THIS LINE
```

**Message:**
```swift
let message = Message(context: context)
message.id = messageId
message.setOwnerToCurrentUser()  // ✅ ADD THIS LINE
```

**User:**
```swift
let user = User(context: context)
user.id = userId
user.setOwnerToCurrentUser()  // ✅ ADD THIS LINE
```

## 📋 Files to Update (in order)

1. **ChatsViewModel.swift** - CRITICAL
   - ~6 fetch requests
   - ~3 object creations
   
2. **ChatViewModel.swift**
   - ~5 fetch requests (Message)
   - ~2 object creations

3. **BackgroundFetchManager.swift**
   - ~3 fetch requests
   - ~2 object creations

4. **ContactsViewModel.swift**
   - ~2 fetch requests

## 🔍 Find & Replace in Xcode

1. Open file
2. Cmd+F → Find & Replace
3. Search: `NSFetchRequest<Chat> = Chat.fetchRequest()`
4. Replace: `= Chat.fetchRequestForCurrentUser()`
5. **Review each occurrence!** Some need additional predicates

Repeat for:
- `NSFetchRequest<Message> = Message.fetchRequest()`
- `NSFetchRequest<User> = User.fetchRequest()`

## ⚠️ Important Notes

1. **Test after each file** - don't update all at once
2. **Keep additional predicates** - use NSCompoundPredicate
3. **Migration is automatic** - existing data won't break (ownerId will be nil initially)
4. **First login sets ownerId** - on next login data will be filtered

## 🧪 Testing

After updating code:

1. **Clean build** (Cmd+Shift+K)
2. **Run app**
3. **Login as user A** → create chats
4. **Logout**
5. **Login as user B**
6. **Expected:** No chats visible ✅

## ❓ Questions?

- Check `docs/implementation/MULTI_ACCOUNT_MIGRATION.md` for detailed guide
- Check `docs/implementation/MULTI_ACCOUNT_TODO.md` for line-by-line changes

---

**Status:** Ready to implement!  
**Compilation:** ✅ No errors

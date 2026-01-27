# Multi-Account Implementation TODO

## ✅ Completed

1. Core Data model updated with `ownerId` fields
2. Extension helpers created (`MultiAccountExtensions.swift`)
3. Migration enabled (automatic lightweight)

## 🚧 Required Changes

### ChatsViewModel.swift (905 lines - CRITICAL)

**Locations to update:**

1. **Line 248** - `startChat()`:
   ```swift
   # OLD:
   let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
   fetchRequest.predicate = NSPredicate(format: "otherUser.id == %@", user.id)
   
   # NEW:
   let fetchRequest = Chat.fetchRequestForCurrentUser()
   // Combine predicates
   let ownerPredicate = fetchRequest.predicate!
   let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", user.id)
   fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerPredicate, otherUserPredicate])
   ```

2. **Line 256** - User fetch:
   ```swift
   # NEW:
   let userFetchRequest = User.fetchRequestForCurrentUser()
   // Then add: AND id == %@
   ```

3. **Line 270** - Creating new Chat:
   ```swift
   let newChat = Chat(context: context)
   newChat.id = UUID().uuidString
   newChat.setOwnerToCurrentUser()  # ADD THIS
   ```

4. **Line 273** - Creating new User:
   ```swift
   newUser.id = user.id
   newUser.setOwnerToCurrentUser()  # ADD THIS
   ```

5. **Line 323, 388, 469, 681, 827** - All other Chat fetches:
   - Replace with `Chat.fetchRequestForCurrentUser()`
   - Keep additional predicates with AND

### Similar updates needed in:

- ChatViewModel.swift
- BackgroundFetchManager.swift
- ContactsViewModel.swift
- ProfileShareViewModel.swift
- AccountSettingsViewModel.swift

---

## Manual Steps (RECOMMENDED)

Since this is a security-critical change affecting many files, I recommend:

1. **Compile & Run First**
   - Check if Core Data migration works
   - Existing data won't break (ownerId will be nil)

2. **Update ONE file at a time**
   - Start with ChatsViewModel
   - Test after each file
   - Ensure no crashes

3. **Use Xcode Find & Replace**
   - Search: `NSFetchRequest<Chat> = Chat.fetchRequest()`
   - Review each occurrence manually
   - Some need additional predicate logic

Would you like me to:
- A) Update ChatsViewModel now (biggest file, most complex)
- B) Create a detailed line-by-line change list for each file
- C) Focus on testing the migration first, then update code incrementally

What's your preference?

# Bug Fix: Missing Username in Contact QR Code

**Date:** 2026-01-24  
**Issue:** Username disappears after app restart  
**Symptom:** `https://konstruct.cc/c/[userId]?username=` (empty username)

---

## 🔍 Root Cause

`AuthViewModel.currentUsername` was not restored when loading session from Core Data.

**Bug Flow:**
```
App Restart → restoreSession() → loadUserFromCoreData()
             → Only displayName restored ❌
             → currentUsername = nil
             → QR code link has empty username
```

---

## ✅ Fix

**File:** `ConstructMessenger/ViewModels/AuthViewModel.swift` (lines 496-504)

```swift
// Before (only restored displayName):
self.currentDisplayName = user.displayName

// After (restore all user data):
self.currentUserId = user.id
self.currentUsername = user.username      // ← FIX!
self.currentDisplayName = user.displayName
```

---

## 🧪 Test

1. Login → Close app → Relaunch
2. Settings → Add Contact → QR code
3. Verify: `?username=testuser` (not empty) ✅

---

**Status:** ✅ FIXED

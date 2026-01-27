# Quick Start: Testing APNs in Xcode

## Step 1: Add File to Project

1. Open `ConstructMessenger.xcodeproj` in Xcode
2. In Project Navigator, find folder: **Networking**
3. Right-click → **Add Files to "ConstructMessenger"...**
4. Navigate to: `ConstructMessenger/Networking/PushNotificationManager.swift`
5. ✅ Ensure checked: **Add to targets: ConstructMessenger**
6. Click **Add**

## Step 2: Enable Push Capability

1. Select project **ConstructMessenger** (blue icon at top)
2. Select target: **ConstructMessenger**
3. Tab: **Signing & Capabilities**
4. Click **+ Capability**
5. Add: **Push Notifications**

This will add `aps-environment` to your entitlements.

## Step 3: Build & Run

```bash
# Clean build folder
Cmd + Shift + K

# Build
Cmd + B

# Run on REAL DEVICE (push doesn't work in simulator!)
Cmd + R
```

## Step 4: Test Flow

### On First Launch After Login:

1. You should see iOS permission dialog:
   ```
   "ConstructMessenger" Would Like to Send You Notifications
   [Don't Allow]  [Allow]
   ```

2. Tap **Allow**

3. Check Xcode console logs:
   ```
   📱 PushNotificationManager initialized
   📱 Requesting push notification permission
   ✅ Push notification permission granted
   📱 Received device token from APNs
   📱 Registering device token (length: 64)
   📡 Registering device token with server
   ✅ Device token registered with server: success=true
   📡 State change: token=present, status=Connected, push=true
   📱 Push enabled - using minimal background polling
   ```

### Testing Message Reception:

1. Send message from another account to your test user
2. Put app in background (home button)
3. Watch for silent push wake-up in logs:
   ```
   📱 Received notification while app in foreground
   📱 Silent push - not showing notification
   📥 Poll response: 1 messages
   ```

## Common Issues

### Build Errors

**Error:** `Cannot find 'PushNotificationManager' in scope`  
**Fix:** Make sure file was added to target (Step 1, checkbox #5)

**Error:** Missing import  
**Fix:** File should auto-import `UserNotifications` and `UIKit`

### Runtime Issues

**Issue:** Permission dialog doesn't appear  
**Fix:** 
```bash
# Reset permissions (if testing multiple times)
Settings → General → Reset → Reset Location & Privacy
# Or delete and reinstall app
```

**Issue:** No device token received  
**Fix:** 
- Must run on **real device** (not simulator)
- Check internet connection
- Verify Push capability is enabled (Step 2)

**Issue:** Server registration fails (404)  
**Fix:**
- Server must be running
- Check server has APNs endpoints deployed
- Verify network connectivity

## Expected Console Output

### ✅ Success Scenario:
```
📱 PushNotificationManager initialized
📱 Requesting push notification permission  
✅ Push notification permission granted
📱 Received device token from APNs
📱 Registering device token (length: 64)
📡 Registering device token with server
✅ Device token registered with server: success=true
📡 State change: token=present, status=Connected, push=true
📱 Push enabled - using minimal background polling
```

### ❌ Common Error (Permission Denied):
```
📱 PushNotificationManager initialized
📱 Requesting push notification permission
❌ Push notification permission denied
📡 State change: token=present, status=Connected, push=false
📡 Push disabled - using full long-polling
```
→ **This is OK!** App will fall back to long-polling.

## What to Look For

### ✅ Good Signs:
- Permission dialog appears
- Device token has 64 characters
- Server responds with `success=true`
- Logs show `push=true` in state change
- No red ❌ errors in console

### ⚠️ Warnings (Non-Critical):
- `search path not found` - can ignore
- `Metal API Validation` - can ignore
- `fopen failed for data file` - CoreData cache, can ignore

### 🔴 Critical Errors:
- `Failed to register for remote notifications` - Check device/capability
- `Failed to register device token with server` - Check server connectivity
- App crashes on launch - Build error, check previous step

## Next Steps After Successful Build

1. ✅ Verify permission dialog appears
2. ✅ Grant permission
3. ✅ Check device token registration succeeds
4. ✅ Send test message from another account
5. ✅ Verify push wakes app in background
6. 🎉 APNs is working!

## Need Help?

Check full documentation:
- `docs/implementation/apns-client-implementation-summary.md`
- `docs/implementation/apns-push-notifications.md`

Console logs with category filters:
```
# Filter by Push category
[Push]

# Filter by ChatsViewModel
[ChatsViewModel]

# Filter by Network
[Network]
```

# APNs Push Notifications Implementation Plan

**Date:** 2026-01-24  
**Status:** Ready for Implementation  
**Priority:** P0 (High Impact - 98% battery savings)

---

## ✅ What's Already Done (Server-Side)

1. ✅ APNs Configuration (`shared/src/construct_server/config/federation.rs`)
2. ✅ APNs Client (`shared/src/construct_server/apns/client.rs`)
3. ✅ Device Token Encryption (`shared/src/construct_server/apns/encryption.rs`)
4. ✅ Notification Routes (`shared/src/construct_server/routes/notifications.rs`)
   - `POST /api/v1/notifications/register-device`
   - `POST /api/v1/notifications/unregister-device`

---

## 🎯 What Needs to be Done

### Server-Side
- [ ] Integrate APNs into messaging service (send push when message arrives)
- [ ] Set environment variables in production

### Client-Side (iOS)
- [ ] Request push notification permissions
- [ ] Register device token with server
- [ ] Handle silent pushes
- [ ] Implement hybrid polling strategy
- [ ] Add settings toggle for push notifications

See full implementation details in the document.

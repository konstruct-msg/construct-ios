# UUID Type Mismatch Fix for APNs Push

**Date**: 2026-01-24 22:28  
**Error**: `operator does not exist: uuid = text`  
**Component**: messaging-service (server)  
**Status**: ⚠️ Needs server-side fix

## Error Message

```
2026-01-24T22:27:21.809344Z  WARN construct_server_shared::construct_server::messaging_service::handlers: 
Failed to send push notification (non-fatal) 
recipient_hash=3ff70210 
error=error returned from database: operator does not exist: uuid = text
```

## Root Cause

PostgreSQL strict type checking: cannot compare UUID column with TEXT string without explicit cast.

The query in `messaging_service/handlers.rs` is likely:

```rust
sqlx::query!(
    "SELECT device_token_encrypted, device_token_hash, enabled 
     FROM device_tokens 
     WHERE user_id = $1 AND enabled = true",
    recipient_id  // ❌ This is String, but user_id is UUID
)
```

## Solution

Add explicit type cast in SQL query:

```rust
sqlx::query!(
    "SELECT device_token_encrypted, device_token_hash, enabled 
     FROM device_tokens 
     WHERE user_id = $1::uuid AND enabled = true",
    //                    ^^^^^^ Add this cast
    recipient_id
)
```

OR convert parameter to UUID before query:

```rust
let recipient_uuid = uuid::Uuid::parse_str(&recipient_id)
    .map_err(|e| anyhow::anyhow!("Invalid recipient ID: {}", e))?;

sqlx::query!(
    "SELECT device_token_encrypted, device_token_hash, enabled 
     FROM device_tokens 
     WHERE user_id = $1 AND enabled = true",
    recipient_uuid  // ✅ Now it's Uuid type
)
```

## File to Fix

**Location**: `construct-server/shared/src/construct_server/messaging_service/handlers.rs`

Look for the `send_push_notification()` function around lines 80-175.

## Test Query

To verify the fix works:

```sql
-- Test with explicit cast
SELECT device_token_encrypted, device_token_hash, enabled 
FROM device_tokens 
WHERE user_id = 'af70cf9a-b176-4df3-b6bf-00196a6f173e'::uuid 
  AND enabled = true;
```

## Impact

**Current**: Non-fatal error, push notifications fail silently  
**After fix**: Push notifications will query database successfully (though sending still disabled until decryption implemented)

## Related Issues

- APNs push is currently disabled (lines 80-175 in handlers.rs)
- Device token decryption not yet implemented
- This fix allows the query to succeed, preparing for future APNs implementation

## Deployment

1. Fix `construct-server/shared/src/construct_server/messaging_service/handlers.rs`
2. Add `::uuid` cast to the WHERE clause
3. Recompile: `cd construct-server && cargo build --release`
4. Deploy to fly.io
5. Verify warning disappears from logs

## Priority

**Low-Medium** - Push notifications are already disabled, so this is just noise in logs. But good to fix for cleaner logs and future APNs work.

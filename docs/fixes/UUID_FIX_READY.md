# APNs UUID Type Mismatch - Ready to Apply Fix

## File: `construct-server/shared/src/construct_server/messaging_service/handlers.rs`

### Find this code (around line 80-100):

```rust
let device_token_row = sqlx::query!(
    r#"
    SELECT device_token_encrypted, device_token_hash, enabled
    FROM device_tokens
    WHERE user_id = $1 AND enabled = true
    "#,
    recipient_id
)
.fetch_optional(&**db_pool)
.await;
```

### Replace with:

```rust
let device_token_row = sqlx::query!(
    r#"
    SELECT device_token_encrypted, device_token_hash, enabled
    FROM device_tokens
    WHERE user_id = $1::uuid AND enabled = true
    "#,
    //                ^^^^^^ Add this cast
    recipient_id
)
.fetch_optional(&**db_pool)
.await;
```

## That's it! Just add `::uuid` after `$1`

## Deploy:
```bash
cd construct-server
cargo build --release -p messaging-service
cd messaging-service
fly deploy
```

## Verify:
After deploy, the warning should disappear:
```
# Before (BAD):
WARN Failed to send push notification error=operator does not exist: uuid = text

# After (GOOD):
No warning, or different error about decryption (which is expected)
```

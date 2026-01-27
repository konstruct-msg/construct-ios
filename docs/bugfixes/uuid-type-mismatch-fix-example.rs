// FIX for: operator does not exist: uuid = text
// File: construct-server/shared/src/construct_server/messaging_service/handlers.rs
// Location: send_push_notification() function

// ❌ BEFORE (causes PostgreSQL error):
let device_token_row = sqlx::query!(
    r#"
    SELECT device_token_encrypted, device_token_hash, enabled
    FROM device_tokens
    WHERE user_id = $1 AND enabled = true
    "#,
    recipient_id  // This is &str, but user_id column is UUID
)
.fetch_optional(&**db_pool)
.await;

// ✅ AFTER (Option 1 - SQL cast):
let device_token_row = sqlx::query!(
    r#"
    SELECT device_token_encrypted, device_token_hash, enabled
    FROM device_tokens
    WHERE user_id = $1::uuid AND enabled = true
    "#,
    //                ^^^^^^ Add explicit cast
    recipient_id
)
.fetch_optional(&**db_pool)
.await;

// ✅ AFTER (Option 2 - Rust Uuid type):
use uuid::Uuid;

let recipient_uuid = Uuid::parse_str(recipient_id)
    .map_err(|e| {
        warn!("Invalid recipient UUID: {}", e);
        anyhow::anyhow!("Invalid recipient ID format")
    })?;

let device_token_row = sqlx::query!(
    r#"
    SELECT device_token_encrypted, device_token_hash, enabled
    FROM device_tokens
    WHERE user_id = $1 AND enabled = true
    "#,
    recipient_uuid  // Now it's Uuid type, matches column type
)
.fetch_optional(&**db_pool)
.await;

// RECOMMENDATION: Use Option 1 (SQL cast) - simpler, fewer changes

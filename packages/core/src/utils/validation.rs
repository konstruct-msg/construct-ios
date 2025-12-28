use crate::config::Config;
use crate::utils::error::Result;

pub fn validate_public_key(key: &[u8]) -> Result<()> {
    let expected_size = Config::global().public_key_size;
    if key.len() != expected_size {
        return Err(crate::utils::error::ConstructError::ValidationError(
            format!("Public key must be {} bytes", expected_size),
        ));
    }
    Ok(())
}

pub fn validate_signature(sig: &[u8]) -> Result<()> {
    let expected_size = Config::global().signature_size;
    if sig.len() != expected_size {
        return Err(crate::utils::error::ConstructError::ValidationError(
            format!("Signature must be {} bytes", expected_size),
        ));
    }
    Ok(())
}

//! Small platform helpers shared by the ported modules.

use std::hash::{BuildHasher, Hasher};

/// Random lowercase-hex string of `n` characters.
///
/// Used for sync library IDs and staging tokens — identifiers that must be
/// unique, not unguessable — so `std`'s randomly seeded `RandomState` is enough
/// and we avoid pulling in an RNG dependency.
pub fn random_hex(n: usize) -> String {
    let mut out = String::with_capacity(n + 16);
    while out.len() < n {
        let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
        hasher.write_u128(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0),
        );
        out.push_str(&format!("{:016x}", hasher.finish()));
    }
    out.truncate(n);
    out
}

/// A UUID-shaped identifier, matching the shape the Windows build sent.
pub fn random_uuid_like() -> String {
    format!(
        "{}-{}-{}-{}-{}",
        random_hex(8),
        random_hex(4),
        random_hex(4),
        random_hex(4),
        random_hex(12)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn random_hex_has_requested_length() {
        assert_eq!(random_hex(10).len(), 10);
        assert_eq!(random_hex(1).len(), 1);
        assert_eq!(random_hex(32).len(), 32);
    }

    #[test]
    fn random_hex_is_hex() {
        assert!(random_hex(64).chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn successive_values_differ() {
        let a = random_hex(32);
        let b = random_hex(32);
        assert_ne!(a, b);
    }
}

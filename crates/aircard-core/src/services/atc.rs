//! `com.apple.atc` — the AirTraffic sync service.
//!
//! This replaces the Windows build's `airtraffic.rs`, which drove Apple's
//! `AirTrafficHost.dll`. The wire protocol is documented in
//! `docs/airtraffic-protocol.md` §3–§5 and was verified against a real device:
//!
//! * framing: 4-byte **LITTLE-endian** length prefix + binary plist
//! * envelope (host → device): `{ "Command", "Session", "Params" }`
//! * sequence:
//!   `SyncAllowed` → `HostInfo`(s0) → `RequestingSync`(s1) → `ReadyForSync`
//!   → `FinishedSyncingMetadata`(s1) → `AssetManifest` → `FileComplete`(s1)
//! * every `Ping` **must** be answered with `Pong` or the connection dies
//! * `SyncFailed` is usually a stale prior-session cancel: non-fatal, keep waiting

use std::time::Duration;

use anyhow::{Context, Result, bail};
use idevice::{Idevice, IdeviceError, IdeviceService, ReadWrite, provider::IdeviceProvider};
use plist::{Dictionary, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::grappa;

const MAX_FRAME: usize = 16 * 1024 * 1024;

/// `HostInfo` goes out on session 0; every other sync message on session 1.
pub const SESSION_HOST_INFO: i64 = 0;
pub const SESSION_SYNC: i64 = 1;

/// One decoded ATC message.
#[derive(Debug, Clone)]
pub struct Message {
    pub command: String,
    pub session: Option<i64>,
    pub params: Option<Dictionary>,
}

impl Message {
    fn from_dict(dict: Dictionary) -> Self {
        Self {
            command: dict
                .get("Command")
                .and_then(Value::as_string)
                .unwrap_or_default()
                .to_string(),
            session: dict.get("Session").and_then(Value::as_signed_integer),
            params: dict.get("Params").and_then(Value::as_dictionary).cloned(),
        }
    }

    pub fn param(&self, key: &str) -> Option<&Value> {
        self.params.as_ref()?.get(key)
    }
}

/// What to do in a sync round.
pub struct SyncRequest<'a> {
    pub library_id: String,
    pub host_name: String,
    /// Index into the published Grappa token table, or `None` to omit Grappa.
    pub grappa_index: Option<usize>,
    /// `(AssetID, AssetPath)` pairs to report as downloaded. Empty = probe only,
    /// which never writes anything outside the AFC Media scope.
    pub completions: &'a [(String, String)],
}

/// Outcome of a sync round.
#[derive(Debug, Default)]
pub struct SyncResult {
    pub manifest: Option<Dictionary>,
    pub manifest_asset_ids: Vec<String>,
    pub completed: usize,
    pub reached_ready_for_sync: bool,
}

pub struct AtcClient {
    stream: Box<dyn ReadWrite>,
}

impl IdeviceService for AtcClient {
    fn service_name() -> std::borrow::Cow<'static, str> {
        "com.apple.atc".into()
    }

    async fn from_stream(idevice: Idevice) -> Result<Self, IdeviceError> {
        let stream = idevice
            .get_socket()
            .ok_or(IdeviceError::NoEstablishedConnection)?;
        Ok(Self { stream })
    }
}

impl AtcClient {
    /// Connect via lockdown (the default `IdeviceService` flow handles
    /// start_session, start_service and the SSL upgrade).
    pub async fn open(provider: &dyn IdeviceProvider) -> Result<Self> {
        <Self as IdeviceService>::connect(provider)
            .await
            .context("starting com.apple.atc")
    }

    /// Read one framed message. Little-endian is the real format; big-endian is
    /// accepted as a fallback so a framing surprise surfaces as a clear error.
    async fn read_message(&mut self, timeout: Duration) -> Result<Message> {
        let mut header = [0u8; 4];
        tokio::time::timeout(timeout, self.stream.read_exact(&mut header))
            .await
            .context("timed out reading ATC frame length")??;

        let le = u32::from_le_bytes(header) as usize;
        let be = u32::from_be_bytes(header) as usize;
        let len = if le > 0 && le <= MAX_FRAME {
            le
        } else if be > 0 && be <= MAX_FRAME {
            be
        } else {
            bail!("no plausible ATC frame length: header={header:02x?} (LE={le} BE={be})");
        };

        let mut body = vec![0u8; len];
        tokio::time::timeout(timeout, self.stream.read_exact(&mut body))
            .await
            .context("timed out reading ATC frame body")??;

        let value: Value = plist::from_bytes(&body).context("decoding ATC plist")?;
        match value {
            Value::Dictionary(d) => Ok(Message::from_dict(d)),
            other => bail!("expected plist dictionary, got {other:?}"),
        }
    }

    /// Send one message using the little-endian framing.
    pub async fn send(
        &mut self,
        command: &str,
        session: i64,
        params: Option<Dictionary>,
    ) -> Result<()> {
        let mut msg = Dictionary::new();
        msg.insert("Command".into(), Value::String(command.to_string()));
        msg.insert("Session".into(), Value::Integer(session.into()));
        if let Some(p) = params {
            msg.insert("Params".into(), Value::Dictionary(p));
        }

        let mut body = Vec::new();
        plist::to_writer_binary(&mut body, &Value::Dictionary(msg))
            .context("encoding ATC plist")?;

        self.stream
            .write_all(&(body.len() as u32).to_le_bytes())
            .await?;
        self.stream.write_all(&body).await?;
        self.stream.flush().await?;
        Ok(())
    }

    /// Read until one of `want` arrives.
    ///
    /// Handles the two things that otherwise hang the sync: replying `Pong` to
    /// every `Ping`, and ignoring `SyncFailed` (a stale prior-session cancel).
    /// Returns `None` if the device finished the session or we ran out of tries.
    async fn recv_until<L: FnMut(&str)>(
        &mut self,
        want: &[&str],
        tries: usize,
        timeout: Duration,
        log: &mut L,
    ) -> Result<Option<Message>> {
        for _ in 0..tries {
            let msg = match self.read_message(timeout).await {
                Ok(m) => m,
                Err(e) => {
                    log(&format!("      ({e:#})"));
                    continue;
                }
            };

            if msg.command != "Ping" {
                log(&format!("  <- {}", msg.command));
            }

            match msg.command.as_str() {
                "Ping" => {
                    self.send("Pong", SESSION_SYNC, None).await?;
                    continue;
                }
                "SyncFailed" => continue,
                "SyncFinished" => return Ok(None),
                c if want.contains(&c) => return Ok(Some(msg)),
                _ => continue,
            }
        }
        Ok(None)
    }

    /// Run one full sync round, optionally reporting assets as downloaded.
    pub async fn run_sync<L: FnMut(&str)>(
        &mut self,
        req: &SyncRequest<'_>,
        log: &mut L,
    ) -> Result<SyncResult> {
        let grappa = req.grappa_index.map(grappa::token);

        // 1. drain the device's startup messages until it allows syncing
        log("[atc] waiting for SyncAllowed");
        if self
            .recv_until(&["SyncAllowed"], 12, Duration::from_millis(1500), log)
            .await?
            .is_none()
        {
            bail!("AirTraffic: SyncAllowed not received (is the iPhone unlocked?)");
        }

        // 2. HostInfo (session 0). Note the params wrap the host dict one level deep.
        let mut host_info = Dictionary::new();
        host_info.insert("Type".into(), Value::String("iTunes".into()));
        host_info.insert("Version".into(), Value::String("13.7.0.161".into()));
        host_info.insert("MacOSVersion".into(), Value::String("Linux".into()));
        host_info.insert(
            "SyncHostName".into(),
            Value::String(req.host_name.clone()),
        );
        host_info.insert("LibraryID".into(), Value::String(req.library_id.clone()));
        host_info.insert(
            "SyncedDataclasses".into(),
            Value::Array(vec![Value::String("Book".into())]),
        );
        host_info.insert(
            "SyncedAssetTypes".into(),
            Value::Array(vec![Value::String("Book".into())]),
        );
        host_info.insert("Wakeable".into(), Value::Boolean(false));
        if let Some(t) = &grappa {
            host_info.insert("Grappa".into(), Value::Data(t.clone()));
        }

        let mut host_params = Dictionary::new();
        host_params.insert("HostInfo".into(), Value::Dictionary(host_info.clone()));
        host_params.insert("LocalCloudSupport".into(), Value::Boolean(false));

        log("[atc] -> HostInfo (session 0)");
        self.send("HostInfo", SESSION_HOST_INFO, Some(host_params))
            .await?;
        tokio::time::sleep(Duration::from_millis(200)).await;

        // 3. RequestingSync (session 1)
        let mut sync_req = Dictionary::new();
        sync_req.insert(
            "Dataclasses".into(),
            Value::Array(vec![Value::String("Book".into())]),
        );
        sync_req.insert(
            "DataclassAnchors".into(),
            Value::Dictionary(Dictionary::new()),
        );
        sync_req.insert("HostInfo".into(), Value::Dictionary(host_info));
        if let Some(t) = &grappa {
            sync_req.insert("Grappa".into(), Value::Data(t.clone()));
        }

        log("[atc] -> RequestingSync (session 1)");
        self.send("RequestingSync", SESSION_SYNC, Some(sync_req))
            .await?;

        // 4. ReadyForSync
        log("[atc] waiting for ReadyForSync");
        let ready = self
            .recv_until(
                &["ReadyForSync", "AssetManifest"],
                24,
                Duration::from_secs(5),
                log,
            )
            .await?;
        if ready.is_none() {
            bail!("AirTraffic: ReadyForSync not received");
        }

        // 5. FinishedSyncingMetadata (session 1) — note the name, it is not
        //    "MetadataSyncFinished" as the Windows wrapper function suggested.
        let mut sync_types = Dictionary::new();
        sync_types.insert("Book".into(), Value::Integer(1.into()));
        let mut meta = Dictionary::new();
        meta.insert("SyncTypes".into(), Value::Dictionary(sync_types));
        meta.insert(
            "DataclassAnchors".into(),
            Value::Dictionary(Dictionary::new()),
        );

        log("[atc] -> FinishedSyncingMetadata (session 1)");
        self.send("FinishedSyncingMetadata", SESSION_SYNC, Some(meta))
            .await?;

        // 6. AssetManifest
        log("[atc] waiting for AssetManifest");
        let manifest_msg = self
            .recv_until(&["AssetManifest"], 20, Duration::from_secs(5), log)
            .await?;
        let manifest = manifest_msg
            .as_ref()
            .and_then(|m| m.param("AssetManifest"))
            .and_then(Value::as_dictionary)
            .cloned();
        let manifest_asset_ids = manifest.as_ref().map(asset_ids).unwrap_or_default();

        // 7. FileComplete — this is the step that makes ATAirlock move files.
        let mut completed = 0usize;
        for (idx, (asset_id, dest)) in req.completions.iter().enumerate() {
            let mut params = Dictionary::new();
            params.insert("AssetID".into(), Value::String(asset_id.clone()));
            params.insert("Dataclass".into(), Value::String("Book".into()));
            params.insert("AssetPath".into(), Value::String(dest.clone()));

            log(&format!("[atc] -> FileComplete {asset_id} => {dest}"));
            self.send("FileComplete", SESSION_SYNC, Some(params)).await?;
            completed += 1;

            if idx + 1 < req.completions.len() {
                tokio::time::sleep(Duration::from_millis(900)).await;
            }
        }

        Ok(SyncResult {
            manifest,
            manifest_asset_ids,
            completed,
            reached_ready_for_sync: true,
        })
    }
}

fn asset_ids(manifest: &Dictionary) -> Vec<String> {
    manifest
        .get("Book")
        .and_then(Value::as_array)
        .map(|books| {
            books
                .iter()
                .filter_map(Value::as_dictionary)
                .filter_map(|d| d.get("AssetID"))
                .filter_map(Value::as_string)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

//! Device discovery and connection over usbmuxd.
//!
//! Replaces the Windows build's `device.rs`, which drove `MobileDevice.dll` via
//! `libloading`. Here everything goes through the pure-Rust `idevice` crate.

use anyhow::{Context, Result};
use idevice::{
    // traits: `connect` on LockdownClient (IdeviceService) and
    // `get_pairing_file` on UsbmuxdProvider (IdeviceProvider)
    IdeviceService,
    provider::{IdeviceProvider, UsbmuxdProvider},
    services::lockdown::LockdownClient,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};

/// Human-readable description of a connected device.
#[derive(Debug, Clone)]
pub struct DeviceInfo {
    pub udid: String,
    pub name: String,
    pub product_type: String,
    pub ios_version: String,
    pub build_version: String,
    pub connection: String,
    /// Whether usbmuxd already holds a pairing record for this device.
    pub paired: bool,
}

impl std::fmt::Display for DeviceInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} ({}, iOS {} [{}]) via {}{}",
            self.name,
            self.product_type,
            self.ios_version,
            self.build_version,
            self.connection,
            if self.paired { "" } else { " [NOT PAIRED]" }
        )
    }
}

fn connection_label(c: &Connection) -> String {
    match c {
        Connection::Usb => "USB".to_string(),
        Connection::Network(ip) => format!("Network({ip})"),
        Connection::Unknown(s) => format!("Unknown({s})"),
    }
}

/// The usbmuxd endpoint (env override, else the crate default).
pub fn usbmuxd_addr() -> UsbmuxdAddr {
    UsbmuxdAddr::from_env_var().unwrap_or_default()
}

async fn open_mux() -> Result<UsbmuxdConnection> {
    UsbmuxdConnection::default()
        .await
        .context("could not connect to usbmuxd — is the usbmuxd daemon running?")
}

/// List every device usbmuxd knows about, enriched with lockdown values.
///
/// Enrichment is best-effort: a device that is locked, untrusted, or has no
/// pairing record still shows up, just with placeholder fields.
pub async fn list_devices() -> Result<Vec<DeviceInfo>> {
    let mut mux = open_mux().await?;
    let devices = mux.get_devices().await.context("listing devices from usbmuxd")?;
    let mut out = Vec::with_capacity(devices.len());
    for device in devices {
        out.push(describe(device).await);
    }
    Ok(out)
}

/// Pick the device to operate on: an explicit UDID, else the first USB device.
pub async fn provider_for(udid: Option<&str>) -> Result<UsbmuxdProvider> {
    let mut mux = open_mux().await?;
    let devices = mux.get_devices().await.context("listing devices from usbmuxd")?;

    let chosen: UsbmuxdDevice = match udid {
        Some(want) => devices
            .iter()
            .find(|d| d.udid.eq_ignore_ascii_case(want))
            .cloned()
            .with_context(|| format!("no connected device with UDID {want}"))?,
        None => devices
            .iter()
            .find(|d| d.connection_type == Connection::Usb)
            .cloned()
            .context("no device connected over USB")?,
    };

    Ok(chosen.to_provider(usbmuxd_addr(), "aircard"))
}

/// A lockdown client with an active session, plus the pairing file it needed.
pub struct Lockdown {
    pub client: LockdownClient,
    pub pairing_file: idevice::pairing_file::PairingFile,
    pub legacy: bool,
}

impl Lockdown {
    /// Connect to lockdownd and start a session.
    pub async fn connect(provider: &UsbmuxdProvider) -> Result<Self> {
        let pairing_file = provider
            .get_pairing_file()
            .await
            .context("no pairing record — pair the device first (tap \"Trust\" when prompted)")?;

        let mut client = LockdownClient::connect(provider)
            .await
            .context("starting lockdownd connection")?;
        let legacy = client
            .start_session(&pairing_file)
            .await
            .context("starting lockdownd session")?;

        Ok(Self {
            client,
            pairing_file,
            legacy,
        })
    }

    /// Read a single lockdown value (best-effort helper).
    pub async fn get(&mut self, key: &str) -> Option<String> {
        self.client
            .get_value(Some(key), None)
            .await
            .ok()
            .and_then(|v| v.as_string().map(str::to_string))
    }
}

async fn describe(device: UsbmuxdDevice) -> DeviceInfo {
    let mut info = DeviceInfo {
        udid: device.udid.clone(),
        name: "iPhone".to_string(),
        product_type: "Unknown".to_string(),
        ios_version: "Unknown".to_string(),
        build_version: "Unknown".to_string(),
        connection: connection_label(&device.connection_type),
        paired: false,
    };

    let provider = device.to_provider(usbmuxd_addr(), "aircard");
    let Ok(mut lockdown) = Lockdown::connect(&provider).await else {
        return info;
    };
    info.paired = true;

    if let Some(v) = lockdown.get("DeviceName").await {
        info.name = v;
    }
    if let Some(v) = lockdown.get("ProductType").await {
        info.product_type = v;
    }
    if let Some(v) = lockdown.get("ProductVersion").await {
        info.ios_version = v;
    }
    if let Some(v) = lockdown.get("BuildVersion").await {
        info.build_version = v;
    }

    info
}

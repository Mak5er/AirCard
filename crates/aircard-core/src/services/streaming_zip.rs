//! `com.apple.streaming_zip_conduit` — stages a zip into the Media sandbox.
//!
//! ⚠️ **Framing here is 4-byte BIG-endian**, the opposite of `com.apple.atc`
//! (see `docs/airtraffic-protocol.md` §5.6). These two must never share a helper.
//!
//! Protocol: send a BE-framed `{"MediaSubdir": <name>}` plist, then the raw
//! archive bytes, then read a BE-framed response plist (`{"Status": "DataComplete"}`).

use std::time::Duration;

use anyhow::{Context, Result, bail};
use idevice::{Idevice, IdeviceError, IdeviceService, ReadWrite, provider::IdeviceProvider};
use plist::{Dictionary, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const MAX_FRAME: usize = 64 * 1024 * 1024;

pub struct StreamingZipClient {
    stream: Box<dyn ReadWrite>,
}

impl IdeviceService for StreamingZipClient {
    fn service_name() -> std::borrow::Cow<'static, str> {
        "com.apple.streaming_zip_conduit".into()
    }

    async fn from_stream(idevice: Idevice) -> Result<Self, IdeviceError> {
        let stream = idevice
            .get_socket()
            .ok_or(IdeviceError::NoEstablishedConnection)?;
        Ok(Self { stream })
    }
}

impl StreamingZipClient {
    pub async fn open(provider: &dyn IdeviceProvider) -> Result<Self> {
        <Self as IdeviceService>::connect(provider)
            .await
            .context("starting com.apple.streaming_zip_conduit")
    }

    /// Stage `archive` into `/var/mobile/Media/<subdir>`.
    ///
    /// Returns the device's response plist.
    pub async fn stage(
        &mut self,
        subdir: &str,
        archive: &[u8],
        timeout: Duration,
    ) -> Result<Dictionary> {
        let mut init = Dictionary::new();
        init.insert("MediaSubdir".into(), Value::String(subdir.to_string()));
        let mut body = Vec::new();
        plist::to_writer_binary(&mut body, &Value::Dictionary(init))
            .context("encoding MediaSubdir")?;

        // BIG-endian length prefix — deliberately not shared with the ATC client.
        self.stream
            .write_all(&(body.len() as u32).to_be_bytes())
            .await?;
        self.stream.write_all(&body).await?;
        self.stream.write_all(archive).await?;
        self.stream.flush().await?;

        let mut header = [0u8; 4];
        tokio::time::timeout(timeout, self.stream.read_exact(&mut header))
            .await
            .context("timed out reading streaming_zip response length")??;
        let len = u32::from_be_bytes(header) as usize;
        if len == 0 || len > MAX_FRAME {
            bail!("implausible streaming_zip response length {len}");
        }

        let mut resp = vec![0u8; len];
        tokio::time::timeout(timeout, self.stream.read_exact(&mut resp))
            .await
            .context("timed out reading streaming_zip response body")??;

        let value: Value = plist::from_bytes(&resp).context("decoding streaming_zip response")?;
        match value {
            Value::Dictionary(d) => Ok(d),
            other => bail!("expected plist dictionary, got {other:?}"),
        }
    }
}

//! AFC facade over `idevice`'s client.
//!
//! Replaces the Windows build's `afc.rs`, which drove Apple's AFC function
//! pointers out of `MobileDevice.dll`. The method set mirrors that file so the
//! ported `airlift.rs` / `flasher.rs` need no changes beyond `async`.

use anyhow::{Context, Result};
use idevice::{
    IdeviceService,
    afc::{AfcClient, opcode::AfcFopenMode},
    provider::IdeviceProvider,
};

/// AFC root is the device's `/var/mobile/Media`, so all paths are Media-relative.
pub struct Afc {
    inner: AfcClient,
}

impl Afc {
    /// Connect to `com.apple.afc`.
    pub async fn connect(provider: &dyn IdeviceProvider) -> Result<Self> {
        let inner = AfcClient::connect(provider)
            .await
            .context("starting com.apple.afc")?;
        Ok(Self { inner })
    }

    /// AFC has no dedicated `exists`; a successful stat is the test.
    pub async fn exists(&mut self, path: &str) -> bool {
        self.inner.get_file_info(path).await.is_ok()
    }

    pub async fn file_size(&mut self, path: &str) -> Option<usize> {
        self.inner.get_file_info(path).await.ok().map(|i| i.size)
    }

    pub async fn read_file(&mut self, path: &str) -> Result<Vec<u8>> {
        let mut fd = self
            .inner
            .open(path, AfcFopenMode::RdOnly)
            .await
            .with_context(|| format!("opening {path} for read"))?;
        let data = fd
            .read_entire()
            .await
            .with_context(|| format!("reading {path}"))?;
        fd.close().await.ok();
        Ok(data)
    }

    pub async fn write_file(&mut self, path: &str, data: &[u8]) -> Result<()> {
        // WrOnly = O_WRONLY|O_CREAT|O_TRUNC, so this creates the file.
        let mut fd = self
            .inner
            .open(path, AfcFopenMode::WrOnly)
            .await
            .with_context(|| format!("opening {path} for write"))?;
        fd.write_entire(data)
            .await
            .with_context(|| format!("writing {path}"))?;
        fd.close().await.ok();
        Ok(())
    }

    pub async fn make_directory(&mut self, path: &str) -> Result<()> {
        if self.exists(path).await {
            return Ok(());
        }
        self.inner
            .mk_dir(path)
            .await
            .with_context(|| format!("mkdir {path}"))?;
        Ok(())
    }

    pub async fn make_directory_recursive(&mut self, path: &str) -> Result<()> {
        let mut current = String::new();
        for part in path.split('/') {
            if part.is_empty() {
                continue;
            }
            current.push('/');
            current.push_str(part);
            self.make_directory(&current).await?;
        }
        Ok(())
    }

    pub async fn remove_path(&mut self, path: &str) -> Result<()> {
        if !self.exists(path).await {
            return Ok(());
        }
        self.inner
            .remove(path)
            .await
            .with_context(|| format!("removing {path}"))?;
        Ok(())
    }

    /// Recursive delete (AFC's REMOVE_ALL).
    pub async fn remove_tree(&mut self, path: &str) -> Result<()> {
        if !self.exists(path).await {
            return Ok(());
        }
        self.inner
            .remove_all(path)
            .await
            .with_context(|| format!("removing tree {path}"))?;
        Ok(())
    }

    pub async fn list_directory(&mut self, path: &str) -> Result<Vec<String>> {
        self.inner
            .list_dir(path)
            .await
            .with_context(|| format!("listing {path}"))
    }
}

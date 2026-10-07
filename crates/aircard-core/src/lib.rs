//! AirCard-Linux core.
//!
//! Port of `reference/AirCard-Windows`, with the device transport layer swapped
//! from Apple's Windows DLLs (`apple.rs` / `device.rs` / `afc.rs`) to the
//! pure-Rust `idevice` crate.
//!
//! The AirTraffic wire protocol this is built on is documented in
//! `docs/airtraffic-protocol.md`.

pub mod afc;
pub mod airlift;
pub mod device;
pub mod flasher;
pub mod image_skin;
pub mod passthm;
pub mod scanner;
pub mod services;
pub mod util;

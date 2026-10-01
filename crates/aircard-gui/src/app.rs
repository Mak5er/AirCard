//! The application state and UI.
//!
//! Layout and styling follow `reference/AirCard-Windows/src/app.rs` closely —
//! same M3 palette ([`crate::theme`]), same two-column card tabs, same status
//! indicators. The one structural difference is the backend: the reference ran
//! each operation on a `std::thread` against a synchronous core, whereas this
//! core is async, so operations are spawned on a Tokio runtime and report back
//! over the same kind of channel.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, channel};

use aircard_core::{
    device::{self, DeviceInfo},
    flasher,
    image_skin::{CARD_HEIGHT, CARD_WIDTH, PreparedSkin},
    passthm::{self, PasscodeTheme},
    scanner::{self, SavedCard},
};
use eframe::egui;

use crate::theme::{self, md3};

#[derive(PartialEq, Eq)]
enum AppTab {
    Wallet,
    Passcode,
    Help,
}

/// Everything a background operation can report back.
enum BackgroundTaskMessage {
    Progress { step: usize, total: usize, message: String },
    Log(String),
    CardFound { hash: String, name: String },
    Devices(Vec<DeviceInfo>),
    Done(Result<String, String>),
}

pub struct AirCardApp {
    /// Drives the async core from egui's synchronous loop.
    rt: tokio::runtime::Runtime,

    current_tab: AppTab,
    apple_status: String,

    // Device management
    devices: Vec<DeviceInfo>,
    selected_udid: Option<String>,

    // Wallet tab
    card_hash: String,
    saved_cards: Vec<SavedCard>,
    source_path: Option<PathBuf>,
    skin: Option<PreparedSkin>,
    skin_texture: Option<egui::TextureHandle>,
    scanning_syslog: bool,
    scan_stop_flag: Option<Arc<AtomicBool>>,

    // Passcode tab
    theme_path: Option<PathBuf>,
    loaded_theme: Option<PasscodeTheme>,
    forced_telephony_ver: String,
    keypad_language: String,
    passcode_bold: bool,
    keypad_textures: Vec<(String, egui::TextureHandle)>,

    // Worker & progress
    is_busy: bool,
    progress_step: usize,
    progress_total: usize,
    progress_msg: String,
    status_msg: String,
    task_rx: Option<Receiver<BackgroundTaskMessage>>,
    logs: Vec<String>,
    show_logs_window: bool,
}

impl AirCardApp {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        theme::setup_custom_theme(&cc.egui_ctx);

        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("building tokio runtime");

        let mut app = Self {
            rt,
            current_tab: AppTab::Wallet,
            apple_status: "Looking for usbmuxd ...".to_string(),
            devices: Vec::new(),
            selected_udid: None,
            card_hash: String::new(),
            saved_cards: scanner::load_saved_cards(),
            source_path: None,
            skin: None,
            skin_texture: None,
            scanning_syslog: false,
            scan_stop_flag: None,
            theme_path: None,
            loaded_theme: None,
            forced_telephony_ver: "Auto (TelephonyUI-10)".to_string(),
            keypad_language: "All Languages (Universal)".to_string(),
            passcode_bold: false,
            keypad_textures: Vec::new(),
            is_busy: false,
            progress_step: 0,
            progress_total: 0,
            progress_msg: String::new(),
            status_msg: "Ready".to_string(),
            task_rx: None,
            logs: Vec::new(),
            show_logs_window: false,
        };
        app.add_log("AirCard-Linux initialized");
        app.add_log(format!("Loaded {} saved card(s)", app.saved_cards.len()));
        app.refresh_devices();
        app
    }

    fn add_log(&mut self, text: impl AsRef<str>) {
        self.logs.push(text.as_ref().to_string());
        if self.logs.len() > 2000 {
            self.logs.drain(0..500);
        }
    }

    fn refresh_devices(&mut self) {
        let (tx, rx) = channel();
        self.task_rx = Some(rx);
        self.apple_status = "Scanning usbmuxd ...".to_string();
        self.rt.spawn(async move {
            let result = device::list_devices().await;
            let _ = tx.send(BackgroundTaskMessage::Devices(result.unwrap_or_default()));
        });
    }

    fn selected_device(&self) -> Option<&DeviceInfo> {
        let udid = self.selected_udid.as_deref()?;
        self.devices.iter().find(|d| d.udid == udid)
    }

    fn select_skin(&mut self, _ctx: &egui::Context) {
        let Some(path) = rfd::FileDialog::new()
            .add_filter("Images", &["png", "jpg", "jpeg", "webp"])
            .set_title("Choose card artwork")
            .pick_file()
        else {
            return;
        };

        match PreparedSkin::from_path(&path) {
            Ok(skin) => {
                self.add_log(format!(
                    "Prepared {} ({}x{} -> {CARD_WIDTH}x{CARD_HEIGHT})",
                    path.display(),
                    skin.source_width,
                    skin.source_height
                ));
                self.status_msg = "Artwork ready".to_string();
                self.skin = Some(skin);
                self.skin_texture = None; // rebuilt from the new bytes in update()
            }
            Err(e) => {
                self.add_log(format!("Image preparation failed: {e:#}"));
                self.status_msg = format!("Failed: {e:#}");
            }
        }
        self.source_path = Some(path);
    }

    fn save_prepared_png(&mut self) {
        let Some(skin) = &self.skin else { return };
        let Some(path) = rfd::FileDialog::new()
            .set_file_name("card-artwork.png")
            .save_file()
        else {
            return;
        };
        match std::fs::write(&path, &skin.png) {
            Ok(()) => {
                self.add_log(format!("Exported prepared card skin PNG: {}", path.display()));
                self.status_msg = "PNG exported".to_string();
            }
            Err(e) => self.add_log(format!("Could not save PNG: {e}")),
        }
    }

    fn toggle_syslog_scan(&mut self) {
        if self.scanning_syslog {
            if let Some(flag) = &self.scan_stop_flag {
                flag.store(true, Ordering::Relaxed);
            }
            self.scanning_syslog = false;
            self.is_busy = false;
            self.status_msg = "Stopping syslog monitor ...".to_string();
            self.add_log("Stopping syslog monitor ...");
            return;
        }

        let udid = self.selected_udid.clone();
        let stop = Arc::new(AtomicBool::new(false));
        self.scan_stop_flag = Some(Arc::clone(&stop));
        self.scanning_syslog = true;
        self.is_busy = true;
        self.status_msg = "Scanning syslog for Wallet events".to_string();

        let (tx, rx) = channel();
        self.task_rx = Some(rx);
        self.add_log("Initiating syslog monitor session...");

        self.rt.spawn(async move {
            let provider = match device::provider_for(udid.as_deref()).await {
                Ok(p) => p,
                Err(e) => {
                    let _ = tx.send(BackgroundTaskMessage::Done(Err(format!("{e:#}"))));
                    return;
                }
            };
            let tx_card = tx.clone();
            let tx_log = tx.clone();
            let result = scanner::scan_syslog_for_cards(
                &provider,
                stop,
                move |hash, name| {
                    let _ = tx_card.send(BackgroundTaskMessage::CardFound { hash, name });
                },
                move |line| {
                    let _ = tx_log.send(BackgroundTaskMessage::Log(line.to_string()));
                },
            )
            .await;
            let _ = tx.send(BackgroundTaskMessage::Done(
                result
                    .map(|_| "Scan stopped".to_string())
                    .map_err(|e| format!("{e:#}")),
            ));
        });
    }

    fn flash_card(&mut self) {
        if self.selected_udid.is_none() {
            self.status_msg = "Flash failed: No connected iPhone selected.".to_string();
            return;
        }
        if self.card_hash.trim().is_empty() {
            self.status_msg = "Flash failed: Target card hash is empty.".to_string();
            return;
        }
        let Some(skin) = self.skin.clone() else {
            self.status_msg = "Flash failed: No skin image prepared.".to_string();
            return;
        };

        let udid = self.selected_udid.clone();
        let hash = self.card_hash.trim().to_string();
        let (tx, rx) = channel();
        self.task_rx = Some(rx);
        self.is_busy = true;
        self.progress_step = 0;
        self.progress_total = 0;
        self.status_msg = "Activating Apple Wallet Skin".to_string();
        self.add_log("Initiating card flash...");

        self.rt.spawn(async move {
            let provider = match device::provider_for(udid.as_deref()).await {
                Ok(p) => p,
                Err(e) => {
                    let _ = tx.send(BackgroundTaskMessage::Done(Err(format!("{e:#}"))));
                    return;
                }
            };
            let tx_progress = tx.clone();
            let tx_log = tx.clone();
            let result = flasher::flash_wallet_skin(
                &provider,
                &hash,
                &skin.png,
                &skin.pdf,
                move |step, total, message| {
                    let _ = tx_progress.send(BackgroundTaskMessage::Progress {
                        step,
                        total,
                        message: message.to_string(),
                    });
                },
                &mut move |line: &str| {
                    let _ = tx_log.send(BackgroundTaskMessage::Log(line.to_string()));
                },
            )
            .await;
            let _ = tx.send(BackgroundTaskMessage::Done(
                result
                    .map(|_| "Card skin applied".to_string())
                    .map_err(|e| format!("{e:#}")),
            ));
        });
    }

    fn select_theme_file(&mut self, ctx: &egui::Context) {
        let Some(path) = rfd::FileDialog::new()
            .add_filter("Passcode theme", &["passthm", "zip"])
            .set_title("Choose a .passthm archive")
            .pick_file()
        else {
            return;
        };
        self.load_theme_from_path(ctx, &path);
    }

    fn load_theme_from_path(&mut self, _ctx: &egui::Context, path: &Path) {
        let version = match self.forced_telephony_ver.as_str() {
            "TelephonyUI-10" | "TelephonyUI-9" | "TelephonyUI-8" => {
                Some(self.forced_telephony_ver.clone())
            }
            _ => None, // "Auto"
        };
        match passthm::parse_passthm_file(path, version.as_deref(), &self.keypad_language, self.passcode_bold)
        {
            Ok(theme) => {
                self.add_log(format!(
                    "Loaded '{}' with {} assets (target: {}, lang: {}, bold: {})",
                    theme.name,
                    theme.items.len(),
                    self.forced_telephony_ver,
                    self.keypad_language,
                    self.passcode_bold
                ));
                self.status_msg = format!("Theme '{}' loaded", theme.name);
                self.keypad_textures.clear();
                self.loaded_theme = Some(theme);
            }
            Err(e) => {
                self.add_log(format!("Failed to parse theme: {e:#}"));
                self.status_msg = format!("Failed: {e:#}");
            }
        }
        self.theme_path = Some(path.to_path_buf());
    }

    fn flash_theme(&mut self) {
        if self.selected_udid.is_none() {
            self.status_msg = "Flash failed: No connected iPhone selected.".to_string();
            return;
        }
        let Some(loaded) = self.loaded_theme.clone() else {
            self.status_msg = "Flash failed: no theme loaded".to_string();
            return;
        };

        let udid = self.selected_udid.clone();
        let theme_name = loaded.name.clone();
        self.add_log(format!(
            "Flashing passcode theme '{}' ({} button assets)",
            theme_name,
            loaded.items.len()
        ));

        let (tx, rx) = channel();
        self.task_rx = Some(rx);
        self.is_busy = true;
        self.progress_step = 0;
        self.progress_total = 0;
        self.status_msg = "Applying skins and dialer keypad packages".to_string();

        self.rt.spawn(async move {
            let provider = match device::provider_for(udid.as_deref()).await {
                Ok(p) => p,
                Err(e) => {
                    let _ = tx.send(BackgroundTaskMessage::Done(Err(format!("{e:#}"))));
                    return;
                }
            };
            let tx_progress = tx.clone();
            let tx_log = tx.clone();
            let result = flasher::flash_passcode_theme(
                &provider,
                &loaded.items,
                move |step, total, message| {
                    let _ = tx_progress.send(BackgroundTaskMessage::Progress {
                        step,
                        total,
                        message: message.to_string(),
                    });
                },
                &mut move |line: &str| {
                    let _ = tx_log.send(BackgroundTaskMessage::Log(line.to_string()));
                },
            )
            .await;
            let _ = tx.send(BackgroundTaskMessage::Done(
                result
                    .map(|_| "Passcode theme applied".to_string())
                    .map_err(|e| format!("{e:#}")),
            ));
        });
    }

    fn handle_messages(&mut self) {
        let Some(rx) = self.task_rx.take() else { return };
        let mut finished = false;

        while let Ok(msg) = rx.try_recv() {
            match msg {
                BackgroundTaskMessage::Progress {
                    step,
                    total,
                    message,
                } => {
                    self.progress_step = step;
                    self.progress_total = total;
                    self.progress_msg = message;
                }
                BackgroundTaskMessage::Log(line) => self.add_log(line),
                BackgroundTaskMessage::CardFound { hash, name } => {
                    self.add_log(format!(
                        "Card captured: {} ({hash})",
                        if name.is_empty() { "unnamed" } else { &name }
                    ));
                    if self.card_hash.trim().is_empty() {
                        self.card_hash = hash;
                    }
                    self.saved_cards = scanner::load_saved_cards();
                }
                BackgroundTaskMessage::Devices(devices) => {
                    self.add_log(format!("Found {} connected device(s)", devices.len()));
                    self.apple_status = if devices.is_empty() {
                        "No devices connected via USB.".to_string()
                    } else {
                        "Loaded and operational".to_string()
                    };
                    if self.selected_udid.is_none() {
                        self.selected_udid = devices.first().map(|d| d.udid.clone());
                    }
                    self.devices = devices;
                }
                BackgroundTaskMessage::Done(result) => {
                    finished = true;
                    match result {
                        Ok(message) => {
                            self.add_log(message.clone());
                            self.status_msg = message;
                        }
                        Err(e) => {
                            self.add_log(format!("Error: {e}"));
                            self.status_msg = format!("Error: {e}");
                        }
                    }
                }
            }
        }

        if finished {
            self.is_busy = false;
            self.scanning_syslog = false;
        } else {
            self.task_rx = Some(rx);
        }
    }

    /// Build the card preview texture from the prepared RGBA, once.
    fn ensure_skin_texture(&mut self, ctx: &egui::Context) {
        if self.skin_texture.is_some() {
            return;
        }
        let Some(skin) = &self.skin else { return };
        let image = egui::ColorImage::from_rgba_unmultiplied(
            [CARD_WIDTH as usize, CARD_HEIGHT as usize],
            &skin.rgba,
        );
        self.skin_texture = Some(ctx.load_texture("card_preview", image, egui::TextureOptions::LINEAR));
    }

    /// Build the per-digit keypad textures from the parsed theme, once.
    fn ensure_keypad_textures(&mut self, ctx: &egui::Context) {
        if !self.keypad_textures.is_empty() {
            return;
        }
        let Some(loaded) = &self.loaded_theme else { return };
        let mut textures = Vec::new();
        for (digit, bytes) in &loaded.key_previews {
            if let Ok(img) = image::load_from_memory(bytes) {
                let rgba = img.to_rgba8();
                let (w, h) = rgba.dimensions();
                let color =
                    egui::ColorImage::from_rgba_unmultiplied([w as usize, h as usize], rgba.as_raw());
                textures.push((
                    digit.clone(),
                    ctx.load_texture(format!("key_{digit}"), color, egui::TextureOptions::LINEAR),
                ));
            }
        }
        textures.sort_by(|a, b| a.0.cmp(&b.0));
        self.keypad_textures = textures;
    }
}

impl eframe::App for AirCardApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.handle_messages();
        self.ensure_skin_texture(ctx);
        self.ensure_keypad_textures(ctx);

        if self.is_busy || self.scanning_syslog {
            ctx.request_repaint_after(std::time::Duration::from_millis(120));
        }

        // ── Header ──────────────────────────────────────────────────────────
        egui::TopBottomPanel::top("header")
            .frame(
                egui::Frame::new()
                    .fill(md3::SURFACE)
                    .inner_margin(egui::Margin::symmetric(20, 10)),
            )
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    ui.label(
                        egui::RichText::new("AirCard")
                            .strong()
                            .size(18.0)
                            .color(md3::ON_SURFACE),
                    );
                    ui.label(
                        egui::RichText::new(env!("CARGO_PKG_VERSION"))
                            .size(11.0)
                            .color(md3::ON_SURFACE_VARIANT),
                    );

                    ui.add_space(20.0);
                    m3_tab(ui, &mut self.current_tab, AppTab::Wallet, "Wallet");
                    m3_tab(ui, &mut self.current_tab, AppTab::Passcode, "Passcode");
                    m3_tab(ui, &mut self.current_tab, AppTab::Help, "Help");

                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if theme::m3_button_outlined(ui, "Refresh") {
                            self.refresh_devices();
                        }
                        ui.add_space(8.0);

                        // Device picker + status dot
                        let devices = self.devices.clone();
                        let label = self
                            .selected_device()
                            .map(|d| d.name.clone())
                            .unwrap_or_else(|| "No device".to_string());
                        let has_device = !devices.is_empty();

                        if has_device {
                            egui::ComboBox::from_id_salt("device_picker")
                                .selected_text(
                                    egui::RichText::new(label).size(12.0).color(md3::ON_SURFACE),
                                )
                                .width(230.0)
                                .show_ui(ui, |ui| {
                                    for d in &devices {
                                        ui.selectable_value(
                                            &mut self.selected_udid,
                                            Some(d.udid.clone()),
                                            format!("{} ({})", d.name, d.product_type),
                                        );
                                    }
                                });
                        } else {
                            ui.label(
                                egui::RichText::new("No device")
                                    .size(12.0)
                                    .color(md3::ON_SURFACE_VARIANT),
                            );
                        }
                        theme::draw_status_dot(
                            ui,
                            if has_device { md3::SUCCESS } else { md3::ERROR },
                        );
                    });
                });
            });

        // ── Status bar ──────────────────────────────────────────────────────
        egui::TopBottomPanel::bottom("status_bar")
            .frame(
                egui::Frame::new()
                    .fill(md3::SURFACE)
                    .inner_margin(egui::Margin::symmetric(20, 8)),
            )
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    let busy = self.is_busy || self.scanning_syslog;
                    let dot_col = if busy {
                        md3::PRIMARY
                    } else if self.status_msg.starts_with("Error")
                        || self.status_msg.starts_with("Failed")
                    {
                        md3::ERROR
                    } else {
                        md3::SUCCESS
                    };
                    theme::draw_status_dot(ui, dot_col);
                    if busy {
                        ui.spinner();
                    }
                    ui.label(
                        egui::RichText::new(&self.status_msg)
                            .size(11.5)
                            .color(md3::ON_SURFACE_VARIANT),
                    );

                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        let btn_text = if self.show_logs_window {
                            "Logs [x]"
                        } else {
                            "Logs"
                        };
                        let btn = egui::Button::new(
                            egui::RichText::new(btn_text).size(11.0).color(
                                if self.show_logs_window {
                                    md3::ON_PRIMARY_CONTAINER
                                } else {
                                    md3::ON_SURFACE_VARIANT
                                },
                            ),
                        )
                        .fill(if self.show_logs_window {
                            md3::PRIMARY_CONTAINER
                        } else {
                            egui::Color32::TRANSPARENT
                        })
                        .corner_radius(20)
                        .stroke(egui::Stroke::new(
                            1.0_f32,
                            if self.show_logs_window {
                                md3::PRIMARY
                            } else {
                                md3::OUTLINE_VARIANT
                            },
                        ));
                        if ui.add(btn).clicked() {
                            self.show_logs_window = !self.show_logs_window;
                        }
                    });
                });
            });

        // ── Central ─────────────────────────────────────────────────────────
        egui::CentralPanel::default()
            .frame(
                egui::Frame::new()
                    .fill(md3::SURFACE)
                    .inner_margin(egui::Margin::same(16)),
            )
            .show(ctx, |ui| {
                egui::ScrollArea::vertical().show(ui, |ui| match self.current_tab {
                    AppTab::Wallet => self.show_wallet_tab(ctx, ui),
                    AppTab::Passcode => self.show_passcode_tab(ctx, ui),
                    AppTab::Help => self.show_help_tab(ui),
                });
            });

        // ── Logs window ─────────────────────────────────────────────────────
        let mut show_logs = self.show_logs_window;
        let mut file_saved_msg: Option<String> = None;
        if show_logs {
            egui::Window::new("Logs")
                .open(&mut show_logs)
                .default_size([540.0, 300.0])
                .min_size([360.0, 180.0])
                .show(ctx, |ui| {
                    ui.horizontal(|ui| {
                        if theme::m3_button_tonal(ui, "Copy Logs") {
                            ctx.copy_text(self.logs.join("\n"));
                        }
                        if theme::m3_button_outlined(ui, "Save to File...") {
                            if let Some(path) = rfd::FileDialog::new()
                                .set_file_name("aircard-diagnostics.log")
                                .add_filter("Log files", &["log", "txt"])
                                .save_file()
                            {
                                let content = self.logs.join("\n");
                                let _ = std::fs::write(&path, content);
                                file_saved_msg =
                                    Some(format!("Saved log file to {}", path.display()));
                            }
                        }
                        if theme::m3_button_outlined(ui, "Clear") {
                            self.logs.clear();
                        }
                        ui.label(
                            egui::RichText::new(format!("{} entries", self.logs.len()))
                                .size(11.0)
                                .color(md3::ON_SURFACE_VARIANT),
                        );
                    });
                    ui.add_space(8.0);
                    egui::Frame::new()
                        .fill(md3::SURFACE_CONTAINER_HIGH)
                        .corner_radius(12)
                        .inner_margin(egui::Margin::same(10))
                        .show(ui, |ui| {
                            egui::ScrollArea::vertical()
                                .stick_to_bottom(true)
                                .auto_shrink([false, false])
                                .show(ui, |ui| {
                                    if self.logs.is_empty() {
                                        ui.label(
                                            egui::RichText::new("No events logged yet.")
                                                .size(11.0)
                                                .color(md3::ON_SURFACE_VARIANT),
                                        );
                                    } else {
                                        for line in &self.logs {
                                            ui.label(
                                                egui::RichText::new(line)
                                                    .size(10.5)
                                                    .monospace()
                                                    .color(md3::ON_SURFACE),
                                            );
                                        }
                                    }
                                });
                        });
                });
            self.show_logs_window = show_logs;
            if let Some(msg) = file_saved_msg {
                self.add_log(msg);
            }
        }
    }
}

/// A pill-shaped tab button.
fn m3_tab(ui: &mut egui::Ui, current: &mut AppTab, target: AppTab, label: &str) {
    let selected = *current == target;
    let (bg, fg) = if selected {
        (md3::SECONDARY_CONTAINER, md3::ON_SECONDARY_CONTAINER)
    } else {
        (egui::Color32::TRANSPARENT, md3::ON_SURFACE_VARIANT)
    };
    let btn = egui::Button::new(egui::RichText::new(label).size(12.5).color(fg))
        .fill(bg)
        .corner_radius(20)
        .stroke(egui::Stroke::NONE);
    if ui.add(btn).clicked() {
        *current = target;
    }
}

impl AirCardApp {
    fn show_wallet_tab(&mut self, ctx: &egui::Context, ui: &mut egui::Ui) {
        // Scanning banner
        if self.scanning_syslog {
            egui::Frame::new()
                .fill(md3::TERTIARY_CONTAINER)
                .corner_radius(16)
                .inner_margin(egui::Margin::same(16))
                .show(ui, |ui| {
                    ui.horizontal(|ui| {
                        ui.spinner();
                        ui.vertical(|ui| {
                            ui.label(
                                egui::RichText::new("Scanning syslog...")
                                    .strong()
                                    .size(13.0)
                                    .color(md3::ON_TERTIARY_CONTAINER),
                            );
                            ui.label(
                                egui::RichText::new("Open Wallet on iPhone and tap your card")
                                    .size(11.5)
                                    .color(md3::ON_TERTIARY_CONTAINER),
                            );
                        });
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            let btn = egui::Button::new(
                                egui::RichText::new("Stop").size(12.0).color(md3::ON_SURFACE),
                            )
                            .fill(md3::ERROR_CONTAINER)
                            .corner_radius(20)
                            .stroke(egui::Stroke::NONE);
                            if ui.add(btn).clicked() {
                                self.toggle_syslog_scan();
                            }
                        });
                    });
                });
            ui.add_space(8.0);
        }

        ui.columns(2, |cols| {
            // ── Left: configuration ─────────────────────────────────────────
            let left = &mut cols[0];
            theme::m3_card(left, |ui| {
                ui.label(
                    egui::RichText::new("Card Configuration")
                        .strong()
                        .size(16.0)
                        .color(md3::ON_SURFACE),
                );
                ui.add_space(4.0);
                ui.label(
                    egui::RichText::new("Target your card and choose replacement artwork")
                        .size(12.0)
                        .color(md3::ON_SURFACE_VARIANT),
                );
                ui.add_space(16.0);

                ui.label(
                    egui::RichText::new("Target Card Hash")
                        .strong()
                        .size(12.0)
                        .color(md3::ON_SURFACE),
                );
                ui.add_space(4.0);
                ui.horizontal(|ui| {
                    let btn_w = 90.0;
                    let text_w = (ui.available_width() - btn_w - 12.0).max(150.0);
                    ui.add(
                        egui::TextEdit::singleline(&mut self.card_hash)
                            .hint_text("Base64 pass hash...")
                            .desired_width(text_w),
                    );

                    // Stays clickable while scanning: starting the scan sets
                    // `is_busy`, so gating on `!is_busy` would grey out "Stop".
                    let scan_label = if self.scanning_syslog { "Stop" } else { "Scan" };
                    let scan_bg = if self.scanning_syslog {
                        md3::ERROR_CONTAINER
                    } else {
                        md3::PRIMARY_CONTAINER
                    };
                    let scan_fg = if self.scanning_syslog {
                        md3::ERROR
                    } else {
                        md3::ON_PRIMARY_CONTAINER
                    };
                    let scan_btn = egui::Button::new(
                        egui::RichText::new(scan_label).size(12.0).color(scan_fg),
                    )
                    .fill(scan_bg)
                    .corner_radius(20)
                    .stroke(egui::Stroke::NONE);
                    if ui.add(scan_btn).clicked() {
                        self.toggle_syslog_scan();
                    }
                });

                if !self.saved_cards.is_empty() {
                    ui.add_space(8.0);
                    ui.label(
                        egui::RichText::new("Saved cards")
                            .size(11.0)
                            .color(md3::ON_SURFACE_VARIANT),
                    );
                    ui.add_space(2.0);
                    let combo_w = (ui.available_width() - 4.0).max(150.0);
                    let sel_label = self
                        .saved_cards
                        .iter()
                        .find(|c| c.hash == self.card_hash)
                        .map(|c| format!("{} ({})", c.name, &c.hash[..8.min(c.hash.len())]))
                        .unwrap_or_else(|| "Select...".into());

                    egui::ComboBox::from_id_salt("saved_cards_box")
                        .width(combo_w)
                        .selected_text(egui::RichText::new(sel_label).color(md3::ON_SURFACE))
                        .show_ui(ui, |ui| {
                            for card in &self.saved_cards {
                                let is_selected = self.card_hash == card.hash;
                                let label = format!(
                                    "{} ({}...)",
                                    card.name,
                                    &card.hash[..8.min(card.hash.len())]
                                );
                                let text = egui::RichText::new(label)
                                    .color(if is_selected {
                                        md3::ON_PRIMARY_CONTAINER
                                    } else {
                                        md3::ON_SURFACE
                                    })
                                    .strong();
                                if ui.selectable_label(is_selected, text).clicked() {
                                    self.card_hash = card.hash.clone();
                                }
                            }
                        });
                }

                ui.add_space(16.0);

                ui.label(
                    egui::RichText::new("Card Skin Artwork")
                        .strong()
                        .size(12.0)
                        .color(md3::ON_SURFACE),
                );
                ui.label(
                    egui::RichText::new("PNG, JPG, WebP - auto-scaled to 1536x969")
                        .size(11.0)
                        .color(md3::ON_SURFACE_VARIANT),
                );
                ui.add_space(4.0);
                ui.horizontal(|ui| {
                    if theme::m3_button_filled(ui, "Choose Image...") {
                        self.select_skin(ctx);
                    }
                    if self.skin.is_some() && theme::m3_button_tonal(ui, "Export PNG") {
                        self.save_prepared_png();
                    }
                });

                if let Some(skin) = &self.skin {
                    ui.add_space(4.0);
                    let fname = self
                        .source_path
                        .as_ref()
                        .and_then(|p| p.file_name())
                        .and_then(|n| n.to_str())
                        .unwrap_or("image");
                    ui.label(
                        egui::RichText::new(format!(
                            "{} - 1536x969 - {:.0} KB",
                            fname,
                            skin.png.len() as f32 / 1024.0
                        ))
                        .size(11.0)
                        .color(md3::PRIMARY),
                    );
                }

                ui.add_space(16.0);

                ui.label(
                    egui::RichText::new("Write to iPhone")
                        .strong()
                        .size(12.0)
                        .color(md3::ON_SURFACE),
                );
                ui.add_space(4.0);

                let can_flash = !self.is_busy
                    && self.selected_udid.is_some()
                    && !self.card_hash.trim().is_empty()
                    && self.skin.is_some();
                let flash_btn = egui::Button::new(
                    egui::RichText::new("Apply Card Skin")
                        .strong()
                        .size(14.0)
                        .color(if can_flash {
                            md3::ON_PRIMARY
                        } else {
                            md3::ON_SURFACE_VARIANT
                        }),
                )
                .fill(if can_flash {
                    md3::PRIMARY
                } else {
                    md3::SURFACE_CONTAINER_HIGH
                })
                .corner_radius(20)
                .stroke(egui::Stroke::NONE)
                .min_size(egui::vec2(ui.available_width(), 40.0));

                let resp = ui.add_enabled(can_flash, flash_btn);
                if resp.clicked() {
                    self.flash_card();
                }
                if !can_flash {
                    let mut need = Vec::new();
                    if self.selected_udid.is_none() {
                        need.push("connect iPhone");
                    }
                    if self.card_hash.trim().is_empty() {
                        need.push("enter card hash");
                    }
                    if self.skin.is_none() {
                        need.push("choose image");
                    }
                    if !need.is_empty() {
                        resp.on_disabled_hover_text(format!("Need: {}", need.join(", ")));
                    }
                }

                if self.is_busy {
                    ui.add_space(8.0);
                    if self.progress_total > 0 {
                        ui.add(
                            egui::ProgressBar::new(
                                self.progress_step as f32 / self.progress_total as f32,
                            )
                            .animate(true),
                        );
                    }
                    ui.label(
                        egui::RichText::new(&self.progress_msg)
                            .size(11.0)
                            .color(md3::PRIMARY),
                    );
                }
            });

            // ── Right: preview ──────────────────────────────────────────────
            let right = &mut cols[1];
            theme::m3_card(right, |ui| {
                ui.label(
                    egui::RichText::new("Wallet Preview")
                        .strong()
                        .size(16.0)
                        .color(md3::ON_SURFACE),
                );
                ui.add_space(4.0);
                ui.label(
                    egui::RichText::new("1536 x 969 px pass canvas")
                        .size(12.0)
                        .color(md3::ON_SURFACE_VARIANT),
                );
                ui.add_space(12.0);

                let pass_w = (ui.available_width() - 8.0).clamp(250.0, 400.0);
                let pass_h = pass_w * (969.0 / 1536.0);
                ui.vertical_centered(|ui| {
                    let (rect, _) = ui
                        .allocate_exact_size(egui::vec2(pass_w, pass_h), egui::Sense::hover());
                    let painter = ui.painter();
                    if let Some(tex) = self.skin_texture.as_ref() {
                        painter.image(
                            tex.id(),
                            rect,
                            egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)),
                            egui::Color32::WHITE,
                        );
                        painter.rect_stroke(
                            rect,
                            16.0,
                            egui::Stroke::new(
                                1.0_f32,
                                egui::Color32::from_rgba_premultiplied(255, 255, 255, 30),
                            ),
                            egui::StrokeKind::Inside,
                        );
                    } else {
                        painter.rect_filled(rect, 16.0, md3::SURFACE_CONTAINER_HIGH);
                        painter.text(
                            rect.center(),
                            egui::Align2::CENTER_CENTER,
                            "No artwork loaded",
                            egui::FontId::proportional(14.0),
                            md3::ON_SURFACE_VARIANT,
                        );
                    }
                });

                ui.add_space(12.0);
                ui.horizontal(|ui| {
                    ui.label(
                        egui::RichText::new("1536x969")
                            .size(11.0)
                            .color(md3::ON_SURFACE_VARIANT),
                    );
                    ui.label(egui::RichText::new("|").size(11.0).color(md3::OUTLINE_VARIANT));
                    ui.label(
                        egui::RichText::new("1.585 ratio")
                            .size(11.0)
                            .color(md3::ON_SURFACE_VARIANT),
                    );
                    ui.label(egui::RichText::new("|").size(11.0).color(md3::OUTLINE_VARIANT));
                    if self.skin.is_some() {
                        ui.label(egui::RichText::new("Ready").size(11.0).color(md3::SUCCESS));
                    } else {
                        ui.label(
                            egui::RichText::new("No image")
                                .size(11.0)
                                .color(md3::ON_SURFACE_VARIANT),
                        );
                    }
                });
                ui.add_space(8.0);
                ui.label(
                    egui::RichText::new("After applying, force close Apple Wallet and reopen it.")
                        .size(11.0)
                        .color(md3::ON_SURFACE_VARIANT),
                );
            });
        });
    }

    fn show_passcode_tab(&mut self, ctx: &egui::Context, ui: &mut egui::Ui) {
        ui.columns(2, |cols| {
            // ── Left: configuration ─────────────────────────────────────────
            let left = &mut cols[0];
            theme::m3_card(left, |ui| {
                ui.label(
                    egui::RichText::new("Passcode Theme")
                        .strong()
                        .size(16.0)
                        .color(md3::ON_SURFACE),
                );
                ui.add_space(4.0);
                ui.label(
                    egui::RichText::new("Custom lockscreen keypad from Cowabunga or Nugget")
                        .size(12.0)
                        .color(md3::ON_SURFACE_VARIANT),
                );
                ui.add_space(16.0);

                ui.label(
                    egui::RichText::new("Theme Package")
                        .strong()
                        .size(12.0)
                        .color(md3::ON_SURFACE),
                );
                ui.label(
                    egui::RichText::new("Choose a .passthm archive containing dialer artwork")
                        .size(11.0)
                        .color(md3::ON_SURFACE_VARIANT),
                );
                ui.add_space(4.0);
                if theme::m3_button_filled(ui, "Choose .passthm...") {
                    self.select_theme_file(ctx);
                }

                if let Some(loaded) = &self.loaded_theme {
                    let fname = self
                        .theme_path
                        .as_ref()
                        .and_then(|p| p.file_name())
                        .and_then(|n| n.to_str())
                        .unwrap_or("theme.passthm");
                    ui.add_space(4.0);
                    ui.label(
                        egui::RichText::new(format!("{} - {} assets", fname, loaded.items.len()))
                            .size(11.0)
                            .color(md3::PRIMARY),
                    );
                }

                ui.add_space(16.0);

                ui.label(
                    egui::RichText::new("Target iOS Cache")
                        .strong()
                        .size(12.0)
                        .color(md3::ON_SURFACE),
                );
                ui.label(
                    egui::RichText::new("Select cache format based on connected iOS version")
                        .size(11.0)
                        .color(md3::ON_SURFACE_VARIANT),
                );
                ui.add_space(4.0);
                let combo_w = (ui.available_width() - 4.0).max(150.0);
                let mut ver_changed = false;
                egui::ComboBox::from_id_salt("telephony_combo")
                    .width(combo_w)
                    .selected_text(&self.forced_telephony_ver)
                    .show_ui(ui, |ui| {
                        for (value, label) in [
                            ("Auto (TelephonyUI-10)", "Auto (TelephonyUI-10)"),
                            ("TelephonyUI-10", "TelephonyUI-10 (iOS 18+)"),
                            ("TelephonyUI-9", "TelephonyUI-9 (iOS 16-17)"),
                            ("TelephonyUI-8", "TelephonyUI-8 (Legacy)"),
                        ] {
                            ver_changed |= ui
                                .selectable_value(
                                    &mut self.forced_telephony_ver,
                                    value.to_string(),
                                    label,
                                )
                                .clicked();
                        }
                    });

                ui.add_space(16.0);

                ui.label(
                    egui::RichText::new("Keypad Language")
                        .strong()
                        .size(12.0)
                        .color(md3::ON_SURFACE),
                );
                ui.label(
                    egui::RichText::new(
                        "Subtext alphabet layout (English, Russian, Ukrainian, Japanese, or Universal)",
                    )
                    .size(11.0)
                    .color(md3::ON_SURFACE_VARIANT),
                );
                ui.add_space(4.0);
                let mut lang_changed = false;
                egui::ComboBox::from_id_salt("keypad_lang_combo")
                    .width(combo_w)
                    .selected_text(
                        egui::RichText::new(&self.keypad_language).color(md3::ON_SURFACE),
                    )
                    .show_ui(ui, |ui| {
                        for option in [
                            "English",
                            "Russian",
                            "Ukrainian",
                            "Japanese",
                            "All Languages (Universal)",
                        ] {
                            lang_changed |= ui
                                .selectable_value(
                                    &mut self.keypad_language,
                                    option.to_string(),
                                    option,
                                )
                                .clicked();
                        }
                    });

                ui.add_space(10.0);

                let mut bold_changed = false;
                ui.horizontal(|ui| {
                    if ui
                        .checkbox(
                            &mut self.passcode_bold,
                            egui::RichText::new("Bold Text (iOS Accessibility)")
                                .strong()
                                .size(12.0)
                                .color(md3::ON_SURFACE),
                        )
                        .changed()
                    {
                        bold_changed = true;
                    }
                });
                ui.label(
                    egui::RichText::new(
                        "Generates *-bold.png for devices with Bold Text turned ON in iPhone Settings -> Display",
                    )
                    .size(11.0)
                    .color(md3::ON_SURFACE_VARIANT),
                );

                // Any of these settings changes what the theme expands to, so
                // re-parse from the file we already have.
                if ver_changed || lang_changed || bold_changed {
                    if let Some(path) = self.theme_path.clone() {
                        self.load_theme_from_path(ctx, &path);
                    }
                }

                ui.add_space(16.0);

                ui.label(
                    egui::RichText::new("Write to iPhone")
                        .strong()
                        .size(12.0)
                        .color(md3::ON_SURFACE),
                );
                ui.add_space(4.0);

                let can_flash =
                    !self.is_busy && self.selected_udid.is_some() && self.loaded_theme.is_some();
                let flash_btn = egui::Button::new(
                    egui::RichText::new("Apply Passcode Theme")
                        .strong()
                        .size(14.0)
                        .color(if can_flash {
                            md3::ON_PRIMARY
                        } else {
                            md3::ON_SURFACE_VARIANT
                        }),
                )
                .fill(if can_flash {
                    md3::PRIMARY
                } else {
                    md3::SURFACE_CONTAINER_HIGH
                })
                .corner_radius(20)
                .stroke(egui::Stroke::NONE)
                .min_size(egui::vec2(ui.available_width(), 40.0));

                let resp = ui.add_enabled(can_flash, flash_btn);
                if resp.clicked() {
                    self.flash_theme();
                }
                if !can_flash {
                    let mut need = Vec::new();
                    if self.selected_udid.is_none() {
                        need.push("connect iPhone");
                    }
                    if self.loaded_theme.is_none() {
                        need.push("select theme");
                    }
                    if !need.is_empty() {
                        resp.on_disabled_hover_text(format!("Need: {}", need.join(", ")));
                    }
                }

                if self.is_busy {
                    ui.add_space(8.0);
                    if self.progress_total > 0 {
                        ui.add(
                            egui::ProgressBar::new(
                                self.progress_step as f32 / self.progress_total as f32,
                            )
                            .animate(true),
                        );
                    }
                    ui.label(
                        egui::RichText::new(&self.progress_msg)
                            .size(11.0)
                            .color(md3::PRIMARY),
                    );
                }
            });

            // ── Right: keypad preview ───────────────────────────────────────
            let right = &mut cols[1];
            theme::m3_card(right, |ui| {
                ui.label(
                    egui::RichText::new("Keypad Preview")
                        .strong()
                        .size(16.0)
                        .color(md3::ON_SURFACE),
                );
                ui.add_space(4.0);
                ui.label(
                    egui::RichText::new("Dialer button artwork")
                        .size(12.0)
                        .color(md3::ON_SURFACE_VARIANT),
                );
                ui.add_space(12.0);

                let pass_w = (ui.available_width() - 8.0).clamp(240.0, 360.0);
                let pass_h = 265.0;

                ui.vertical_centered(|ui| {
                    let (rect, _) = ui
                        .allocate_exact_size(egui::vec2(pass_w, pass_h), egui::Sense::hover());
                    let painter = ui.painter();
                    painter.rect_filled(rect, 16.0, md3::SURFACE_CONTAINER_HIGH);

                    if self.keypad_textures.is_empty() {
                        painter.text(
                            rect.center(),
                            egui::Align2::CENTER_CENTER,
                            "No theme loaded",
                            egui::FontId::proportional(14.0),
                            md3::ON_SURFACE_VARIANT,
                        );
                    } else {
                        ui.scope_builder(egui::UiBuilder::new().max_rect(rect), |ui| {
                            ui.vertical_centered(|ui| {
                                ui.add_space(10.0);
                                const DIALER_LAYOUT: &[&[&str]] = &[
                                    &["1", "2", "3"],
                                    &["4", "5", "6"],
                                    &["7", "8", "9"],
                                    &["", "0", ""],
                                ];
                                egui::Grid::new("keypad_grid")
                                    .spacing([18.0, 6.0])
                                    .show(ui, |ui| {
                                        for row in DIALER_LAYOUT {
                                            for &d in *row {
                                                if d.is_empty() {
                                                    ui.allocate_exact_size(
                                                        egui::vec2(44.0, 50.0),
                                                        egui::Sense::hover(),
                                                    );
                                                } else {
                                                    let tex = self
                                                        .keypad_textures
                                                        .iter()
                                                        .find(|(k, _)| k == d)
                                                        .map(|(_, t)| t.clone());
                                                    ui.vertical_centered(|ui| {
                                                        egui::Frame::new()
                                                            .fill(md3::SURFACE)
                                                            .corner_radius(12)
                                                            .inner_margin(3)
                                                            .show(ui, |ui| match &tex {
                                                                Some(tex) => {
                                                                    ui.image((
                                                                        tex.id(),
                                                                        egui::vec2(40.0, 40.0),
                                                                    ));
                                                                }
                                                                None => {
                                                                    let (btn_rect, _) = ui
                                                                        .allocate_exact_size(
                                                                            egui::vec2(40.0, 40.0),
                                                                            egui::Sense::hover(),
                                                                        );
                                                                    ui.painter().rect_filled(
                                                                        btn_rect,
                                                                        8.0,
                                                                        md3::SURFACE_CONTAINER,
                                                                    );
                                                                    ui.painter().text(
                                                                        btn_rect.center(),
                                                                        egui::Align2::CENTER_CENTER,
                                                                        d,
                                                                        egui::FontId::proportional(
                                                                            14.0,
                                                                        ),
                                                                        md3::ON_SURFACE_VARIANT,
                                                                    );
                                                                }
                                                            });
                                                        ui.label(
                                                            egui::RichText::new(d)
                                                                .size(9.5)
                                                                .color(md3::ON_SURFACE_VARIANT),
                                                        );
                                                    });
                                                }
                                            }
                                            ui.end_row();
                                        }
                                    });
                            });
                        });
                    }
                });

                ui.add_space(12.0);
                ui.horizontal(|ui| {
                    ui.label(
                        egui::RichText::new("3x4 Keypad")
                            .size(11.0)
                            .color(md3::ON_SURFACE_VARIANT),
                    );
                    ui.label(egui::RichText::new("|").size(11.0).color(md3::OUTLINE_VARIANT));
                    ui.label(
                        egui::RichText::new("TelephonyUI")
                            .size(11.0)
                            .color(md3::ON_SURFACE_VARIANT),
                    );
                    ui.label(egui::RichText::new("|").size(11.0).color(md3::OUTLINE_VARIANT));
                    if self.loaded_theme.is_some() {
                        ui.label(egui::RichText::new("Ready").size(11.0).color(md3::SUCCESS));
                    } else {
                        ui.label(
                            egui::RichText::new("No theme")
                                .size(11.0)
                                .color(md3::ON_SURFACE_VARIANT),
                        );
                    }
                });
                ui.add_space(8.0);
                ui.label(
                    egui::RichText::new("After applying, lock your iPhone to see the new keypad.")
                        .size(11.0)
                        .color(md3::ON_SURFACE_VARIANT),
                );
            });
        });
    }

    fn show_help_tab(&mut self, ui: &mut egui::Ui) {
        let width = (ui.available_width() - 8.0).clamp(280.0, 640.0);
        ui.vertical_centered(|ui| {
            ui.allocate_ui_with_layout(
                egui::vec2(width, 0.0),
                egui::Layout::top_down(egui::Align::LEFT),
                |ui| {
                    theme::m3_card(ui, |ui| {
                        ui.label(
                            egui::RichText::new("Activation & Theme Guide")
                                .strong()
                                .size(16.0)
                                .color(md3::ON_SURFACE),
                        );
                        ui.add_space(12.0);
                        for line in [
                            "1. Connect your iPhone over USB, unlock it, and tap \"Trust\" if prompted.",
                            "2. Wallet tab: click Scan, then open Apple Wallet on the phone and tap",
                            "   the card you want to skin. Its hash is captured automatically.",
                            "3. Choose an image, then click Apply Card Skin.",
                            "4. Force-close Wallet on the phone and reopen it.",
                        ] {
                            ui.label(
                                egui::RichText::new(line)
                                    .size(12.0)
                                    .color(md3::ON_SURFACE_VARIANT),
                            );
                        }
                        ui.add_space(16.0);
                        ui.label(
                            egui::RichText::new("Passcode Themes")
                                .strong()
                                .size(14.0)
                                .color(md3::ON_SURFACE),
                        );
                        ui.add_space(6.0);
                        for line in [
                            "1. Open the Passcode tab and choose a .passthm file.",
                            "2. Pick the keypad language and target cache version.",
                            "3. Click Apply Passcode Theme, then lock the phone.",
                            "Note: turn Bold Text OFF in iOS Settings for cached keypad art to be used.",
                        ] {
                            ui.label(
                                egui::RichText::new(line)
                                    .size(12.0)
                                    .color(md3::ON_SURFACE_VARIANT),
                            );
                        }
                        ui.add_space(16.0);
                        ui.label(
                            egui::RichText::new("How it works")
                                .strong()
                                .size(14.0)
                                .color(md3::ON_SURFACE),
                        );
                        ui.add_space(6.0);
                        ui.label(
                            egui::RichText::new(
                                "AirCard uses the AirTraffic (Books) sync path to write files \
                                 outside the normal sandbox. Before every write the device's \
                                 Books state is snapshotted and restored afterwards, and all \
                                 staged files are removed.",
                            )
                            .size(12.0)
                            .color(md3::ON_SURFACE_VARIANT),
                        );
                        ui.add_space(10.0);
                        ui.label(
                            egui::RichText::new("Protocol reference: docs/airtraffic-protocol.md")
                                .size(11.0)
                                .color(md3::PRIMARY),
                        );
                    });
                },
            );
        });
    }
}

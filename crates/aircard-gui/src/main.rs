//! AirCard-Linux desktop GUI.
//!
//! Port of `reference/AirCard-Windows/src/app.rs`. The reference ran each
//! backend operation on a `std::thread`; the core here is async, so operations
//! are spawned on a Tokio runtime and report back over the same kind of channel.

mod app;
mod theme;

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1000.0, 700.0])
            .with_min_inner_size([820.0, 560.0])
            .with_title("AirCard-Linux"),
        ..Default::default()
    };

    eframe::run_native(
        "AirCard-Linux",
        options,
        Box::new(|cc| Ok(Box::new(app::AirCardApp::new(cc)))),
    )
}

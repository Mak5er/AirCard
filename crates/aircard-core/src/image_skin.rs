//! Card artwork preparation: centre-crop, resize, PNG + PDF encode.
//!
//! Ported from `reference/AirCard-Windows/src/image_skin.rs`. The only change is
//! that the preview is returned as raw RGBA rather than an `egui::ColorImage`,
//! so the core crate stays GUI-free — the GUI wraps these bytes itself.

use std::io::Cursor;
use std::path::Path;

use anyhow::{Context, Result};
use image::{DynamicImage, GenericImageView, ImageFormat, imageops::FilterType};

/// Apple Wallet card artwork dimensions.
pub const CARD_WIDTH: u32 = 1_536;
pub const CARD_HEIGHT: u32 = 969;

/// Everything needed to flash one card skin.
#[derive(Clone)]
pub struct PreparedSkin {
    /// `cardBackgroundCombined@2x/@3x.png` payload.
    pub png: Vec<u8>,
    /// `cardBackgroundCombined.pdf` payload.
    pub pdf: Vec<u8>,
    pub source_width: u32,
    pub source_height: u32,
    /// Final artwork as raw RGBA (`CARD_WIDTH * CARD_HEIGHT * 4`), for preview.
    pub rgba: Vec<u8>,
}

impl PreparedSkin {
    pub fn from_path(path: &Path) -> Result<Self> {
        let image =
            image::open(path).with_context(|| format!("could not decode {}", path.display()))?;
        Self::from_image(image)
    }

    pub fn from_image(image: DynamicImage) -> Result<Self> {
        let (source_width, source_height) = image.dimensions();
        let cropped = center_crop_for_card(image);
        let resized = cropped.resize_exact(CARD_WIDTH, CARD_HEIGHT, FilterType::Lanczos3);
        let rgba_image = resized.to_rgba8();
        let rgba = rgba_image.as_raw().clone();

        let mut png = Vec::new();
        DynamicImage::ImageRgba8(rgba_image)
            .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
            .context("encoding prepared PNG")?;

        let pdf = png_to_pdf(&png).context("generating card PDF artwork")?;

        Ok(Self {
            png,
            pdf,
            source_width,
            source_height,
            rgba,
        })
    }
}

/// Wrap a PNG as a single-page PDF with one image XObject.
///
/// Written by hand (rather than pulling in a PDF crate) exactly as the Windows
/// build did, so the byte layout the device sees is unchanged.
pub fn png_to_pdf(png_bytes: &[u8]) -> Result<Vec<u8>> {
    let img = image::load_from_memory(png_bytes).context("decoding image for PDF")?;
    let rgb = img.to_rgb8();
    let width = rgb.width();
    let height = rgb.height();
    let raw = rgb.into_raw();
    let stream = miniz_oxide::deflate::compress_to_vec_zlib(&raw, 6);

    let mut pdf: Vec<u8> = Vec::new();
    pdf.extend_from_slice(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");

    let mut offsets: Vec<usize> = Vec::new();

    offsets.push(pdf.len());
    pdf.extend_from_slice(b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    offsets.push(pdf.len());
    pdf.extend_from_slice(b"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    offsets.push(pdf.len());
    pdf.extend_from_slice(
        format!(
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] \
             /Contents 4 0 R /Resources << /XObject << /Im0 5 0 R >> >> >>\nendobj\n"
        )
        .as_bytes(),
    );

    offsets.push(pdf.len());
    let content = format!("q\n{width} 0 0 {height} 0 0 cm\n/Im0 Do\nQ\n");
    pdf.extend_from_slice(
        format!(
            "4 0 obj\n<< /Length {} >>\nstream\n{content}endstream\nendobj\n",
            content.len()
        )
        .as_bytes(),
    );

    offsets.push(pdf.len());
    pdf.extend_from_slice(
        format!(
            "5 0 obj\n<< /Type /XObject /Subtype /Image /Width {width} /Height {height} \
             /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length {} >>\nstream\n",
            stream.len()
        )
        .as_bytes(),
    );
    pdf.extend_from_slice(&stream);
    pdf.extend_from_slice(b"\nendstream\nendobj\n");

    let xref_offset = pdf.len();
    pdf.extend_from_slice(format!("xref\n0 {}\n", offsets.len() + 1).as_bytes());
    pdf.extend_from_slice(b"0000000000 65535 f \n");
    for offset in &offsets {
        pdf.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
    }

    pdf.extend_from_slice(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n",
            offsets.len() + 1
        )
        .as_bytes(),
    );

    Ok(pdf)
}

fn center_crop_for_card(image: DynamicImage) -> DynamicImage {
    let (width, height) = image.dimensions();
    let card_ratio = CARD_WIDTH as f64 / CARD_HEIGHT as f64;
    let source_ratio = width as f64 / height as f64;

    if source_ratio > card_ratio {
        let crop_width = (height as f64 * card_ratio).round() as u32;
        let x = (width - crop_width) / 2;
        image.crop_imm(x, 0, crop_width, height)
    } else {
        let crop_height = (width as f64 / card_ratio).round() as u32;
        let y = (height - crop_height) / 2;
        image.crop_imm(0, y, width, crop_height)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_to_pdf_structure() {
        let dummy = DynamicImage::new_rgb8(10, 10);
        let mut png = Vec::new();
        dummy
            .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
            .unwrap();

        let pdf = png_to_pdf(&png).expect("png_to_pdf");
        assert!(pdf.starts_with(b"%PDF-1.4"));
        assert!(pdf.ends_with(b"%%EOF\n"));
        let text = String::from_utf8_lossy(&pdf);
        assert!(text.contains("/FlateDecode"));
        assert!(text.contains("/MediaBox [0 0 10 10]"));
        assert!(text.contains("xref"));
    }

    #[test]
    fn prepared_skin_has_card_dimensions() {
        let dummy = DynamicImage::new_rgb8(4000, 1000);
        let skin = PreparedSkin::from_image(dummy).expect("prepare skin");
        assert_eq!(skin.rgba.len(), (CARD_WIDTH * CARD_HEIGHT * 4) as usize);
        assert_eq!(skin.source_width, 4000);
        assert_eq!(skin.source_height, 1000);
        assert!(!skin.png.is_empty());
        assert!(!skin.pdf.is_empty());
    }

    #[test]
    fn centre_crop_matches_card_aspect() {
        // Very wide source: cropped to the card ratio, height preserved.
        let cropped = center_crop_for_card(DynamicImage::new_rgb8(4000, 1000));
        let (w, h) = cropped.dimensions();
        assert_eq!(h, 1000);
        let expected = (1000.0 * CARD_WIDTH as f64 / CARD_HEIGHT as f64).round() as u32;
        assert_eq!(w, expected);
    }
}

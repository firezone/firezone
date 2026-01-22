//! A minimal graphics compositor for the little 32x32 tray icons
//!
//! It's common for web apps like Discord, Element, and Slack to composite
//! their favicons in an offscreen HTML5 canvas, so that they can layer
//! notification dots and other stuff over the logo, without maintaining
//! multiple nearly-identical graphics assets.
//!
//! Using the HTML5 canvas in Tauri would make us depend on it too much,
//! and the math for compositing RGBA images in a mostly-gamma-correct way
//! is simple enough to just replicate it here.

use std::io;

use anyhow::{Context as _, Result, ensure};

pub struct Image {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Builds up an image via painter's algorithm
///
/// <https://en.wikipedia.org/wiki/Painter%27s_algorithm>
///
/// # Args
///
/// - `layers` - An iterator of PNG-compressed layers. We assume alpha is NOT pre-multiplied because Figma doesn't seem to export pre-multiplied images.
///
/// # Returns
///
/// An `Image` with the same dimensions as the first layer.
pub fn compose<'a, I: IntoIterator<Item = &'a [u8]>>(layers: I) -> Result<Image> {
    let mut dst = None;

    for layer in layers {
        // Decode the metadata for this PNG layer
        let decoder = png::Decoder::new(io::Cursor::new(layer));
        let mut reader = decoder.read_info()?;
        let info = reader.info();

        let size = reader
            .output_buffer_size()
            .context("Failed to get output buffer size")?;

        // Create the output buffer if needed
        let dst = dst.get_or_insert_with(|| Image {
            width: info.width,
            height: info.height,
            rgba: vec![0; size],
        });

        ensure!(info.width == dst.width);
        ensure!(info.height == dst.height);

        // Decompress the PNG layer
        let mut rgba = vec![0; dst.rgba.len()];
        let info = reader.next_frame(&mut rgba)?;
        ensure!(info.buffer_size() == rgba.len());

        // Do the actual composite
        // Do all the math with floats so it's easier to write and read the code
        let gamma = 2.2;
        let inv_gamma = 1.0 / gamma;

        for (src, dst) in rgba.chunks_exact(4).zip(dst.rgba.chunks_exact_mut(4)) {
            let src_a = src[3] as f32 / 255.0;

            for (src_int, dst_int) in (src[0..3]).iter().zip(&mut dst[0..3]) {
                let src_c = *src_int as f32 / 255.0;
                let dst_c = *dst_int as f32 / 255.0;

                // Convert from gamma to linear space
                let src_c = src_c.powf(gamma);
                let dst_c = dst_c.powf(gamma);

                // Linear interp between the src and dst colors depending on the src alpha
                let dst_c = src_c * src_a + dst_c * (1.0 - src_a);

                // Convert back to gamma space and clamp / saturate
                let dst_c = dst_c.powf(inv_gamma).clamp(0.0, 1.0);

                *dst_int = (dst_c * 255.0) as u8;
            }

            // Add the source alpha into the dest alpha
            dst[3] = dst[3].saturating_add(src[3]);
        }
    }

    dst.context("No layers")
}

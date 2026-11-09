//! The tokens of `main.css`, converted from OKLCH to sRGB.

use freya::prelude::Color;

pub struct Palette {
    /// What the webview shows around the window's rounded corners.
    pub outside: Color,
    pub canvas: Color,
    pub surface: Color,
    pub raised: Color,
    pub overlay: Color,
    pub border: Color,
    pub border_strong: Color,
    pub border_emphasis: Color,
    pub heading: Color,
    pub body: Color,
    pub subtle: Color,
    pub muted: Color,
    pub brand: Color,
    pub brand_muted: Color,
    pub danger: Color,
    pub error: Color,
    pub warning: Color,
    pub control_bg: Color,
    pub control_border: Color,
    pub focus: Color,
    pub scroll_track: Color,
    pub scroll_thumb: Color,
}

const fn rgba(r: u8, g: u8, b: u8, percent: u16) -> Color {
    Color::from_argb((percent * 255 / 100) as u8, r, g, b)
}

const fn rgb(r: u8, g: u8, b: u8) -> Color {
    Color::from_rgb(r, g, b)
}

pub const LIGHT: Palette = Palette {
    outside: rgb(255, 255, 255),
    canvas: rgb(238, 241, 246),
    surface: rgb(255, 255, 255),
    raised: rgb(247, 249, 252),
    overlay: rgb(255, 255, 255),
    border: rgba(15, 23, 42, 8),
    border_strong: rgba(15, 23, 42, 16),
    border_emphasis: rgba(15, 23, 42, 28),
    heading: rgb(15, 23, 42),
    body: rgb(71, 85, 105),
    subtle: rgb(110, 129, 151),
    muted: rgb(165, 176, 186),
    brand: rgb(255, 118, 5),
    brand_muted: rgb(255, 249, 245),
    danger: rgb(220, 38, 38),
    error: rgb(220, 38, 38),
    warning: rgb(217, 119, 6),
    control_bg: rgb(255, 255, 255),
    control_border: rgba(15, 23, 42, 16),
    focus: rgb(255, 118, 5),
    scroll_track: rgb(252, 252, 252),
    scroll_thumb: rgb(139, 139, 139),
};

pub const DARK: Palette = Palette {
    outside: rgb(18, 18, 18),
    canvas: rgb(8, 12, 20),
    surface: rgb(15, 22, 35),
    raised: rgb(23, 32, 50),
    overlay: rgb(30, 42, 63),
    border: rgba(241, 245, 249, 7),
    border_strong: rgba(241, 245, 249, 12),
    border_emphasis: rgba(241, 245, 249, 22),
    heading: rgb(241, 245, 249),
    body: rgb(148, 163, 184),
    subtle: rgb(78, 99, 122),
    muted: rgb(45, 63, 82),
    brand: rgb(255, 154, 71),
    brand_muted: rgba(255, 118, 5, 12),
    danger: rgb(220, 38, 38),
    error: rgb(248, 113, 113),
    warning: rgb(217, 119, 6),
    control_bg: rgb(23, 32, 50),
    control_border: rgba(241, 245, 249, 12),
    focus: rgb(255, 154, 71),
    scroll_track: rgb(44, 44, 44),
    scroll_thumb: rgb(159, 159, 159),
};

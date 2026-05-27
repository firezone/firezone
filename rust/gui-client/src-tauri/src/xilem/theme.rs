//! Firezone light-mode palette + default widget properties for the xilem GUI,
//! mirroring the iced client's `theme::LIGHT` tokens (mapped from the admin
//! portal's CSS).
//!
//! [`properties`] builds the app-wide theme handed to
//! `Xilem::with_default_properties`, so widgets pick up the Firezone look by
//! default; `ui.rs` only overrides per-instance exceptions (primary buttons,
//! the active nav item, secondary/warning text).

use xilem::Color;
use xilem::masonry::core::DefaultProperties;
use xilem::masonry::properties::{
    ActiveBackground, Background, BorderColor, BorderWidth, CaretColor, CheckmarkColor,
    ContentColor, CornerRadius, HoveredBorderColor, Padding,
};
use xilem::masonry::widgets::{Button, Checkbox, Label, TextArea, TextInput};

const fn rgb(r: u8, g: u8, b: u8) -> Color {
    Color::from_rgba8(r, g, b, 0xff)
}

/// App background behind the content area.
pub const CANVAS: Color = rgb(0xee, 0xf1, 0xf6);
/// Sidebar / card surface.
pub const SURFACE: Color = rgb(0xff, 0xff, 0xff);
/// Slightly raised surface (active nav item, secondary buttons).
pub const SURFACE_RAISED: Color = rgb(0xf7, 0xf9, 0xfc);
pub const TEXT_PRIMARY: Color = rgb(0x0f, 0x17, 0x2a);
pub const TEXT_SECONDARY: Color = rgb(0x47, 0x55, 0x69);
pub const TEXT_MUTED: Color = rgb(0xa5, 0xb0, 0xba);
/// Brand orange ("heat wave 500").
pub const BRAND: Color = rgb(0xff, 0x76, 0x05);
/// Darker brand, used for the active nav item's text.
pub const BRAND_HOVER: Color = rgb(0xc2, 0x57, 0x00);
pub const STATUS_WARN: Color = rgb(0xd9, 0x77, 0x06);
/// Text drawn on top of the brand colour (primary buttons).
pub const ON_BRAND: Color = rgb(0xff, 0xff, 0xff);
/// Subtle border for secondary buttons and inputs.
pub const BORDER: Color = rgb(0xcb, 0xd5, 0xe1);

/// App-wide default widget properties: a light Firezone theme.
///
/// Starts from masonry's (dark) `default_property_set` to keep its structural
/// defaults (padding, radii, stroke widths for widgets we don't touch) and
/// overrides the colours of the widgets this UI actually uses. Without this,
/// inputs/labels would render near-white text (the dark default) on our light
/// surfaces.
pub fn properties() -> DefaultProperties {
    let mut p = xilem::masonry::theme::default_property_set();

    // Buttons default to the light "secondary" look; `ui::primary_button` and
    // `ui::nav_item` override per-instance.
    p.insert::<Button, _>(Background::Color(SURFACE_RAISED));
    p.insert::<Button, _>(ActiveBackground(Background::Color(BORDER)));
    p.insert::<Button, _>(BorderColor::new(BORDER));
    p.insert::<Button, _>(HoveredBorderColor(BorderColor::new(BRAND)));
    p.insert::<Button, _>(BorderWidth::all(1.0));
    p.insert::<Button, _>(CornerRadius::all(8.0));
    p.insert::<Button, _>(Padding::from_vh(10.0, 16.0));

    // Text (labels + button labels) defaults to the primary ink colour.
    p.insert::<Label, _>(ContentColor::new(TEXT_PRIMARY));
    // The editable/non-editable text widgets behind `text_input` / prose.
    p.insert::<TextArea<true>, _>(ContentColor::new(TEXT_PRIMARY));
    p.insert::<TextArea<true>, _>(CaretColor {
        color: TEXT_PRIMARY,
    });
    p.insert::<TextArea<false>, _>(ContentColor::new(TEXT_PRIMARY));

    // Light text inputs.
    p.insert::<TextInput, _>(Background::Color(SURFACE));
    p.insert::<TextInput, _>(BorderColor::new(BORDER));
    p.insert::<TextInput, _>(BorderWidth::all(1.0));
    p.insert::<TextInput, _>(CornerRadius::all(6.0));

    // Light checkboxes with a brand checkmark.
    p.insert::<Checkbox, _>(Background::Color(SURFACE));
    p.insert::<Checkbox, _>(BorderColor::new(BORDER));
    p.insert::<Checkbox, _>(CheckmarkColor { color: BRAND });

    p
}

//! Animated toggle.
//!
//! Iced 0.14's built-in `iced::widget::toggler` snaps between off
//! and on with no interpolation. We render our own toggle using
//! existing primitives — a rounded `container` for the track with a
//! smaller circular `container` for the thumb — so we can drive the
//! thumb's offset from an `Animation<bool>` and lerp the track
//! colour as the animation progresses.

use std::time::Instant;

use iced::animation::Animation;
use iced::widget::{Space, container, mouse_area, row};
use iced::{Background, Border, Center, Color, Element, Length, Theme};

use crate::iced::Message;
use crate::iced::theme::Tokens;

const TRACK_W: f32 = 38.0;
const TRACK_H: f32 = 22.0;
const THUMB_SIZE: f32 = 16.0;
const PADDING: f32 = 3.0;

/// Linear interpolation between two colours in linear (sRGB-component)
/// space. Good enough for the toggle's grey→brand sweep.
fn lerp_color(a: Color, b: Color, t: f32) -> Color {
    let t = t.clamp(0.0, 1.0);
    Color {
        r: a.r + (b.r - a.r) * t,
        g: a.g + (b.g - a.g) * t,
        b: a.b + (b.b - a.b) * t,
        a: a.a + (b.a - a.a) * t,
    }
}

/// Builds an animated toggle element.
///
/// * `anim` carries the currently-animating state; its `interpolate`
///   call samples the eased thumb position at `now`.
/// * `current` is the logical state; clicks emit `on_toggle(!current)`.
/// * `enabled = false` greys the track and ignores clicks (matching
///   the behaviour of iced's `toggler` when its `on_toggle` is unset).
pub fn animated_toggle<'a, F>(
    anim: &Animation<bool>,
    current: bool,
    enabled: bool,
    on_toggle: F,
    theme: Tokens,
) -> Element<'a, Message>
where
    F: Fn(bool) -> Message + 'a,
{
    let now = Instant::now();
    let progress = anim.interpolate(0.0, 1.0, now);

    // Off-state track is `text_muted` (a medium grey) rather than
    // `surface_raised` (near-white) so a white thumb has visible
    // contrast against the canvas background; on-state is the brand
    // orange. Disabled toggles drop alpha to half on the same lerp.
    let off = theme.text_muted;
    let on = theme.brand;
    let track_color = if enabled {
        lerp_color(off, on, progress)
    } else {
        Color {
            a: 0.5,
            ..lerp_color(off, on, progress)
        }
    };
    let thumb_color = Color::WHITE;

    let max_offset = TRACK_W - THUMB_SIZE - 2.0 * PADDING;
    let thumb_offset = max_offset * progress;

    let thumb = container(Space::new())
        .width(Length::Fixed(THUMB_SIZE))
        .height(Length::Fixed(THUMB_SIZE))
        .style(move |_theme: &Theme| container::Style {
            background: Some(Background::Color(thumb_color)),
            border: Border {
                color: Color::TRANSPARENT,
                width: 0.0,
                radius: (THUMB_SIZE / 2.0).into(),
            },
            ..container::Style::default()
        });

    let row_inner = row![Space::new().width(Length::Fixed(thumb_offset)), thumb,].align_y(Center);

    let track = container(row_inner)
        .width(Length::Fixed(TRACK_W))
        .height(Length::Fixed(TRACK_H))
        .padding(PADDING)
        .style(move |_theme: &Theme| container::Style {
            background: Some(Background::Color(track_color)),
            border: Border {
                color: Color::TRANSPARENT,
                width: 0.0,
                radius: (TRACK_H / 2.0).into(),
            },
            ..container::Style::default()
        });

    if enabled {
        mouse_area(track).on_press(on_toggle(!current)).into()
    } else {
        track.into()
    }
}

/// Returns true if `anim` is mid-transition at `now`. The application
/// uses this to decide whether to subscribe to per-frame redraws.
pub fn is_animating(anim: &Animation<bool>, now: Instant) -> bool {
    anim.is_animating(now)
}

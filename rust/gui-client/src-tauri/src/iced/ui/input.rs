//! Shared style for `text_input` widgets, matching the Elixir admin
//! portal's `<.input>` Phoenix component:
//!
//! ```text
//! block rounded-md text-sm px-3 py-2
//! bg-[var(--control-bg)]
//! text-[var(--text-primary)] placeholder:text-[var(--text-muted)]
//! border border-[var(--control-border)]
//! outline-none transition-colors
//! focus:border-[var(--control-focus)] focus:ring-1 ...
//! ```

use iced::widget::text_input::{Status, Style};
use iced::{Background, Border, Theme};

use crate::theme::Tokens;

pub fn style(_theme: &Theme, status: Status, tokens: Tokens) -> Style {
    let is_focused = matches!(status, Status::Focused { .. });
    let is_hovered = matches!(status, Status::Hovered);
    let is_disabled = matches!(status, Status::Disabled);
    let border_color = if is_disabled {
        tokens.text_muted
    } else if is_focused {
        tokens.brand
    } else if is_hovered {
        tokens.text_tertiary
    } else {
        tokens.text_muted
    };
    let bg = if is_disabled {
        tokens.surface_raised
    } else {
        tokens.surface
    };
    let value = if is_disabled {
        tokens.text_tertiary
    } else {
        tokens.text_primary
    };

    Style {
        background: Background::Color(bg),
        border: Border {
            color: border_color,
            width: 1.0,
            radius: 6.0.into(),
        },
        icon: tokens.text_muted,
        placeholder: tokens.text_muted,
        value,
        selection: tokens.brand,
    }
}

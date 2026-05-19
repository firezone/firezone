//! Overview screen — sign in / sign out flow.

use iced::widget::{Space, column, container, text};
use iced::{Center, Element, Length};

use crate::Message;
use crate::state::{App, Session};
use crate::theme;
use crate::ui::button::{Variant, fz_button};

pub fn view(app: &App) -> Element<'_, Message> {
    let session: Element<'_, Message> = match &app.session {
        Session::SignedOut => signed_out(),
        Session::Loading => loading(),
        Session::SignedIn {
            account_slug,
            actor_name,
        } => signed_in(account_slug, actor_name),
    };

    container(
        column![
            text("Firezone").size(48).color(theme::LIGHT.text_primary),
            Space::new().height(24),
            session,
        ]
        .align_x(Center)
        .spacing(16),
    )
    .center_x(Length::Fill)
    .center_y(Length::Fill)
    .into()
}

fn signed_out<'a>() -> Element<'a, Message> {
    column![
        text(
            "You can sign in by clicking the Firezone icon in the taskbar \
             or by clicking \"Sign in\" below."
        )
        .size(14)
        .color(theme::LIGHT.text_secondary),
        Space::new().height(8),
        fz_button(
            "Sign in",
            Variant::Primary,
            Message::SignInPressed,
            theme::LIGHT,
        ),
        Space::new().height(8),
        text(
            "Firezone will continue running after this window is closed. \
             It is always available from the taskbar."
        )
        .size(11)
        .color(theme::LIGHT.text_tertiary),
    ]
    .spacing(8)
    .align_x(Center)
    .into()
}

fn loading<'a>() -> Element<'a, Message> {
    column![
        text("Signing in…")
            .size(14)
            .color(theme::LIGHT.text_secondary),
        Space::new().height(8),
        text(
            "Firezone will continue running in the taskbar after this \
             window is closed."
        )
        .size(11)
        .color(theme::LIGHT.text_tertiary),
    ]
    .spacing(8)
    .align_x(Center)
    .into()
}

fn signed_in<'a>(account_slug: &'a str, actor_name: &'a str) -> Element<'a, Message> {
    column![
        text(format!(
            "You are currently signed into {account_slug} as {actor_name}.\n\
             Click the Firezone icon in the taskbar to see the list of Resources."
        ))
        .size(14)
        .color(theme::LIGHT.text_secondary),
        Space::new().height(8),
        fz_button(
            "Sign out",
            Variant::Secondary,
            Message::SignOutPressed,
            theme::LIGHT,
        ),
        Space::new().height(8),
        text(
            "Firezone will continue running in the taskbar after this \
             window is closed."
        )
        .size(11)
        .color(theme::LIGHT.text_tertiary),
    ]
    .spacing(8)
    .align_x(Center)
    .into()
}

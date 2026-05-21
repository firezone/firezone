//! Overview screen — sign in / sign out flow.

use iced::widget::{Space, column, container, image, row, text};
use iced::{Center, Element, Font, Length};

use crate::Message;
use crate::assets;
use crate::state::{App, Session};
use crate::theme;
use crate::ui::button::{Variant, fz_button};

fn bold() -> Font {
    Font {
        weight: iced::font::Weight::Bold,
        ..assets::font()
    }
}

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
            image(assets::logo()).width(160).height(160),
            text("Firezone").size(48).color(theme::LIGHT.text_primary),
            Space::new().height(16),
            session,
        ]
        .align_x(Center)
        .spacing(8),
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
        .color(theme::LIGHT.text_secondary)
        .align_x(Center),
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
        .color(theme::LIGHT.text_tertiary)
        .align_x(Center),
    ]
    .spacing(8)
    .align_x(Center)
    .into()
}

fn loading<'a>() -> Element<'a, Message> {
    column![
        text("Signing in…")
            .size(14)
            .color(theme::LIGHT.text_secondary)
            .align_x(Center),
        Space::new().height(8),
        text(
            "Firezone will continue running in the taskbar after this \
             window is closed."
        )
        .size(11)
        .color(theme::LIGHT.text_tertiary)
        .align_x(Center),
    ]
    .spacing(8)
    .align_x(Center)
    .into()
}

fn signed_in<'a>(account_slug: &'a str, actor_name: &'a str) -> Element<'a, Message> {
    // Use a horizontal row so just the account slug + actor name are
    // bold; the surrounding prose stays at regular weight.
    let label = |s: &'a str| text(s).size(14).color(theme::LIGHT.text_secondary);
    let bold_label = |s: &'a str| {
        text(s)
            .size(14)
            .font(bold())
            .color(theme::LIGHT.text_primary)
    };
    let header = row![
        label("You are currently signed into "),
        bold_label(account_slug),
        label(" as "),
        bold_label(actor_name),
        label("."),
    ]
    .align_y(Center);

    column![
        header,
        text("Click the Firezone icon in the taskbar to see the list of Resources.")
            .size(14)
            .color(theme::LIGHT.text_secondary)
            .align_x(Center),
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
        .color(theme::LIGHT.text_tertiary)
        .align_x(Center),
    ]
    .spacing(8)
    .align_x(Center)
    .into()
}

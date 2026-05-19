//! General settings screen.

use iced::widget::{Space, column, container, row, text, text_input, toggler};
use iced::{Element, Length};

use crate::Message;
use crate::state::App;
use crate::theme;
use crate::ui::button::{Variant, fz_button};

pub fn view(app: &App) -> Element<'_, Message> {
    let s = &app.general_settings;

    container(
        column![
            field_label("Account slug"),
            text_input("", &s.account_slug)
                .on_input_maybe(if s.account_slug_is_managed {
                    None
                } else {
                    Some(Message::GeneralSettingsAccountSlugChanged)
                })
                .padding(8),
            managed_hint(s.account_slug_is_managed),
            Space::new().height(16),
            toggle_row(
                "Start minimized",
                s.start_minimized,
                Message::GeneralSettingsStartMinimizedToggled,
                false,
            ),
            toggle_row(
                "Start on login",
                s.start_on_login,
                Message::GeneralSettingsStartOnLoginToggled,
                false,
            ),
            toggle_row(
                "Connect on start",
                s.connect_on_start,
                Message::GeneralSettingsConnectOnStartToggled,
                s.connect_on_start_is_managed,
            ),
            Space::new().height(24),
            row![
                fz_button(
                    "Save",
                    Variant::Primary,
                    Message::GeneralSettingsSave,
                    theme::LIGHT,
                ),
                fz_button(
                    "Reset to defaults",
                    Variant::Secondary,
                    Message::GeneralSettingsReset,
                    theme::LIGHT,
                ),
            ]
            .spacing(8),
        ]
        .spacing(4),
    )
    .width(Length::Fill)
    .padding(16)
    .into()
}

fn field_label<'a>(label: &'a str) -> Element<'a, Message> {
    text(label)
        .size(13)
        .color(theme::LIGHT.text_secondary)
        .into()
}

fn managed_hint(is_managed: bool) -> Element<'static, Message> {
    if is_managed {
        text("Managed by your administrator")
            .size(11)
            .color(theme::LIGHT.text_tertiary)
            .into()
    } else {
        Space::new().height(0).into()
    }
}

fn toggle_row<'a, F>(
    label: &'a str,
    value: bool,
    on_toggle: F,
    managed: bool,
) -> Element<'a, Message>
where
    F: 'a + Fn(bool) -> Message,
{
    let mut t = toggler(value).size(20);
    if !managed {
        t = t.on_toggle(on_toggle);
    }
    row![
        text(label).size(14).color(theme::LIGHT.text_primary),
        Space::new().width(Length::Fill),
        t,
    ]
    .align_y(iced::Center)
    .into()
}

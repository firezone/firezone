//! Advanced settings screen — auth/API URLs and log filter.

use iced::widget::{Space, column, container, row, text, text_input};
use iced::{Element, Length};

use crate::Message;
use crate::state::App;
use crate::theme;
use crate::ui::button::{Variant, fz_button};

pub fn view(app: &App) -> Element<'_, Message> {
    let s = &app.advanced_settings;

    container(
        column![
            text(
                "WARNING: These settings are intended for internal debug \
                 purposes only. Changing these is not supported and will \
                 likely break the client."
            )
            .size(13)
            .color(theme::LIGHT.status_warn),
            Space::new().height(16),
            labeled_input(
                "Auth base URL",
                &s.auth_url,
                s.auth_url_is_managed,
                Message::AdvancedSettingsAuthUrlChanged,
            ),
            Space::new().height(8),
            labeled_input(
                "API URL",
                &s.api_url,
                s.api_url_is_managed,
                Message::AdvancedSettingsApiUrlChanged,
            ),
            Space::new().height(8),
            labeled_input(
                "Log filter",
                &s.log_filter,
                s.log_filter_is_managed,
                Message::AdvancedSettingsLogFilterChanged,
            ),
            Space::new().height(24),
            row![
                fz_button(
                    "Save",
                    Variant::Primary,
                    Message::AdvancedSettingsSave,
                    theme::LIGHT,
                ),
                fz_button(
                    "Reset to defaults",
                    Variant::Secondary,
                    Message::AdvancedSettingsReset,
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

fn labeled_input<'a, F>(
    label: &'a str,
    value: &'a str,
    managed: bool,
    on_input: F,
) -> Element<'a, Message>
where
    F: 'a + Fn(String) -> Message,
{
    let input = text_input("", value)
        .on_input_maybe(if managed { None } else { Some(on_input) })
        .padding([8, 12])
        .style(|t, st| crate::ui::input::style(t, st, theme::LIGHT));

    column![
        text(label).size(13).color(theme::LIGHT.text_secondary),
        input,
        if managed {
            text("Managed by your administrator")
                .size(11)
                .color(theme::LIGHT.text_tertiary)
                .into()
        } else {
            Element::from(Space::new().height(0))
        }
    ]
    .spacing(2)
    .into()
}

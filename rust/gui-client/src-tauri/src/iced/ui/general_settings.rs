//! General settings screen.

use iced::animation::Animation;
use iced::widget::{Space, column, container, row, text, text_input};
use iced::{Element, Length};

use crate::Message;
use crate::state::App;
use crate::theme;
use crate::ui::button::{Variant, fz_button};
use crate::ui::toggle::animated_toggle;

pub fn view(app: &App) -> Element<'_, Message> {
    let s = &app.general_settings;

    let toggles = column![
        toggle_row(
            "Start minimized",
            &s.start_minimized_anim,
            s.start_minimized,
            Message::GeneralSettingsStartMinimizedToggled,
            false,
        ),
        toggle_row(
            "Start on login",
            &s.start_on_login_anim,
            s.start_on_login,
            Message::GeneralSettingsStartOnLoginToggled,
            false,
        ),
        toggle_row(
            "Connect on start",
            &s.connect_on_start_anim,
            s.connect_on_start,
            Message::GeneralSettingsConnectOnStartToggled,
            s.connect_on_start_is_managed,
        ),
    ]
    .spacing(14);

    container(
        column![
            field_label("Account slug", s.account_slug_is_managed),
            text_input("", &s.account_slug)
                .on_input_maybe(if s.account_slug_is_managed {
                    None
                } else {
                    Some(Message::GeneralSettingsAccountSlugChanged)
                })
                .padding([8, 12])
                .style(|t, st| crate::ui::input::style(t, st, theme::LIGHT)),
            managed_hint(s.account_slug_is_managed),
            Space::new().height(18),
            toggles,
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
        .spacing(6),
    )
    .width(Length::Fill)
    .into()
}

fn field_label<'a>(label: &'a str, managed: bool) -> Element<'a, Message> {
    let color = if managed {
        theme::LIGHT.text_muted
    } else {
        theme::LIGHT.text_secondary
    };
    text(label).size(13).color(color).into()
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
    anim: &Animation<bool>,
    value: bool,
    on_toggle: F,
    managed: bool,
) -> Element<'a, Message>
where
    F: 'a + Fn(bool) -> Message,
{
    let label_color = if managed {
        theme::LIGHT.text_muted
    } else {
        theme::LIGHT.text_primary
    };
    row![
        text(label).size(14).color(label_color),
        Space::new().width(Length::Fill),
        animated_toggle(anim, value, !managed, on_toggle, theme::LIGHT),
    ]
    .align_y(iced::Center)
    .into()
}

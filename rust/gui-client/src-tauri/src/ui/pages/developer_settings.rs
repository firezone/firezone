use freya::prelude::*;

use crate::{
    settings::DeveloperSettingsViewModel,
    ui::{
        Ui,
        components::{ScrollPage, Variant, border_top, button, card, pal, setting_row, switch},
    },
};

pub(crate) fn developer_settings(settings: DeveloperSettingsViewModel) -> impl IntoElement {
    let requests = Ui::get().requests;
    let p = pal();
    let rows = [
        setting_row(
            "Reset connlib",
            false,
            false,
            button("Reset", Variant::Secondary).on_press({
                let requests = requests.clone();
                move |_| requests.reset_connlib()
            }),
            None,
        ),
        setting_row(
            "Force relayed connections",
            false,
            false,
            switch(
                "Force relayed connections",
                settings.force_relayed_connections,
                false,
                {
                    let requests = requests.clone();
                    move |enabled| requests.set_force_relayed_connections(enabled)
                },
            ),
            None,
        ),
    ];

    ScrollPage(
        rect()
            .width(Size::fill())
            .spacing(12.)
            .child(card(rows))
            .child(
                rect()
                    .width(Size::fill())
                    .horizontal()
                    .main_align(Alignment::End)
                    .padding((13., 0., 0., 0.))
                    .border(border_top(p.border))
                    .child(
                        button("Hide Developer Settings", Variant::Secondary)
                            .on_press(move |_| requests.set_developer_settings_unlocked(false)),
                    ),
            )
            .into(),
    )
}

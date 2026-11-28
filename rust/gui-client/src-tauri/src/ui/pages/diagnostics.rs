use freya::prelude::*;

use crate::{
    logging::FileCount,
    settings::LogFilterViewModel,
    ui::{
        Ui,
        components::{
            Icon, ScrollPage, TextSetting, card, confirmation_dialog, icon, icon_button,
            managed_notice, pal, section, setting_row, text,
        },
    },
};

#[derive(PartialEq)]
pub(crate) struct Diagnostics {
    pub(crate) log_count: Option<FileCount>,
    pub(crate) log_filter: Option<LogFilterViewModel>,
}

impl Component for Diagnostics {
    fn render(&self) -> impl IntoElement {
        let requests = Ui::get().requests;
        let p = pal();
        let mut confirm_clear = use_state(|| false);
        let filter_text = use_state(String::new);
        let bytes = self.log_count.as_ref().map_or(0, |c| c.bytes);
        let megabytes = (bytes as f64 / 100_000.).round() / 10.;
        let (log_filter, managed) = self
            .log_filter
            .as_ref()
            .map_or((String::new(), false), |l| {
                (l.log_filter.clone(), l.log_filter_is_managed)
            });

        let log_files = rect()
            .horizontal()
            .cross_align(Alignment::Center)
            .spacing(4.)
            .child(
                text(format!("{megabytes} MB"), 14.)
                    .font_tabular()
                    .margin((0., 8., 0., 0.)),
            )
            .child(
                icon_button(icon(Icon::ShareForward, 16., p.body), "Export Logs").on_press({
                    let requests = requests.clone();
                    move |_| requests.export_logs()
                }),
            )
            .child(
                icon_button(icon(Icon::DeleteBin, 16., p.body), "Clear Logs")
                    .offset_x(4.)
                    .on_press(move |_| confirm_clear.set(true)),
            );
        let rows = [
            TextSetting {
                label: "Log Filter",
                value: log_filter,
                text: filter_text,
                managed,
                mono: true,
                validate: None,
                save: Callback::new({
                    let requests = requests.clone();
                    move |filter| requests.apply_log_filter(filter)
                }),
            }
            .into_element(),
            setting_row("Log Files", false, false, log_files, None),
        ];

        rect()
            .expanded()
            .child(ScrollPage(
                section("Logs", card(rows), managed.then(managed_notice)).into(),
            ))
            .maybe_child(confirm_clear().then(|| {
                confirmation_dialog(
                    "Delete all log files?",
                    "Clear",
                    move || confirm_clear.set(false),
                    move || {
                        confirm_clear.set(false);
                        requests.clear_logs();
                    },
                )
            }))
    }
}

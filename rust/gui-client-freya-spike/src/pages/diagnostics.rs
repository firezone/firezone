use freya::prelude::*;

use crate::{
    Bridge, FileCount, LogFilter, Request,
    components::{Icon, ScrollPage, TextSetting, card, confirmation_dialog, icon, icon_button, managed_notice, pal, section, setting_row, text},
};

#[derive(PartialEq)]
pub struct Diagnostics {
    pub log_count: Option<FileCount>,
    pub log_filter: LogFilter,
}

impl Component for Diagnostics {
    fn render(&self) -> impl IntoElement {
        let bridge = use_consume::<Bridge>();
        let p = pal();
        let mut confirm_clear = use_state(|| false);
        let filter_text = use_state(String::new);
        let megabytes = (self.log_count.map_or(0, |c| c.bytes) as f64 / 100_000.).round() / 10.;
        let send = |request: Request| {
            let bridge = bridge.clone();
            move |_| bridge.send(request.clone())
        };

        let log_files = rect()
            .horizontal()
            .cross_align(Alignment::Center)
            .spacing(4.)
            .child(text(format!("{megabytes} MB"), 14.).font_tabular().margin((0., 8., 0., 0.)))
            .child(icon_button(icon(Icon::ShareForward, 16., p.body), "Export Logs").on_press(send(Request::ExportLogs)))
            .child(icon_button(icon(Icon::DeleteBin, 16., p.body), "Clear Logs").offset_x(4.).on_press(move |_| confirm_clear.set(true)));
        let rows = [
            TextSetting {
                label: "Log Filter",
                value: self.log_filter.log_filter.clone(),
                text: filter_text,
                managed: self.log_filter.log_filter_is_managed,
                mono: true,
                validate: None,
                on_save: EventHandler::new({
                    let bridge = bridge.clone();
                    move |filter| bridge.send(Request::ApplyLogFilter(filter))
                }),
            }
            .into_element(),
            setting_row("Log Files", false, false, log_files, None),
        ];
        let notes = self.log_filter.log_filter_is_managed.then(managed_notice);

        rect()
            .expanded()
            .child(ScrollPage(section("Logs", card(rows), notes).into()))
            .maybe_child(confirm_clear().then(|| {
                let clear = send(Request::ClearLogs);
                confirmation_dialog(
                    "Delete all log files?",
                    "Clear",
                    move |_| confirm_clear.set(false),
                    move |e| {
                        confirm_clear.set(false);
                        clear(e);
                    },
                )
            }))
    }
}

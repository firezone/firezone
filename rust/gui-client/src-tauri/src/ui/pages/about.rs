use freya::prelude::*;

use crate::ui::{
    Build, MONO, Ui,
    components::{pal, text},
};

const DEVELOPER_SETTINGS_UNLOCK_CLICKS: u32 = 7;

#[derive(PartialEq)]
pub(crate) struct About(pub(crate) Build);

impl Component for About {
    fn render(&self) -> impl IntoElement {
        about(self.0)
    }
}

fn about(build: Build) -> impl IntoElement {
    let requests = Ui::get().requests;
    let mut logo_clicks = use_state(|| 0);
    let p = pal();
    let link = |label: &'static str, url: String| {
        text(label, 14.)
            .color(p.brand)
            .a11y_role(AccessibilityRole::Link)
            .on_press(move |_| {
                if let Err(e) = open::that_detached(&url) {
                    tracing::warn!("Failed to open {url}: {e}");
                }
            })
    };

    rect().expanded().center().padding(24.).child(
        rect()
            .cross_align(Alignment::Center)
            .child(
                rect()
                    .margin((0., 0., 24., 0.))
                    .a11y_role(AccessibilityRole::Button)
                    .a11y_alt("Firezone Logo")
                    .on_press(move |_| {
                        *logo_clicks.write() += 1;
                        if logo_clicks() == DEVELOPER_SETTINGS_UNLOCK_CLICKS {
                            requests.set_developer_settings_unlocked(true);
                        }
                    })
                    .child(super::logo()),
            )
            .child(text("Version", 14.).margin((0., 0., 4., 0.)))
            .child(
                rect()
                    .horizontal()
                    .margin((0., 0., 24., 0.))
                    .font_size(18.)
                    .font_weight(FontWeight::BOLD)
                    .color(p.heading)
                    .child(text(format!("{} (", build.version), 18.))
                    .child(
                        link(
                            &build.git_sha[..8],
                            format!(
                                "https://github.com/firezone/firezone/commit/{}",
                                build.git_sha
                            ),
                        )
                        .font_size(18.)
                        .font_family(MONO)
                        .text_decoration(TextDecoration::Underline),
                    )
                    .child(text(")", 18.)),
            )
            .child(
                rect().padding((6., 8.)).child(
                    link(
                        "Documentation",
                        "https://www.firezone.dev/kb?utm_source=product".to_owned(),
                    )
                    .font_weight(FontWeight::MEDIUM),
                ),
            ),
    )
}

use freya::prelude::*;

use crate::{
    MONO,
    components::{pal, text},
};

const APP_VERSION: &str = "1.0.0";
const GIT_VERSION: &str = match option_env!("GIT_SHA") {
    Some(sha) => sha,
    None => "0000000000000000000000000000000000000000",
};

pub fn about() -> impl IntoElement {
    let p = pal();
    let link = |label: &'static str, url: String| text(label, 14.).color(p.brand).on_press(move |_| Platform::get().open_url(url.clone()));
    rect().expanded().center().padding(24.).child(
        rect()
            .cross_align(Alignment::Center)
            .child(super::logo().margin((0., 0., 24., 0.)))
            .child(text("Version", 14.).margin((0., 0., 4., 0.)))
            .child(
                rect()
                    .horizontal()
                    .margin((0., 0., 24., 0.))
                    .font_size(18.)
                    .font_weight(FontWeight::BOLD)
                    .color(p.heading)
                    .child(text(format!("{APP_VERSION} ("), 18.))
                    .child(
                        link(&GIT_VERSION[..8], format!("https://github.com/firezone/firezone/commit/{GIT_VERSION}"))
                            .font_size(18.)
                            .font_family(MONO)
                            .text_decoration(TextDecoration::Underline),
                    )
                    .child(text(")", 18.)),
            )
            .child(
                rect()
                    .padding((6., 8.))
                    .child(link("Documentation", "https://www.firezone.dev/kb?utm_source=product".into()).font_weight(FontWeight::MEDIUM)),
            ),
    )
}

use freya::prelude::*;

use crate::{
    MONO,
    components::{ScrollPage, border, border_bottom, pal, text},
};

const PRIMARY: [u32; 11] = [
    0xfff9f5, 0xfff1e5, 0xffddc2, 0xffbc85, 0xff9a47, 0xff7300, 0xff7605, 0xc25700, 0x7f3900,
    0x5c2900, 0x331700,
];
const ACCENT: [u32; 11] = [
    0xf8f5ff, 0xece5ff, 0xd2c2ff, 0xa585ff, 0x7847ff, 0x5e00d6, 0x4805ff, 0x3400c2, 0x37007f,
    0x28005c, 0x160033,
];
const NEUTRAL: [u32; 10] = [
    0xf6f6f6, 0xe7e7e7, 0xd1d1d1, 0xb0b0b0, 0x888888, 0x6d6d6d, 0x575757, 0x4f4f4f, 0x454545,
    0x3d3d3d,
];
const STEPS: [&str; 11] = [
    "50", "100", "200", "300", "400", "450", "500", "600", "700", "800", "900",
];

pub fn color_palette() -> impl IntoElement {
    ScrollPage(
        rect()
            .width(Size::fill())
            .spacing(32.)
            .child(section("Primary Colors", "primary", &PRIMARY, &STEPS))
            .child(section("Accent Colors", "accent", &ACCENT, &STEPS))
            .child(section(
                "Neutral Colors",
                "neutral",
                &NEUTRAL,
                &[&STEPS[..5], &STEPS[6..]].concat(),
            ))
            .into(),
    )
}

fn section(title: &'static str, name: &str, colors: &[u32], steps: &[&str]) -> Rect {
    let p = pal();
    let swatches: Vec<Element> = colors
        .iter()
        .zip(steps)
        .map(|(rgb, step)| {
            rect()
                .width(Size::flex(1.))
                .corner_radius(4.)
                .overflow(Overflow::Clip)
                .background(p.surface)
                .border(border(p.border))
                .child(
                    rect()
                        .width(Size::fill())
                        .height(Size::px(56.))
                        .background(Color::new(0xff000000 | rgb))
                        .border(border_bottom(p.border)),
                )
                .child(
                    rect()
                        .padding(12.)
                        .child(text(format!("bg-{name}-{step}"), 12.).font_family(MONO)),
                )
                .into()
        })
        .collect();
    rect()
        .width(Size::fill())
        .spacing(16.)
        .child(
            rect()
                .width(Size::fill())
                .padding((0., 0., 8., 0.))
                .border(border_bottom(p.border))
                .child(
                    text(title, 20.)
                        .font_weight(FontWeight::SEMI_BOLD)
                        .color(p.heading),
                ),
        )
        .children(swatches.chunks(4).map(|row| {
            let padding = (row.len()..4).map(|_| rect().width(Size::flex(1.)).into_element());
            rect()
                .width(Size::fill())
                .horizontal()
                .content(Content::Flex)
                .spacing(16.)
                .children(row.iter().cloned().chain(padding))
                .into_element()
        }))
}

use freya::prelude::*;

use crate::{
    CertField, MONO,
    components::{Icon, ScrollPage, card, icon, pal, text},
};

pub fn device_trust(fields: &[CertField]) -> impl IntoElement {
    let p = pal();
    let field = |label: &str| {
        fields
            .iter()
            .find(|f| f.label == label)
            .and_then(|f| f.value.clone())
    };
    let heading = field("Common Name")
        .or_else(|| field("Subject"))
        .unwrap_or_else(|| "Client certificate".into());
    let line = |s: String| text(s, 14.).margin((2., 0., 0., 0.));
    let summary = rect()
        .width(Size::fill())
        .horizontal()
        .spacing(12.)
        .padding(16.)
        .child(icon(Icon::Certificate, 32., p.subtle))
        .child(
            rect()
                .width(Size::flex(1.))
                .child(
                    text(heading, 16.)
                        .font_weight(FontWeight::SEMI_BOLD)
                        .color(p.heading)
                        .letter_spacing(-0.4),
                )
                .maybe_child(field("Issuer").map(|issuer| line(format!("Issued by {issuer}"))))
                .maybe_child(
                    field("Not After").map(|not_after| line(format!("Valid until {not_after}"))),
                ),
        );

    let last = fields.len().saturating_sub(1);
    let rows = fields.iter().enumerate().map(|(i, f)| {
        let value = match &f.value {
            Some(value) => text(value.clone(), 12.).font_family(MONO),
            None => text("Not present", 12.).color(p.subtle),
        };
        rect()
            .width(Size::fill())
            .horizontal()
            .content(Content::Flex)
            .spacing(4.)
            .padding((
                if i == 0 { 0. } else { 10. },
                0.,
                if i == last { 0. } else { 10. },
                0.,
            ))
            .child(
                text(f.label.clone(), 12.)
                    .color(p.subtle)
                    .width(Size::px(192.)),
            )
            .child(
                rect()
                    .width(Size::flex(1.))
                    .child(value.width(Size::fill()))
                    .maybe_child(f.problem.clone().map(|problem| {
                        rect()
                            .horizontal()
                            .spacing(6.)
                            .margin((4., 0., 0., 0.))
                            .child(icon(Icon::Alert, 14., p.warning).margin((2., 0., 0., 0.)))
                            .child(text(problem, 12.).color(p.warning))
                    })),
            )
            .into()
    });

    // `.panel p-4` around a `dl.divide-y`: the dividers stop at the padding.
    let details = card([rect()
        .width(Size::fill())
        .padding(16.)
        .child(card_rows(rows))
        .into()]);
    ScrollPage(
        rect()
            .width(Size::fill())
            .spacing(16.)
            .child(card([summary.into()]))
            .child(details)
            .into(),
    )
}

fn card_rows(rows: impl Iterator<Item = Element>) -> Rect {
    let p = pal();
    rect()
        .width(Size::fill())
        .children(rows.enumerate().flat_map(|(i, row)| {
            let divider = (i > 0).then(|| {
                rect()
                    .width(Size::fill())
                    .height(Size::px(1.))
                    .background(p.border)
                    .into()
            });
            divider.into_iter().chain([row])
        }))
}

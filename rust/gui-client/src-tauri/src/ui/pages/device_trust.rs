use freya::prelude::*;

use crate::{
    ui::{
        MONO,
        components::{Icon, ScrollPage, card, divided, icon, pal, text},
    },
    view::{X509Certificate, X509DetailField, X509ValidationError},
};

pub(crate) fn device_trust(certificate: Option<&X509Certificate>) -> impl IntoElement {
    let p = pal();
    let fields = certificate.map_or(&[][..], |c| &c.fields);
    let field = |label: &str| {
        fields
            .iter()
            .find(|f| f.label == label)
            .and_then(|f| f.value.clone())
    };
    let heading = field("Common Name")
        .or_else(|| field("Subject"))
        .unwrap_or_else(|| "Client certificate".to_owned());
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
    let rows = fields
        .iter()
        .enumerate()
        .map(|(i, field)| detail_row(field, i == 0, i == last));

    // The dividers between the details stop at the card's padding.
    let details = card([rect()
        .width(Size::fill())
        .padding(16.)
        .child(rect().width(Size::fill()).children(divided(rows)))
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

fn detail_row(field: &X509DetailField, first: bool, last: bool) -> Element {
    let p = pal();
    let value = match &field.value {
        Some(value) => text(value.clone(), 12.).font_family(MONO),
        None => text("Not present", 12.).color(p.subtle),
    };

    rect()
        .width(Size::fill())
        .horizontal()
        .content(Content::Flex)
        .spacing(4.)
        .padding((
            if first { 0. } else { 10. },
            0.,
            if last { 0. } else { 10. },
            0.,
        ))
        .child(
            text(field.label.clone(), 12.)
                .color(p.subtle)
                .width(Size::px(192.)),
        )
        .child(
            rect()
                .width(Size::flex(1.))
                .child(value.width(Size::fill()))
                .maybe_child(field.problem.map(|problem| {
                    rect()
                        .horizontal()
                        .spacing(6.)
                        .margin((4., 0., 0., 0.))
                        .child(icon(Icon::Alert, 14., p.warning).margin((2., 0., 0., 0.)))
                        .child(text(problem_text(problem), 12.).color(p.warning))
                })),
        )
        .into()
}

fn problem_text(problem: X509ValidationError) -> &'static str {
    match problem {
        X509ValidationError::Empty => "Empty",
        X509ValidationError::TooLong => "Too long",
        X509ValidationError::Ambiguous => "Ambiguous",
        X509ValidationError::PlaceholderIdentifier => "Placeholder identifier",
        X509ValidationError::UnknownAttribute => "Unrecognized attribute",
        X509ValidationError::NotYetValid => "Not yet valid",
        X509ValidationError::Expired => "Expired",
        X509ValidationError::MissingClientAuthEku => "Missing client authentication EKU",
        X509ValidationError::DigitalSignatureNotAllowed => "Digital signature not allowed",
    }
}

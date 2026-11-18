use freya::{animation::*, prelude::*};

use crate::{
    ui::{
        Ui,
        components::{Variant, button, pal, text},
    },
    view::SessionViewModel,
};

#[derive(PartialEq)]
pub(crate) struct Overview(pub(crate) Option<SessionViewModel>);

impl Component for Overview {
    fn render(&self) -> impl IntoElement {
        let requests = Ui::get().requests;
        let p = pal();
        let small = |s: &'static str| {
            text(s, 12.)
                .width(Size::fill())
                .color(p.subtle)
                .text_align(TextAlign::Center)
        };
        let strong = |s: &str| {
            Span::new(s.to_owned())
                .font_weight(FontWeight::BOLD)
                .color(p.heading)
        };

        let session: Element = match &self.0 {
            None | Some(SessionViewModel::SignedOut) => column()
                .child(
                    text("You can sign in by clicking the Firezone icon in the taskbar or by clicking the button below.", 14.)
                        .width(Size::fill())
                        .text_align(TextAlign::Center),
                )
                .child(button("Sign in", Variant::Primary).on_press(move |_| requests.sign_in()))
                .child(small("Firezone will continue running after this window is closed.\nIt is always available from the taskbar."))
                .into(),
            Some(SessionViewModel::Loading) => column()
                .child(Spinner)
                .child(small("Firezone will continue running in the taskbar after this window is closed."))
                .into(),
            Some(SessionViewModel::SignedIn { account_slug, actor_name }) => column()
                .child(
                    paragraph()
                        .width(Size::fill())
                        .text_align(TextAlign::Center)
                        .line_height(20. / 14.)
                        .span("You are currently signed into \u{a0}")
                        .span(strong(account_slug))
                        .span("\u{a0}as\u{a0}")
                        .span(strong(actor_name))
                        .span(".\nClick the Firezone icon in the taskbar to see the list of Resources."),
                )
                .child(button("Sign out", Variant::Primary).on_press(move |_| requests.sign_out()))
                .child(small("Firezone will continue running in the taskbar after this window is closed."))
                .into(),
        };

        rect().expanded().center().padding(24.).child(
            column()
                .max_width(Size::px(512.))
                .child(super::logo())
                .child(
                    text("Firezone", 20.)
                        .font_weight(FontWeight::SEMI_BOLD)
                        .color(p.heading)
                        .letter_spacing(-0.5),
                )
                .child(session),
        )
    }
}

fn column() -> Rect {
    rect()
        .width(Size::fill())
        .cross_align(Alignment::Center)
        .spacing(16.)
}

/// A spinning loading ring.
#[derive(PartialEq)]
struct Spinner;

impl Component for Spinner {
    fn render(&self) -> impl IntoElement {
        let p = pal();
        let animation = use_animation(|conf| {
            conf.on_creation(OnCreation::Run);
            conf.on_finish(OnFinish::restart());
            AnimNum::new(0., 360.).time(1000)
        });
        let hex = |c: Color| format!("#{:02x}{:02x}{:02x}", c.r(), c.g(), c.b());
        let svg = format!(
            r#"<svg viewBox="0 0 20 20" xmlns="http://www.w3.org/2000/svg" fill="none" stroke-width="2">
<circle cx="10" cy="10" r="9" stroke="{}" stroke-opacity="{}"/>
<path d="M3.64 3.64A9 9 0 0 1 16.36 3.64" stroke="{}"/></svg>"#,
            hex(p.brand_muted),
            p.brand_muted.a() as f32 / 255.,
            hex(p.brand)
        );

        SvgViewer::new(Bytes::from(svg))
            .width(Size::px(20.))
            .height(Size::px(20.))
            .show_loader(false)
            .a11y_role(AccessibilityRole::ProgressIndicator)
            .rotation(animation.get().value())
    }
}

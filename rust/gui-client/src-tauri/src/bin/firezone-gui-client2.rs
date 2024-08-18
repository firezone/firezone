use floem::{
    peniko::Color,
    unit::{PxPct, PxPctAuto},
    views::{button, container, img, static_label, v_stack, Decorators},
    View,
};

fn welcome() -> impl View {
    body(
        v_stack((
            container(static_label("Welcome to Firezone."))
                .style(|s| s.font_size(32.0).flex().justify_center()),
            container(static_label("Sign in below to get started."))
                .style(|s| s.flex().font_size(16.0).justify_center()),
            container(img(|| include_bytes!("./logo.png").to_vec()).style(|s| {
                s.border_radius(PxPct::Pct(50.0))
                    .width(192.0)
                    .height(192.0)
                    .background(Color::WHITE)
                    // .box_shadow()
                    .border(2.0)
                    .border_color(Color::BLACK)
            }))
            .style(|s| s.flex().justify_center()),
            container(
                button(|| "Sign in")
                    .on_click_stop(move |_| {
                        // Handle sign in action
                    })
                    .style(|s| {
                        s.background(Color::rgb8(94, 0, 214))
                            .font_size(20.0)
                            .border_radius(2.75)
                            .padding_horiz(20.0)
                            .padding_vert(10.0)
                            // .text_align_center()
                            .color(Color::WHITE)
                    }),
            )
            .style(|s| s.flex().justify_center()),
        ))
        .style(|s| s.gap(30).margin(PxPctAuto::Auto)),
    )
}

fn body(children: impl View + 'static) -> impl View {
    container(children).style(|s| {
        s.background(Color::rgb8(0xf5, 0xf5, 0xf5))
            .color(Color::rgb8(0x11, 0x18, 0x27))
            .width_full()
            .font_family("ui-sans-serif, system-ui, sans-serif".to_owned())
    })
}

fn main() {
    floem::launch(welcome);
}

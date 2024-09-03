use anyhow::Result;
use floem::{
    peniko::Color,
    unit::{PxPct, PxPctAuto},
    views::{button, container, img, static_label, v_stack, Decorators},
    View,
};
use tao::{
    event_loop::{ControlFlow, EventLoopBuilder},
};
#[cfg(target_os = "linux")]
use tao::platform::unix::EventLoopBuilderExtUnix as _;
#[cfg(target_os = "windows")]
use tao::platform::windows::EventLoopBuilderExtWindows as _;
use tray_icon::{Icon, TrayIconBuilder};

fn welcome() -> impl View {
    body(
        v_stack((
            container(static_label("Welcome to Firezone."))
                .style(|s| s.font_size(32.0).flex().justify_center()),
            container(static_label("Sign in below to get started."))
                .style(|s| s.flex().font_size(16.0).justify_center()),
            container(
                img(|| include_bytes!("../../src/logo.png").to_vec()).style(|s| {
                    s.border_radius(PxPct::Pct(50.0))
                        .width(192.0)
                        .height(192.0)
                        .background(Color::WHITE)
                        // .box_shadow()
                        .border(2.0)
                        .border_color(Color::BLACK)
                }),
            )
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

fn main() -> Result<()> {
    std::thread::spawn(gtk_thread);

    floem::launch(welcome);
    Ok(())
}

fn gtk_thread() -> Result<()> {
    let mut icon = vec![];
    for _ in 0..32 * 32 {
        icon.push(255);
        icon.push(0);
        icon.push(255);
        icon.push(255);
    }
    let icon = tray_icon::Icon::from_rgba(icon, 32, 32)?;
    let menu = tray_icon::menu::Menu::new();
    menu.append(&tray_icon::menu::MenuItem::with_id(
        "floem",
        "Firezone Floem",
        true,
        None,
    ))?;

    tray_icon::menu::MenuEvent::set_event_handler(Some(|event| {
        println!("Menu event {event:?}");
    }));
    tray_icon::TrayIconEvent::set_event_handler(Some(|event| {
        println!("Icon event {event:?}");
    }));

    let event_loop = EventLoopBuilder::new().with_any_thread(true).build();

    let tray_icon = TrayIconBuilder::new()
        .with_tooltip("system-tray - tray icon library!")
        .with_icon(icon)
        .with_menu(Box::new(menu))
        .build()?;

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
    });
    Ok(())
}

use anyhow::Result;
use gtk::prelude::*;
use gtk::{Application, ApplicationWindow};
use std::time::Duration;
use tokio::sync::mpsc;
use tray_icon::{TrayIconBuilder, menu::{Menu, MenuEvent, MenuItem}};

fn main() -> Result<()> {
    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    let app = Application::builder()
        .application_id("dev.firezone.client")
        .build();

    app.connect_activate(|app| {
        // We create the main window.
        let win = ApplicationWindow::builder()
            .application(app)
            .default_width(640)
            .default_height(480)
            .title("Firezone GTK+ 3")
            .build();

        // Don't forget to make all widgets visible.
        win.show_all();
    });

    let mut icon_rgba = vec![];
    for _ in 0..96 * 96 {
        icon_rgba.push(255);
        icon_rgba.push(0);
        icon_rgba.push(255);
        icon_rgba.push(255);
    }
    let icon = tray_icon::Icon::from_rgba(icon_rgba, 96, 96)?;

    gtk::init()?;
    MenuEvent::set_event_handler(Some(|event: MenuEvent| println!("Got tray event `{}`", event.id.0)));
    let tray_menu = Menu::new();
    tray_menu.append(&MenuItem::with_id("do-not-panic", "Don't you panic", true, None))?;
    let tray_icon = TrayIconBuilder::new()
        .with_menu(Box::new(tray_menu))
        .with_tooltip("system-tray - tray icon library!")
        .with_icon(icon)
        .build()?;

    let (main_tx, mut main_rx) = mpsc::channel(1);

    glib::spawn_future_local(async move {
        loop {
            let count = main_rx.recv().await.unwrap();
            let tray_menu = Menu::new();
            tray_menu.append(&MenuItem::with_id("do-not-panic", "Don't you panic", true, None)).unwrap();
            tray_menu.append(&MenuItem::with_id("timer", format!("Time is {count}"), true, None)).unwrap();
            tray_icon.set_menu(Some(Box::new(tray_menu)));
        }
    });

    rt.spawn(run_controller(main_tx));

    if app.run() != 0.into() {
        anyhow::bail!("GTK main loop returned non-zero exit code");
    }
    Ok(())
}

async fn run_controller(main_tx: mpsc::Sender<usize>) -> Result<()> {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    let mut count = 0;
    loop {
        interval.tick().await;
        main_tx.send(count).await?;
        count += 1;
    }
}

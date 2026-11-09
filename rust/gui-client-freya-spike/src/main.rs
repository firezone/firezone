use std::time::Duration;

use freya::{prelude::*, winit::window::WindowId};
use gui_client_freya_spike::*;
use tokio::sync::mpsc;

/// What the Controller asks of the GUI, beyond view-model updates.
#[derive(Debug)]
enum UiCommand {
    Update(Box<ViewModel>),
    Show,
    Hide,
    Close,
    Quit,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--headless") {
        // Exits before anything touches a display, GL or the tray.
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async { tokio::time::sleep(Duration::from_millis(10)).await });
        println!("headless: ok");
        return;
    }
    let scripted = args.iter().any(|a| a == "--script");

    let rt = tokio::runtime::Runtime::new().unwrap();
    let _guard = rt.enter();
    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
    let (req_tx, req_rx) = mpsc::unbounded_channel();
    rt.spawn(controller(cmd_tx, req_rx, scripted));

    let bridge = Bridge {
        vm: State::create_global(ViewModel::default()),
        requests: req_tx,
        dark: std::env::var("DARK").is_ok(),
        start_page: Page::Overview,
    };

    // Build the event loop ourselves so "no display" is an error we handle, not a panic.
    let event_loop =
        match freya::winit::event_loop::EventLoop::<NativeEvent>::with_user_event().build() {
            Ok(event_loop) => event_loop,
            Err(e) => {
                eprintln!("cannot start GUI: {e}");
                std::process::exit(2);
            }
        };
    let config = FONTS
        .iter()
        .fold(LaunchConfig::new(), |config, (family, bytes)| {
            config.with_font(*family, Bytes::from_static(bytes))
        });
    let config = config
        .with_event_loop(event_loop)
        .with_exit_on_close(false)
        .with_default_font(SANS)
        .with_task({
            let bridge = bridge.clone();
            move |proxy| gui_loop(cmd_rx, proxy, bridge)
        });
    #[cfg(feature = "tray")]
    let config = tray::with_tray(config, bridge);
    launch(config);
    println!("event loop exited");
}

/// Glue on the GUI thread: apply Controller commands to state and windows.
async fn gui_loop(
    mut cmds: mpsc::UnboundedReceiver<UiCommand>,
    proxy: LaunchProxy,
    bridge: Bridge,
) {
    let mut vm = bridge.vm;
    while let Some(cmd) = cmds.recv().await {
        let bridge = bridge.clone();
        let windows = proxy
            .post_callback(move |r| {
                let ids: Vec<WindowId> = r.windows().keys().copied().collect();
                match cmd {
                    UiCommand::Update(new) => vm.set(*new),
                    UiCommand::Show => show_window(r, &bridge),
                    UiCommand::Hide => ids
                        .iter()
                        .for_each(|id| Platform::get().with_window(*id, |w| w.set_visible(false))),
                    UiCommand::Close => ids.iter().for_each(|id| Platform::get().close_window(*id)),
                    UiCommand::Quit => r.exit(),
                }
                ids.len()
            })
            .await;
        println!("gui: windows before command = {:?}", windows.ok());
    }
}

fn show_window(r: &mut RendererContext, bridge: &Bridge) {
    match r.windows().keys().next().copied() {
        Some(id) => Platform::get().with_window(id, |w| {
            w.set_visible(true);
            w.focus_window();
        }),
        None => {
            r.launch_window(
                WindowConfig::new(app)
                    .with_root_context(bridge.clone())
                    .with_size(900., 500.)
                    .with_title("Firezone"),
            );
        }
    }
}

async fn controller(
    ui: mpsc::UnboundedSender<UiCommand>,
    mut requests: mpsc::UnboundedReceiver<Request>,
    scripted: bool,
) {
    if scripted {
        let step = |c: UiCommand| {
            println!("controller: {c:?}");
            ui.send(c).unwrap();
        };
        let pause = || tokio::time::sleep(Duration::from_millis(1500));
        pause().await;
        step(UiCommand::Show);
        pause().await;
        step(UiCommand::Update(Box::new(ViewModel {
            session: Some(Session::SignedIn {
                account_slug: "example-corp".into(),
                actor_name: "Jane Doe".into(),
            }),
            ..Default::default()
        })));
        pause().await;
        step(UiCommand::Hide);
        pause().await;
        step(UiCommand::Show);
        pause().await;
        step(UiCommand::Close);
        pause().await;
        step(UiCommand::Show);
        pause().await;
        step(UiCommand::Close);
        pause().await;
        step(UiCommand::Show); // Proves the loop survived the last window closing.
        pause().await;
        step(UiCommand::Quit);
        return;
    }
    ui.send(UiCommand::Show).unwrap();
    let mut model = ViewModel {
        session: Some(Session::SignedOut),
        log_count: Some(FileCount { bytes: 0, files: 0 }),
        ..Default::default()
    };
    ui.send(UiCommand::Update(Box::new(model.clone()))).unwrap();
    while let Some(req) = requests.recv().await {
        println!("controller: {req:?}");
        match req {
            Request::SignIn => {
                model.session = Some(Session::SignedIn {
                    account_slug: "example-corp".into(),
                    actor_name: "Jane Doe".into(),
                });
            }
            Request::SignOut => model.session = Some(Session::SignedOut),
            Request::ApplySettings(_) | Request::ResetSettings | Request::ApplyLogFilter(_) => {
                let _ =
                    desktop_notifications::show("dev.firezone.spike", "Settings applied", "", None)
                        .await;
            }
            Request::ClearLogs => model.log_count = Some(FileCount { bytes: 0, files: 0 }),
            Request::ExportLogs => {
                let picked = rfd::AsyncFileDialog::new()
                    .set_file_name("logs.zip")
                    .save_file()
                    .await;
                if let Some(path) = picked {
                    let _ = open::that(path.path());
                }
            }
        }
        ui.send(UiCommand::Update(Box::new(model.clone()))).unwrap();
    }
}

#[cfg(feature = "tray")]
mod tray {
    use freya::{
        prelude::*,
        tray::{
            Icon, TrayIconBuilder,
            menu::{Menu, MenuItem},
        },
    };
    use gui_client_freya_spike::Bridge;

    pub fn with_tray(config: LaunchConfig, bridge: Bridge) -> LaunchConfig {
        config.with_tray(
            || {
                let menu = Menu::new();
                menu.append(&MenuItem::with_id("open", "Open Firezone", true, None))
                    .unwrap();
                menu.append(&MenuItem::with_id("quit", "Quit", true, None))
                    .unwrap();
                let rgba = [255u8, 120, 34, 255].repeat(32 * 32);
                TrayIconBuilder::new()
                    .with_menu(Box::new(menu))
                    .with_icon(Icon::from_rgba(rgba, 32, 32).unwrap())
                    .with_tooltip("Firezone")
                    .build()
                    .expect("tray icon")
            },
            move |event, mut r| {
                if let freya::tray::TrayEvent::Menu(menu) = event {
                    match menu.id.0.as_str() {
                        "open" => super::show_window(&mut r, &bridge),
                        "quit" => r.exit(),
                        _ => {}
                    }
                }
            },
        )
    }
}

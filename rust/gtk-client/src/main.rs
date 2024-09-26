use anyhow::Result;
use firezone_gui_client_common::{
    self as common, auth,
    controller::{Controller, ControllerRequest, CtlrTx, GuiIntegration},
    ipc,
    system_tray::Entry,
    updates,
};
use firezone_headless_client::LogFilterReloader;
use gtk::prelude::*;
use gtk::{Application, ApplicationWindow};
use tokio::sync::mpsc;
use tray_icon::{menu::MenuEvent, TrayIconBuilder};

fn main() -> Result<()> {
    let common::logging::Handles {
        logger: _logger,
        reloader: log_filter_reloader,
    } = start_logging("debug")?; // TODO
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
    let tray_icon = TrayIconBuilder::new()
        .with_tooltip("system-tray - tray icon library!")
        .with_icon(icon)
        .build()?;

    let (main_tx, main_rx) = mpsc::channel(100);

    let l = MainThreadLoop {
        app: app.clone(),
        main_rx,
        tray_icon,
    };
    glib::spawn_future_local(l.run());

    let (ctlr_tx, ctlr_rx) = mpsc::channel(100);

    {
        let ctlr_tx = ctlr_tx.clone();
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
            let Ok(event) = serde_json::from_str::<common::system_tray::Event>(&event.id.0) else {
                tracing::error!("Couldn't parse system tray event");
                return;
            };
            if let Err(error) = ctlr_tx.blocking_send(ControllerRequest::SystemTrayMenu(event)) {
                tracing::error!(?error, "Couldn't send system tray event to Controller");
            }
        }));
    }

    let (_updates_tx, updates_rx) = mpsc::channel(1);

    rt.spawn(run_controller(
        main_tx,
        ctlr_tx,
        ctlr_rx,
        log_filter_reloader,
        updates_rx,
    ));

    if app.run() != 0.into() {
        anyhow::bail!("GTK main loop returned non-zero exit code");
    }
    Ok(())
}

struct MainThreadLoop {
    app: gtk::Application,
    main_rx: mpsc::Receiver<MainThreadReq>,
    tray_icon: tray_icon::TrayIcon,
}

impl MainThreadLoop {
    async fn run(mut self) -> Result<()> {
        while let Some(req) = self.main_rx.recv().await {
            match req {
                MainThreadReq::Quit => self.app.quit(),
                MainThreadReq::SetTrayMenu(app_state) => self.set_tray_menu(app_state)?,
            }
        }
        Ok(())
    }

    fn set_tray_menu(&mut self, app_state: common::system_tray::AppState) -> Result<()> {
        let menu = build_menu("", &app_state.into_menu())?;
        self.tray_icon.set_menu(Some(Box::new(menu)));
        Ok(())
    }
}

fn build_menu(text: &str, that: &common::system_tray::Menu) -> Result<tray_icon::menu::Submenu> {
    let menu = tray_icon::menu::Submenu::new(text, true);
    for entry in &that.entries {
        match entry {
            Entry::Item(item) if item.checked.is_some() => {
                menu.append(&build_checked_item(item))?
            }
            Entry::Item(item) => menu.append(&build_item(item))?,
            Entry::Separator => menu.append(&tray_icon::menu::PredefinedMenuItem::separator())?,
            Entry::Submenu { title, inner } => menu.append(&build_menu(title, inner)?)?,
        };
    }
    Ok(menu)
}

fn build_checked_item(that: &common::system_tray::Item) -> tray_icon::menu::CheckMenuItem {
    let id = serde_json::to_string(&that.event)
        .expect("`serde_json` should always be able to serialize tray menu events");

    tray_icon::menu::CheckMenuItem::with_id(
        id,
        &that.title,
        that.event.is_some(),
        that.checked.unwrap_or_default(),
        None,
    )
}

fn build_item(that: &common::system_tray::Item) -> tray_icon::menu::MenuItem {
    let id = serde_json::to_string(&that.event)
        .expect("`serde_json` should always be able to serialize tray menu events");

    tray_icon::menu::MenuItem::with_id(id, &that.title, that.event.is_some(), None)
}

/// Something that needs to be done on the GTK+ main thread.
enum MainThreadReq {
    Quit,
    SetTrayMenu(common::system_tray::AppState),
}

async fn run_controller(
    main_tx: mpsc::Sender<MainThreadReq>, // Runs stuff on the main thread
    ctlr_tx: CtlrTx,
    rx: mpsc::Receiver<ControllerRequest>,
    log_filter_reloader: LogFilterReloader,
    updates_rx: mpsc::Receiver<Option<updates::Notification>>,
) -> Result<()> {
    let integration = GtkIntegration {
        main_tx: main_tx.clone(),
    };

    let (ipc_tx, ipc_rx) = mpsc::channel(1);
    let ipc_client = ipc::Client::new(ipc_tx).await?;
    let controller = Controller {
        advanced_settings: Default::default(), // TODO
        auth: auth::Auth::new()?,
        clear_logs_callback: None,
        ctlr_tx,
        ipc_client,
        ipc_rx,
        integration,
        log_filter_reloader,
        release: None,
        rx,
        status: Default::default(),
        updates_rx,
        uptime: Default::default(),
    };

    controller.main_loop().await?;
    main_tx.send(MainThreadReq::Quit).await?;
    Ok(())
}

struct GtkIntegration {
    main_tx: mpsc::Sender<MainThreadReq>,
}

impl GuiIntegration for GtkIntegration {
    fn set_welcome_window_visible(&self, _visible: bool) -> Result<()> {
        tracing::warn!("set_welcome_window_visible not implemented");
        Ok(())
    }

    fn open_url<P: AsRef<str>>(&self, _url: P) -> Result<()> {
        tracing::warn!("open_url not implemented");
        Ok(())
    }

    fn set_tray_icon(&mut self, _icon: common::system_tray::Icon) -> Result<()> {
        tracing::warn!("set_tray_icon not implemented");
        Ok(())
    }

    fn set_tray_menu(&mut self, app_state: common::system_tray::AppState) -> Result<()> {
        self.main_tx
            .try_send(MainThreadReq::SetTrayMenu(app_state))?;
        Ok(())
    }

    fn show_notification(&self, _title: &str, _body: &str) -> Result<()> {
        tracing::warn!("show_notification not implemented");
        Ok(())
    }

    fn show_update_notification(
        &self,
        _ctlr_tx: CtlrTx,
        _title: &str,
        _url: url::Url,
    ) -> Result<()> {
        tracing::warn!("show_update_notification not implemented");
        Ok(())
    }

    fn show_window(&self, _window: common::system_tray::Window) -> Result<()> {
        tracing::warn!("show_window not implemented");
        Ok(())
    }
}

/// Starts logging
///
/// Don't drop the log handle or logging will stop.
fn start_logging(directives: &str) -> Result<common::logging::Handles> {
    let logging_handles = common::logging::setup(directives)?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        os = std::env::consts::OS,
        ?directives,
        git_version = firezone_bin_shared::git_version!("gui-client-*"),
        system_uptime_seconds = firezone_headless_client::uptime::get().map(|dur| dur.as_secs()),
        "`gui-client` started logging"
    );

    Ok(logging_handles)
}

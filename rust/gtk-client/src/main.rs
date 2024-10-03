use anyhow::{Context as _, Result};
use clap::{Args, Parser};
use firezone_gui_client_common::{
    self as common,
    compositor::{self, Image},
    controller::{Builder as ControllerBuilder, ControllerRequest, CtlrTx, GuiIntegration},
    deep_link,
    system_tray::{AppState, ConnlibState, Entry, Icon, IconBase},
    updates,
};
use firezone_headless_client::LogFilterReloader;
use firezone_telemetry as telemetry;
use gtk::prelude::*;
use gtk::{Application, ApplicationWindow};
use secrecy::{ExposeSecret as _, SecretString};
use std::str::FromStr;
use tokio::sync::mpsc;
use tray_icon::{menu::MenuEvent, TrayIconBuilder};

// TODO: De-dupe icon compositing with the Tauri Client.

// Figma is the source of truth for the tray icon layers
// <https://www.figma.com/design/THvQQ1QxKlsk47H9DZ2bhN/Core-Library?node-id=1250-772&t=nHBOzOnSY5Ol4asV-0>
const LOGO_BASE: &[u8] = include_bytes!("../../gui-client/src-tauri/icons/tray/Logo.png");
const LOGO_GREY_BASE: &[u8] = include_bytes!("../../gui-client/src-tauri/icons/tray/Logo grey.png");
const BUSY_LAYER: &[u8] = include_bytes!("../../gui-client/src-tauri/icons/tray/Busy layer.png");
const SIGNED_OUT_LAYER: &[u8] =
    include_bytes!("../../gui-client/src-tauri/icons/tray/Signed out layer.png");
const UPDATE_READY_LAYER: &[u8] =
    include_bytes!("../../gui-client/src-tauri/icons/tray/Update ready layer.png");

const TOOLTIP: &str = "Firezone";

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Cmd>,
}

#[derive(clap::Subcommand)]
enum Cmd {
    Debug,
    OpenDeepLink(DeepLink),
}

#[derive(Args)]
struct DeepLink {
    url: url::Url, // TODO: Should be `Secret`?
}

fn main() -> Result<()> {
    let current_exe = std::env::current_exe()?;
    let cli = Cli::parse();

    match cli.command {
        Some(Cmd::Debug) => return Ok(()), // I didn't want to use `if-let` here
        Some(Cmd::OpenDeepLink(deep_link)) => {
            let rt = tokio::runtime::Runtime::new()?;
            if let Err(error) = rt.block_on(deep_link::open(&deep_link.url)) {
                tracing::error!(?error, "Error in `OpenDeepLink`");
            }
            return Ok(());
        }
        None => {}
    }

    // We're not a deep link handler, so start telemetry
    let telemetry = telemetry::Telemetry::default();
    // TODO: Fix missing stuff for telemetry
    telemetry.start(
        "wss://api.firez.one",
        firezone_bin_shared::git_version!("gtk-client-*"),
        telemetry::GUI_DSN,
    );

    let common::logging::Handles {
        logger: _logger,
        reloader: log_filter_reloader,
    } = start_logging("debug")?; // TODO
    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    let deep_link_server = rt.block_on(deep_link::Server::new())?;

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

    gtk::init()?;
    let tray_icon = TrayIconBuilder::new()
        .with_tooltip(TOOLTIP)
        .with_icon(icon_to_native_icon(&Icon::default()))
        .build()?;

    let (main_tx, main_rx) = mpsc::channel(100);

    let l = MainThreadLoop {
        app: app.clone(),
        last_icon_set: Default::default(),
        main_rx,
        tray_icon,
    };
    glib::spawn_future_local(l.run());

    let (ctlr_tx, ctlr_rx) = mpsc::channel(100);

    deep_link::register(current_exe)?;
    rt.spawn(accept_deep_links(deep_link_server, ctlr_tx.clone()));

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
        telemetry,
        updates_rx,
    ));

    if app.run() != 0.into() {
        anyhow::bail!("GTK main loop returned non-zero exit code");
    }
    Ok(())
}

// Worker task to accept deep links from a named pipe forever
///
/// * `server` An initial named pipe server to consume before making new servers. This lets us also use the named pipe to enforce single-instance
async fn accept_deep_links(mut server: deep_link::Server, ctlr_tx: CtlrTx) -> Result<()> {
    loop {
        match server.accept().await {
            Ok(bytes) => {
                let url = SecretString::from_str(
                    std::str::from_utf8(bytes.expose_secret())
                        .context("Incoming deep link was not valid UTF-8")?,
                )
                .context("Impossible: can't wrap String into SecretString")?;
                // Ignore errors from this, it would only happen if the app is shutting down, otherwise we would wait
                ctlr_tx
                    .send(ControllerRequest::SchemeRequest(url))
                    .await
                    .ok();
            }
            Err(error) => tracing::error!(?error, "error while accepting deep link"),
        }
        // We re-create the named pipe server every time we get a link, because of an oddity in the Windows API.
        server = deep_link::Server::new().await?;
    }
}

#[must_use]
struct MainThreadLoop {
    app: gtk::Application,
    last_icon_set: Icon,
    main_rx: mpsc::Receiver<MainThreadReq>,
    tray_icon: tray_icon::TrayIcon,
}

impl MainThreadLoop {
    async fn run(mut self) -> Result<()> {
        while let Some(req) = self.main_rx.recv().await {
            match req {
                MainThreadReq::Quit => self.app.quit(),
                MainThreadReq::SetTrayMenu(app_state) => self.set_tray_menu(*app_state)?,
            }
        }
        Ok(())
    }

    fn set_tray_menu(&mut self, state: AppState) -> Result<()> {
        let base = match &state.connlib {
            ConnlibState::Loading
            | ConnlibState::Quitting
            | ConnlibState::RetryingConnection
            | ConnlibState::WaitingForBrowser
            | ConnlibState::WaitingForPortal
            | ConnlibState::WaitingForTunnel => IconBase::Busy,
            ConnlibState::SignedOut => IconBase::SignedOut,
            ConnlibState::SignedIn { .. } => IconBase::SignedIn,
        };
        let new_icon = Icon {
            base,
            update_ready: state.release.is_some(),
        };

        let menu = build_menu("", &state.into_menu())?;
        self.tray_icon.set_menu(Some(Box::new(menu)));
        // TODO: Set menu tooltip here too
        self.set_icon(new_icon)?;

        Ok(())
    }

    fn set_icon(&mut self, icon: Icon) -> Result<()> {
        if icon == self.last_icon_set {
            return Ok(());
        }
        // TODO: Does `tray-icon` have the same problem as `tao`,
        // where it writes PNGs to `/run/user/$UID/` every time you set an icon?
        self.tray_icon.set_icon(Some(icon_to_native_icon(&icon)))?;
        self.last_icon_set = icon;
        Ok(())
    }
}

fn icon_to_native_icon(that: &Icon) -> tray_icon::Icon {
    let layers = match that.base {
        IconBase::Busy => &[LOGO_GREY_BASE, BUSY_LAYER][..],
        IconBase::SignedIn => &[LOGO_BASE][..],
        IconBase::SignedOut => &[LOGO_GREY_BASE, SIGNED_OUT_LAYER][..],
    }
    .iter()
    .copied()
    .chain(that.update_ready.then_some(UPDATE_READY_LAYER));
    let composed =
        compositor::compose(layers).expect("PNG decoding should always succeed for baked-in PNGs");
    image_to_native_icon(composed)
}

fn image_to_native_icon(val: Image) -> tray_icon::Icon {
    tray_icon::Icon::from_rgba(val.rgba, val.width, val.height)
        .expect("Converting a tray icon to RGBA should always work")
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
    SetTrayMenu(Box<common::system_tray::AppState>),
}

async fn run_controller(
    main_tx: mpsc::Sender<MainThreadReq>, // Runs stuff on the main thread
    ctlr_tx: CtlrTx,
    rx: mpsc::Receiver<ControllerRequest>,
    log_filter_reloader: LogFilterReloader,
    telemetry: telemetry::Telemetry,
    updates_rx: mpsc::Receiver<Option<updates::Notification>>,
) -> Result<()> {
    let integration = GtkIntegration {
        main_tx: main_tx.clone(),
    };

    let controller = ControllerBuilder {
        advanced_settings: Default::default(), // TODO
        ctlr_tx,
        integration,
        log_filter_reloader,
        rx,
        telemetry,
        updates_rx,
    }
    .build()
    .await?;

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

    fn open_url<P: AsRef<str>>(&self, url: P) -> Result<()> {
        open::that(std::ffi::OsStr::new(url.as_ref()))?;
        Ok(())
    }

    fn set_tray_icon(&mut self, _icon: common::system_tray::Icon) -> Result<()> {
        tracing::warn!("set_tray_icon not implemented");
        Ok(())
    }

    fn set_tray_menu(&mut self, app_state: common::system_tray::AppState) -> Result<()> {
        self.main_tx
            .try_send(MainThreadReq::SetTrayMenu(Box::new(app_state)))?;
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

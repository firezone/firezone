//! The Tauri GUI for Windows
//! This is not checked or compiled on other platforms.

// TODO: `git grep` for unwraps before 1.0, especially this gui module

use crate::client::{self, deep_link, ipc, network_changes, AppLocalDataDir, BUNDLE_ID};
use anyhow::{anyhow, bail, Context, Result};
use client::{
    about, logging,
    settings::{self, AdvancedSettings},
};
use connlib_client_shared::ResourceDescription;
use connlib_shared::messages::ResourceId;
use secrecy::ExposeSecret;
use std::{path::PathBuf, str::FromStr, sync::Arc, time::Duration};
use system_tray_menu::Event as TrayMenuEvent;
use tauri::{api::notification::Notification, Manager, SystemTray, SystemTrayEvent};
use tokio::{
    sync::{mpsc, oneshot, Notify},
    time::timeout,
};
use ControllerRequest as Req;

mod system_tray_menu;

pub(crate) type CtlrTx = mpsc::Sender<ControllerRequest>;

// TODO: Move out of GUI module, shouldn't be here
pub(crate) fn app_local_data_dir() -> Result<AppLocalDataDir> {
    let path = known_folders::get_known_folder_path(known_folders::KnownFolder::LocalAppData)
        .context("should be able to ask Windows where AppData/Local is")?
        .join(BUNDLE_ID);
    Ok(AppLocalDataDir(path))
}

/// All managed state that we might need to access from odd places like Tauri commands.
///
/// Note that this never gets Dropped because of
/// <https://github.com/tauri-apps/tauri/issues/8631>
pub(crate) struct Managed {
    pub ctlr_tx: CtlrTx,
    pub inject_faults: bool,
}

impl Managed {
    #[cfg(debug_assertions)]
    /// In debug mode, if `--inject-faults` is passed, sleep for `millis` milliseconds
    pub async fn fault_msleep(&self, millis: u64) {
        if self.inject_faults {
            tokio::time::sleep(std::time::Duration::from_millis(millis)).await;
        }
    }

    #[cfg(not(debug_assertions))]
    /// Does nothing in release mode
    pub async fn fault_msleep(&self, _millis: u64) {}
}

/// Runs the Tauri GUI and returns on exit or unrecoverable error
pub(crate) fn run(params: client::GuiParams) -> Result<()> {
    // Change to data dir so the file logger will write there and not in System32 if we're launching from an app link
    let cwd = app_local_data_dir()?.0.join("data");
    std::fs::create_dir_all(&cwd)?;
    std::env::set_current_dir(&cwd)?;

    let advanced_settings = settings::load_advanced_settings().unwrap_or_default();

    // Start logging
    let _logging_handles = client::logging::setup(&advanced_settings.log_filter)?;
    tracing::info!("started log");
    tracing::info!("GIT_VERSION = {}", crate::client::GIT_VERSION);

    let client::GuiParams {
        crash_on_purpose,
        flag_elevated: _,
        inject_faults,
    } = params;

    // Need to keep this alive so crashes will be handled. Dropping detaches it.
    let _crash_handler = match client::crash_handling::attach_handler() {
        Ok(x) => Some(x),
        Err(error) => {
            // TODO: None of these logs are actually written yet
            // <https://github.com/firezone/firezone/issues/3211>
            tracing::warn!(?error, "Did not set up crash handler");
            None
        }
    };

    // Needed for the deep link server
    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    if crash_on_purpose {
        tokio::spawn(async {
            let delay = 10;
            tracing::info!("Will crash on purpose in {delay} seconds to test crash handling.");
            tokio::time::sleep(std::time::Duration::from_secs(delay)).await;
            tracing::info!("Crashing on purpose because of `--crash-on-purpose` flag");
            unsafe { sadness_generator::raise_segfault() }
        });
    }

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let notify_controller = Arc::new(Notify::new());

    // Make sure we're single-instance
    // We register our deep links to call the `open-deep-link` subcommand,
    // so if we're at this point, we know we've been launched manually
    let server = deep_link::Server::new()?;

    // We know now we're the only instance on the computer, so register our exe
    // to handle deep links
    deep_link::register()?;
    tokio::spawn(accept_deep_links(server, ctlr_tx.clone()));

    let managed = Managed {
        ctlr_tx: ctlr_tx.clone(),
        inject_faults,
    };

    let tray = SystemTray::new().with_menu(system_tray_menu::signed_out());

    tauri::Builder::default()
        .manage(managed)
        .on_window_event(|event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event.event() {
                // Keep the frontend running but just hide this webview
                // Per https://tauri.app/v1/guides/features/system-tray/#preventing-the-app-from-closing

                event.window().hide().unwrap();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            about::get_cargo_version,
            about::get_git_version,
            logging::clear_logs,
            logging::count_logs,
            logging::export_logs,
            settings::apply_advanced_settings,
            settings::reset_advanced_settings,
            settings::get_advanced_settings,
        ])
        .system_tray(tray)
        .on_system_tray_event(|app, event| {
            if let SystemTrayEvent::MenuItemClick { id, .. } = event {
                let event = match TrayMenuEvent::from_str(&id) {
                    Ok(x) => x,
                    Err(e) => {
                        tracing::error!("{e}");
                        return;
                    }
                };
                match handle_system_tray_event(app, event) {
                    Ok(_) => {}
                    Err(e) => tracing::error!("{e}"),
                }
            }
        })
        .setup(move |app| {
            assert_eq!(
                BUNDLE_ID,
                app.handle().config().tauri.bundle.identifier,
                "BUNDLE_ID should match bundle ID in tauri.conf.json"
            );

            let app_handle = app.handle();
            let _ctlr_task = tokio::spawn(async move {
                let result = run_controller(
                    app_handle.clone(),
                    ctlr_tx,
                    ctlr_rx,
                    advanced_settings,
                    notify_controller,
                )
                .await;

                // See <https://github.com/tauri-apps/tauri/issues/8631>
                // This should be the ONLY place we call `app.exit` or `app_handle.exit`,
                // because it exits the entire process without dropping anything.
                //
                // This seems to be a platform limitation that Tauri is unable to hide
                // from us. It was the source of much consternation at time of writing.

                if let Err(e) = result {
                    tracing::error!("run_controller returned an error: {e:#?}");
                    app_handle.exit(1);
                } else {
                    tracing::debug!("GUI controller task exited cleanly");
                    app_handle.exit(0);
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!())?
        .run(|_app_handle, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                // Don't exit if we close our main window
                // https://tauri.app/v1/guides/features/system-tray/#preventing-the-app-from-closing

                api.prevent_exit();
            }
        });
    Ok(())
}

/// Worker task to accept deep links from a named pipe forever
///
/// * `server` An initial named pipe server to consume before making new servers. This lets us also use the named pipe to enforce single-instance
async fn accept_deep_links(mut server: deep_link::Server, ctlr_tx: CtlrTx) -> Result<()> {
    loop {
        if let Ok(url) = server.accept().await {
            ctlr_tx
                .send(ControllerRequest::SchemeRequest(url))
                .await
                .ok();
        }
        // We re-create the named pipe server every time we get a link, because of an oddity in the Windows API.
        server = deep_link::Server::new()?;
    }
}

fn handle_system_tray_event(app: &tauri::AppHandle, event: TrayMenuEvent) -> Result<()> {
    let ctlr_tx = &app
        .try_state::<Managed>()
        .ok_or_else(|| anyhow!("can't get Managed struct from Tauri"))?
        .ctlr_tx;

    // TODO: Just handle these in Controller directly: <https://github.com/firezone/firezone/issues/2983>
    match event {
        TrayMenuEvent::About => {
            let win = app
                .get_window("about")
                .ok_or_else(|| anyhow!("getting handle to About window"))?;

            if win.is_visible()? {
                win.hide()?;
            } else {
                win.show()?;
            }
        }
        TrayMenuEvent::CancelSignIn => ctlr_tx.blocking_send(ControllerRequest::CancelSignIn)?,
        TrayMenuEvent::Resource { id } => {
            ctlr_tx.blocking_send(ControllerRequest::CopyResource(id))?
        }
        TrayMenuEvent::Settings => {
            let win = app
                .get_window("settings")
                .ok_or_else(|| anyhow!("getting handle to Settings window"))?;

            if win.is_visible()? {
                // If we close the window here, we can't re-open it, we'd have to fully re-create it. Not needed for MVP - We agreed 100 MB is fine for the GUI client.
                win.hide()?;
            } else {
                win.show()?;
            }
        }
        TrayMenuEvent::SignIn => ctlr_tx.blocking_send(ControllerRequest::SignIn)?,
        TrayMenuEvent::SignOut => ctlr_tx.blocking_send(ControllerRequest::SignOut)?,
        TrayMenuEvent::Quit => ctlr_tx.blocking_send(ControllerRequest::Quit)?,
    }
    Ok(())
}

pub(crate) enum ControllerRequest {
    Callback(ipc::Callback),
    CancelSignIn,
    CopyResource(String),
    ExportLogs { path: PathBuf, stem: PathBuf },
    GetAdvancedSettings(oneshot::Sender<AdvancedSettings>),
    Quit,
    SchemeRequest(url::Url),
    SignIn,
    SignOut,
}

struct Controller {
    /// Debugging-only settings like API URL, auth URL, log filter
    advanced_settings: AdvancedSettings,
    app: tauri::AppHandle,
    // Sign-in state with the portal / deep links
    auth: client::auth::Auth,
    ctlr_tx: CtlrTx,
    /// connlib session for the currently signed-in user, if there is one
    session: Option<Session>,
    /// Kills subprocesses when our own process exits
    leak_guard: ipc::LeakGuard,
    notify_controller: Arc<Notify>,
    resources: Vec<ResourceDescription>,
    tunnel_ready: bool,
}

/// Everything related to a signed-in user session
struct Session {
    _response_rx: mpsc::Receiver<ipc::ManagerMsg>,
    server_write: ipc::ServerWriteHalf,
    worker: ipc::SubcommandChild,
}

impl Session {
    async fn close(mut self) -> anyhow::Result<()> {
        tracing::info!("disconnecting connlib");
        self.server_write.close().await?;
        self.worker
            .wait_then_kill(Duration::from_secs(2))
            .await
            .context("couldn't join or kill connlib worker")?;
        Ok(())
    }
}

impl Controller {
    async fn new(
        app: tauri::AppHandle,
        advanced_settings: AdvancedSettings,
        ctlr_tx: CtlrTx,
        notify_controller: Arc<Notify>,
    ) -> Result<Self> {
        let mut this = Self {
            advanced_settings,
            app,
            auth: client::auth::Auth::new()?,
            ctlr_tx,
            session: None,
            leak_guard: ipc::LeakGuard::new()?,
            notify_controller,
            resources: vec![],
            tunnel_ready: false,
        };

        if let Some(_token) = this.auth.token()? {
            // Connect immediately if we reloaded the token
            if let Err(error) = this.start_session().await {
                tracing::error!(?error, "couldn't restart session on app start");
            }
        }

        Ok(this)
    }

    // TODO: Figure out how re-starting sessions automatically will work
    /// Pre-req: the auth module must be signed in
    async fn start_session(&mut self) -> Result<()> {
        if self.session.is_some() {
            bail!("can't start session, we're already in a session");
        }

        let args = ["connlib-worker"];
        let mut subprocess = timeout(
            Duration::from_secs(10),
            ipc::Subprocess::new(&mut self.leak_guard, &args),
        )
        .await
        .context("timed out while starting subprocess")?
        .context("error while starting subprocess")?;
        subprocess
            .server
            .send(ipc::ManagerMsg::Connect)
            .await
            .context("couldn't send Connect request to worker")?;
        let ipc::ManagerMsg::Connect = subprocess
            .server
            .response_rx
            .recv()
            .await
            .context("didn't get response from worker")?
        else {
            anyhow::bail!("Expected Connected back from connlib worker");
        };

        let ipc::Subprocess { server, worker } = subprocess;

        let (server_read, server_write) = server.into_split();
        let ipc::ServerReadHalf {
            mut cb_rx,
            _response_rx,
        } = server_read;

        let ctlr_tx = self.ctlr_tx.clone();

        // TODO: Make sure this task doesn't leak
        tokio::task::spawn(async move {
            while let Some(cb) = cb_rx.recv().await {
                ctlr_tx.send(ControllerRequest::Callback(cb)).await?;
            }
            tracing::info!("callback receiver task exiting");
            Ok::<_, anyhow::Error>(())
        });

        self.session = Some(Session {
            _response_rx,
            server_write,
            worker,
        });

        Ok(())
    }

    fn copy_resource(&self, id: &str) -> Result<()> {
        if self.session.is_none() {
            bail!("app is signed out");
        };
        let id = ResourceId::from_str(id)?;
        let Some(res) = self.resources.iter().find(|r| r.id() == id) else {
            bail!("resource ID is not in the list");
        };
        let mut clipboard = arboard::Clipboard::new()?;
        // TODO: Make this a method on `ResourceDescription`
        match res {
            ResourceDescription::Dns(x) => clipboard.set_text(&x.address)?,
            ResourceDescription::Cidr(x) => clipboard.set_text(&x.address.to_string())?,
        }
        Ok(())
    }

    async fn handle_deep_link(&mut self, url: &url::Url) -> Result<()> {
        let Some(auth_response) = client::deep_link::parse_auth_callback(url) else {
            // TODO: `bail` is redundant here, just do `.context("")?;` since it's `anyhow`
            bail!("couldn't parse scheme request");
        };

        let _token = self.auth.handle_response(auth_response)?;
        if let Err(e) = self.start_session().await {
            // TODO: Replace `bail` with `context` here too
            bail!("couldn't start session: {e:#?}");
        }
        Ok(())
    }

    /// Returns a new system tray menu
    fn build_system_tray_menu(&self) -> tauri::SystemTrayMenu {
        // TODO: Refactor this and the auth module so that "Are we logged in"
        // doesn't require such complicated control flow to answer.
        if let Some(auth_session) = self.auth.session() {
            if self.session.is_some() {
                if self.tunnel_ready {
                    // Signed in, tunnel ready
                    system_tray_menu::signed_in(&auth_session.actor_name, &self.resources)
                } else {
                    // Signed in, raising tunnel
                    system_tray_menu::signing_in()
                }
            } else {
                tracing::error!("We have an auth session but no connlib session");
                system_tray_menu::signed_out()
            }
        } else if self.auth.ongoing_request().is_ok() {
            // Signing in, waiting on deep link callback
            system_tray_menu::signing_in()
        } else {
            system_tray_menu::signed_out()
        }
    }

    /// Builds a new system tray menu and applies it to the app
    fn refresh_system_tray_menu(&self) -> Result<()> {
        Ok(self
            .app
            .tray_handle()
            .set_menu(self.build_system_tray_menu())?)
    }
}

// TODO: Move some of this into `impl Controller`
async fn run_controller(
    app: tauri::AppHandle,
    ctlr_tx: CtlrTx,
    mut rx: mpsc::Receiver<ControllerRequest>,
    advanced_settings: AdvancedSettings,
    notify_controller: Arc<Notify>,
) -> Result<()> {
    let mut controller =
        Controller::new(app.clone(), advanced_settings, ctlr_tx, notify_controller)
            .await
            .context("couldn't create Controller")?;

    let mut have_internet = network_changes::check_internet()?;
    tracing::debug!(?have_internet);

    let mut com_worker = network_changes::Worker::new()?;

    loop {
        // TODO: Extract a step function so this loop isn't so long and so indented
        tokio::select! {
            () = controller.notify_controller.notified() => if let Err(e) = controller.refresh_system_tray_menu() {
                tracing::error!("couldn't reload resource list: {e:#?}");
            },
            () = com_worker.notified() => {
                let new_have_internet = network_changes::check_internet()?;
                if new_have_internet != have_internet {
                    have_internet = new_have_internet;
                    // TODO: Stop / start / restart connlib as needed here
                    tracing::debug!(?have_internet);
                }
            },
            req = rx.recv() => {
                let Some(req) = req else {
                    break;
                };
                match req {
                    Req::CopyResource(id) => if let Err(e) = controller.copy_resource(&id) {
                        tracing::error!("couldn't copy resource to clipboard: {e:#?}");
                    }
                    Req::Callback(ipc::Callback::DisconnectedTokenExpired) | Req::Callback(ipc::Callback::OnDisconnect) | Req::CancelSignIn | Req::SignOut => {
                        tracing::debug!("Token expired, user signed out, user canceled sign-in, or connlib disconnected");
                        controller.auth.sign_out()?;
                        controller.tunnel_ready = false;
                        if let Some(session) = controller.session.take() {
                            session.close().await?;
                        }
                        else {
                            // Might just be because we got a double sign-out or
                            // the user canceled the sign-in or something innocent.
                            tracing::warn!("tried to sign out but there's no session");
                        }
                        controller.refresh_system_tray_menu()?;
                    }
                    Req::Callback(cb) => match cb {
                        // TODO: Make this impossible
                        ipc::Callback::Cookie(_) => bail!("Cookie isn't supposed to show up here"),
                        ipc::Callback::DisconnectedTokenExpired => bail!("DisconnectedTokenExpired should be handled above here"),
                        ipc::Callback::OnDisconnect => bail!("DisconnectedTokenExpired should be handled above here"),
                        ipc::Callback::OnUpdateResources(resources) => {
                            controller.resources = resources;
                            controller.refresh_system_tray_menu()?;
                        },
                        ipc::Callback::TunnelReady => {
                            controller.tunnel_ready = true;
                            controller.refresh_system_tray_menu()?;

                            // May say "Windows Powershell" in dev mode
                            // See https://github.com/tauri-apps/tauri/issues/3700
                            Notification::new(&controller.app.config().tauri.bundle.identifier)
                                .title("Firezone connected")
                                .body("You are now signed in and able to access resources.")
                            .show()?;
                        },
                    }
                    Req::ExportLogs{path, stem} => logging::export_logs_to(path, stem).await?,
                    Req::GetAdvancedSettings(tx) => {
                        tx.send(controller.advanced_settings.clone()).ok();
                    }
                    Req::Quit => break,
                    Req::SchemeRequest(url) => if let Err(e) = controller.handle_deep_link(&url).await {
                        tracing::error!("couldn't handle deep link: {e:#?}");
                    }
                    Req::SignIn => {
                        if let Some(req) = controller.auth.start_sign_in()? {
                            let url = req.to_url(&controller.advanced_settings.auth_base_url);
                            controller.refresh_system_tray_menu()?;
                            tauri::api::shell::open(
                                &app.shell_scope(),
                                &url.expose_secret().inner,
                                None,
                            )?;
                        }
                    }
                }
            }
        }
    }

    if let Some(session) = controller.session.take() {
        session.close().await?;
    }

    if let Err(error) = com_worker.close() {
        tracing::error!(?error, "com_worker");
    }

    // Last chance to do any drops / cleanup before the process crashes.

    Ok(())
}

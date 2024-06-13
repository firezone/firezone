//! Implementation of headless Client and IPC service for Windows
//!
//! Try not to panic in the IPC service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use crate::{CliCommon, SignalKind};
use anyhow::{Context as _, Result};
use connlib_client_shared::file_logger;
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};
use tracing::subscriber::set_global_default;
use tracing_subscriber::{layer::SubscriberExt as _, EnvFilter, Layer, Registry};
use windows_service::{
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
};

mod wintun_install;

#[cfg(debug_assertions)]
const SERVICE_RUST_LOG: &str = "firezone_headless_client=debug,firezone_tunnel=trace,phoenix_channel=debug,connlib_shared=debug,connlib_client_shared=debug,boringtun=debug,snownet=debug,str0m=info,info";

#[cfg(not(debug_assertions))]
const SERVICE_RUST_LOG: &str = "str0m=warn,info";

const SERVICE_NAME: &str = "firezone_client_ipc";
const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;

// This looks like a pointless wrapper around `CtrlC`, because it must match
// the Linux signatures
pub(crate) struct Signals {
    sigint: tokio::signal::windows::CtrlC,
}

impl Signals {
    pub(crate) fn new() -> Result<Self> {
        let sigint = tokio::signal::windows::ctrl_c()?;
        Ok(Self { sigint })
    }

    pub(crate) async fn recv(&mut self) -> SignalKind {
        self.sigint.recv().await;
        SignalKind::Interrupt
    }
}

// The return value is useful on Linux
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn check_token_permissions(_path: &Path) -> Result<()> {
    // TODO: For Headless Client, make sure the token is only readable by admin / our service user on Windows
    Ok(())
}

pub(crate) fn default_token_path() -> std::path::PathBuf {
    // TODO: For Headless Client, system-wide default token path for Windows
    PathBuf::from("token.txt")
}

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub(crate) fn run_ipc_service(_cli: CliCommon) -> Result<()> {
    windows_service::service_dispatcher::start(SERVICE_NAME, ffi_service_run).context("windows_service::service_dispatcher failed. This isn't running in an interactive terminal, right?")
}

/// Wintun stress test to shake out issue #4765
pub(crate) fn run_wintun() -> Result<()> {
    crate::debug_command_setup()?;

    let iters = 100;
    for i in 0..iters {
        tracing::info!(?i, "Loop");
        wintun::Tun::new().context("`Tun::new` failed")?;
    }
    Ok(())
}

/// Copies of functions from `tun_windows.rs` but with `anyhow` so it's easier to debug
mod wintun {
    use anyhow::{bail, Context as _, Result};
    use connlib_shared::{
        windows::{CREATE_NO_WINDOW, TUNNEL_NAME},
        DEFAULT_MTU,
    };
    use std::{
        io,
        os::windows::process::CommandExt,
        process::{Command, Stdio},
        str::FromStr,
        sync::Arc,
        thread::sleep,
        time::Duration,
    };
    use tokio::sync::mpsc;
    use windows::Win32::{
        NetworkManagement::{
            IpHelper::{GetIpInterfaceEntry, SetIpInterfaceEntry, MIB_IPINTERFACE_ROW},
            Ndis::NET_LUID_LH,
        },
        Networking::WinSock::{AF_INET, AF_INET6},
    };
    use wintun::Adapter;

    // Not sure how this and `TUNNEL_NAME` differ
    const ADAPTER_NAME: &str = "Firezone";

    pub(crate) struct Tun {
        _packet_rx: mpsc::Receiver<wintun::Packet>,
        recv_thread: Option<std::thread::JoinHandle<()>>,
        session: Arc<wintun::Session>,
    }

    impl Drop for Tun {
        fn drop(&mut self) {
            if let Err(error) = self.session.shutdown() {
                tracing::error!(?error, "`wintun::Session::shutdown` failed");
            }
            if let Some(recv_thread) = self.recv_thread.take() {
                if let Err(error) = recv_thread.join() {
                    tracing::error!(?error, "Couldn't join `recv_thread`");
                }
            } else {
                tracing::error!("No `recv_thread` in `Tun`");
            }
        }
    }

    impl Tun {
        #[tracing::instrument]
        pub(crate) fn new() -> Result<Self> {
            const TUNNEL_UUID: &str = "e9245bc1-b8c1-44ca-ab1d-c6aad4f13b9c";

            // SAFETY: we're loading a DLL from disk and it has arbitrary C code in it.
            // The Windows client, in `wintun_install` hashes the DLL at startup, before calling connlib, so it's unlikely for the DLL to be accidentally corrupted by the time we get here.
            let path = connlib_shared::windows::wintun_dll_path()?;
            let wintun = unsafe { wintun::load_from_path(path) }?;

            // Create wintun adapter
            let uuid = uuid::Uuid::from_str(TUNNEL_UUID)
                .expect("static UUID should always parse correctly")
                .as_u128();
            let adapter = Adapter::create(&wintun, ADAPTER_NAME, TUNNEL_NAME, Some(uuid))?;
            let iface_idx = adapter
                .get_adapter_index()
                .context("`get_adapter_index` failed")?;

            // Remove any routes that were previously associated with us
            // TODO: Pick a more elegant way to do this
            Command::new("powershell")
                .creation_flags(CREATE_NO_WINDOW)
                .arg("-Command")
                .arg(format!(
                    "Remove-NetRoute -InterfaceIndex {iface_idx} -Confirm:$false"
                ))
                .stdout(Stdio::null())
                .status()?;

            set_iface_config(adapter.get_luid(), DEFAULT_MTU)?;

            let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);
            let (packet_tx, packet_rx) = mpsc::channel(5);
            let recv_thread = start_recv_thread(packet_tx, Arc::clone(&session))?;
            Ok(Self {
                recv_thread: Some(recv_thread),
                _packet_rx: packet_rx,
                session: Arc::clone(&session),
            })
        }
    }

    fn start_recv_thread(
        packet_tx: mpsc::Sender<wintun::Packet>,
        session: Arc<wintun::Session>,
    ) -> io::Result<std::thread::JoinHandle<()>> {
        std::thread::Builder::new()
            .name("Firezone wintun worker".into())
            .spawn(move || {
                loop {
                    match session.receive_blocking() {
                        Ok(pkt) => {
                            if packet_tx.blocking_send(pkt).is_err() {
                                // Most likely the receiver was dropped and we're closing down the connlib session.
                                break;
                            }
                        }
                        Err(wintun::Error::ShuttingDown) => break,
                        Err(e) => {
                            tracing::error!("wintun::Session::receive_blocking: {e:#?}");
                            break;
                        }
                    }
                }
                tracing::debug!("recv_task exiting gracefully");
            })
    }

    /// Delete old wintun adapter if needed
    ///
    /// We delete it because `get_adapter_index` doesn't work on adapters opened by
    /// `open`, per wintun docs.
    fn delete_old_adapter(wintun: &wintun::Wintun) -> Result<()> {
        if let Ok(adapter) = Adapter::open(wintun, ADAPTER_NAME) {
            tracing::warn!("Deleting existing wintun adapter");
            let adapter = Arc::into_inner(adapter)
                .context("Nobody else should have a handle to this wintun adapter")?;
            if let Err(error) = adapter.delete() {
                tracing::error!(?error, "Error while deleting existing wintun adapter");
            } else {
                tracing::debug!("Deleted existing wintun adapter");
            }
        } else {
            tracing::debug!("No existing wintun adapter, good");
        }
        Ok(())
    }

    /// Sets MTU on the interface
    /// TODO: Set IP and other things in here too, so the code is more organized
    fn set_iface_config(luid: wintun::NET_LUID_LH, mtu: u32) -> Result<()> {
        // SAFETY: Both NET_LUID_LH unions should be the same. We're just copying out
        // the u64 value and re-wrapping it, since wintun doesn't refer to the windows
        // crate's version of NET_LUID_LH.
        let luid = NET_LUID_LH {
            Value: unsafe { luid.Value },
        };

        // Set MTU for IPv4
        {
            let mut row = MIB_IPINTERFACE_ROW {
                Family: AF_INET,
                InterfaceLuid: luid,
                ..Default::default()
            };

            // SAFETY: TODO
            unsafe { GetIpInterfaceEntry(&mut row) }.ok()?;

            // https://stackoverflow.com/questions/54857292/setipinterfaceentry-returns-error-invalid-parameter
            row.SitePrefixLength = 0;

            // Set MTU for IPv4
            row.NlMtu = mtu;

            // SAFETY: TODO
            unsafe { SetIpInterfaceEntry(&mut row) }.ok()?;
        }

        // Set MTU for IPv6
        {
            let mut row = MIB_IPINTERFACE_ROW {
                Family: AF_INET6,
                InterfaceLuid: luid,
                ..Default::default()
            };

            // SAFETY: TODO
            unsafe { GetIpInterfaceEntry(&mut row) }.ok()?;

            // https://stackoverflow.com/questions/54857292/setipinterfaceentry-returns-error-invalid-parameter
            row.SitePrefixLength = 0;

            // Set MTU for IPv4
            row.NlMtu = mtu;

            // SAFETY: TODO
            unsafe { SetIpInterfaceEntry(&mut row) }.ok()?;
        }
        Ok(())
    }
}

// Generates `ffi_service_run` from `service_run`
windows_service::define_windows_service!(ffi_service_run, windows_service_run);

fn windows_service_run(arguments: Vec<OsString>) {
    let log_path = crate::known_dirs::ipc_service_logs()
        .expect("Should be able to compute IPC service logs dir");
    std::fs::create_dir_all(&log_path).expect("We should have permissions to create our log dir");
    let (layer, handle) = file_logger::layer(&log_path);
    let filter = EnvFilter::from_str(SERVICE_RUST_LOG)
        .expect("Hard-coded log filter should always be parsable");
    let subscriber = Registry::default().with(layer.with_filter(filter));
    set_global_default(subscriber).expect("`set_global_default` should always work)");
    tracing::info!(git_version = crate::GIT_VERSION);
    if let Err(error) = fallible_windows_service_run(arguments, handle) {
        tracing::error!(?error, "`fallible_windows_service_run` returned an error");
    }
}

// Most of the Windows-specific service stuff should go here
//
// The arguments don't seem to match the ones passed to the main thread at all.
//
// If Windows stops us gracefully, this function may never return.
fn fallible_windows_service_run(
    arguments: Vec<OsString>,
    logging_handle: file_logger::Handle,
) -> Result<()> {
    tracing::info!(?arguments, "fallible_windows_service_run");

    let rt = tokio::runtime::Runtime::new()?;
    rt.spawn(crate::heartbeat::heartbeat());

    let ipc_task = rt.spawn(super::ipc_listen());
    let ipc_task_ah = ipc_task.abort_handle();

    let event_handler = move |control_event| -> ServiceControlHandlerResult {
        tracing::debug!(?control_event);
        match control_event {
            // TODO
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            ServiceControl::PowerEvent(event) => {
                tracing::info!(?event, "Power event");
                ServiceControlHandlerResult::NoError
            }
            ServiceControl::Shutdown | ServiceControl::Stop => {
                tracing::info!(?control_event, "Got stop signal from service controller");
                ipc_task_ah.abort();
                ServiceControlHandlerResult::NoError
            }
            ServiceControl::UserEvent(_) => ServiceControlHandlerResult::NoError,
            ServiceControl::Continue
            | ServiceControl::NetBindAdd
            | ServiceControl::NetBindDisable
            | ServiceControl::NetBindEnable
            | ServiceControl::NetBindRemove
            | ServiceControl::ParamChange
            | ServiceControl::Pause
            | ServiceControl::Preshutdown
            | ServiceControl::HardwareProfileChange(_)
            | ServiceControl::SessionChange(_)
            | ServiceControl::TimeChange
            | ServiceControl::TriggerEvent => {
                tracing::warn!(?control_event, "Unhandled service control event");
                ServiceControlHandlerResult::NotImplemented
            }
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    };

    // Tell Windows that we're running (equivalent to sd_notify in systemd)
    let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)?;
    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::POWER_EVENT
            | ServiceControlAccept::SHUTDOWN
            | ServiceControlAccept::STOP,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;

    let result = match rt.block_on(ipc_task) {
        Err(join_error) if join_error.is_cancelled() => {
            // We cancelled because Windows asked us to shut down.
            Ok(())
        }
        Err(join_error) => Err(anyhow::Error::from(join_error).context("`ipc_listen` panicked")),
        Ok(Err(error)) => Err(error.context("`ipc_listen` threw an error")),
        Ok(Ok(impossible)) => match impossible {},
    };
    if let Err(error) = &result {
        tracing::error!(?error, "`ipc_listen` failed");
    }

    // Drop the logging handle so it flushes the logs before we let Windows kill our process.
    // There is no obvious and elegant way to do this, since the logging and `ServiceState`
    // changes are interleaved, not nested:
    // - Start logging
    // - ServiceState::Running
    // - Stop logging
    // - ServiceState::Stopped
    std::mem::drop(logging_handle);

    // Tell Windows that we're stopping
    // Per Windows docs, this will cause Windows to kill our process eventually.
    status_handle
        .set_service_status(ServiceStatus {
            service_type: SERVICE_TYPE,
            current_state: ServiceState::Stopped,
            controls_accepted: ServiceControlAccept::empty(),
            exit_code: ServiceExitCode::Win32(if result.is_ok() { 0 } else { 1 }),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })
        .expect("Should be able to tell Windows we're stopping");
    // Generally unreachable
    Ok(())
}

// Does nothing on Windows. On Linux this notifies systemd that we're ready.
// When we eventually have a system service for the Windows Headless Client,
// this could notify the Windows service controller too.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn notify_service_controller() -> Result<()> {
    Ok(())
}

pub(crate) fn setup_before_connlib() -> Result<()> {
    wintun_install::ensure_dll()?;
    Ok(())
}

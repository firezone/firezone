use crate::CliCommon;
use anyhow::{bail, Context as _, Result};
use firezone_bin_shared::platform::DnsControlMethod;
use firezone_telemetry::Telemetry;
use futures::channel::mpsc;
use std::{
    ffi::{c_void, OsStr, OsString},
    mem::size_of,
    time::Duration,
};
use windows::{
    core::PWSTR,
    Win32::{
        Foundation::{CloseHandle, HANDLE},
        Security::{
            GetTokenInformation, LookupAccountSidW, TokenElevation, TokenUser, SID_NAME_USE,
            TOKEN_ELEVATION, TOKEN_QUERY, TOKEN_USER,
        },
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    },
};
use windows_service::{
    service::{
        ServiceAccess, ServiceControl, ServiceControlAccept, ServiceErrorControl, ServiceExitCode,
        ServiceInfo, ServiceStartType, ServiceState, ServiceStatus, ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_manager::{ServiceManager, ServiceManagerAccess},
};

const SERVICE_NAME: &str = "firezone_client_ipc";
const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;

/// Returns true if the IPC service can run properly
pub(crate) fn elevation_check() -> Result<bool> {
    let token = ProcessToken::our_process().context("Failed to get process token")?;
    let elevated = token
        .is_elevated()
        .context("Failed to get elevation status")?;
    let username = token.username().context("Failed to get username")?;

    tracing::debug!(%username, %elevated);

    Ok(elevated)
}

// https://stackoverflow.com/questions/8046097/how-to-check-if-a-process-has-the-administrative-rights/8196291#8196291
struct ProcessToken {
    inner: HANDLE,
}

impl ProcessToken {
    fn our_process() -> Result<Self> {
        // SAFETY: Calling C APIs is unsafe
        // `GetCurrentProcess` returns a pseudo-handle which does not need to be closed.
        // Docs say nothing about thread safety. <https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getcurrentprocess>
        let our_proc = unsafe { GetCurrentProcess() };
        let mut inner = HANDLE::default();
        // SAFETY: We just created `inner`, and moving a `HANDLE` is safe.
        // We assume that if `OpenProcessToken` fails, we don't need to close the `HANDLE`.
        // Docs say nothing about threads or safety: <https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken>
        unsafe { OpenProcessToken(our_proc, TOKEN_QUERY, &mut inner) }
            .context("`OpenProcessToken` failed")?;
        Ok(Self { inner })
    }

    fn is_elevated(&self) -> Result<bool> {
        let mut elevation = TOKEN_ELEVATION::default();
        let token_elevation_sz = u32::try_from(size_of::<TOKEN_ELEVATION>())
            .context("Failed to convert `TOKEN_ELEVATION` to u32")?;
        let mut return_size = 0u32;
        // SAFETY: Docs say nothing about threads or safety <https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation>
        // The type of `elevation` varies based on the 2nd parameter, but we hard-coded that.
        // It should be fine.
        unsafe {
            GetTokenInformation(
                self.inner,
                TokenElevation,
                Some(&mut elevation as *mut _ as *mut c_void),
                token_elevation_sz,
                &mut return_size as *mut _,
            )
        }?;
        Ok(elevation.TokenIsElevated == 1)
    }

    fn username(&self) -> Result<String> {
        // Normally, the pattern here is to call `GetTokenInformation` with a size of 0 and retrieve the necessary buffer length from the first error.
        // This doesn't seem to work in this case so we just allocate a hopefully sufficiently large buffer ahead of time.
        let token_user_sz = 1024;
        let mut token_user = vec![0u8; token_user_sz as usize];
        let token_user = token_user.as_mut_ptr() as *mut TOKEN_USER;

        let mut return_sz = 0;

        // Fetch the actual user information.
        // SAFETY: Docs say nothing about threads or safety <https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation>
        unsafe {
            GetTokenInformation(
                self.inner,
                TokenUser,
                Some(token_user as *mut c_void),
                token_user_sz,
                &mut return_sz,
            )
        }?;

        let mut name = vec![0u16; 256];
        let mut domain = vec![0u16; 256];
        let mut name_size = name.len() as u32;
        let mut domain_size = domain.len() as u32;
        let mut sid_type = SID_NAME_USE::default();

        // Convert account ID to human-friendly name.

        // SAFETY: We allocated the buffer.
        let sid = unsafe { (*token_user).User.Sid };

        // SAFETY: Docs say nothing about threads or safety <https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation>
        unsafe {
            LookupAccountSidW(
                None,
                sid,
                PWSTR::from_raw(name.as_mut_ptr()),
                &mut name_size,
                PWSTR::from_raw(domain.as_mut_ptr()),
                &mut domain_size,
                &mut sid_type,
            )
        }?;

        let name = String::from_utf16_lossy(&name[..name_size as usize]);
        let domain = String::from_utf16_lossy(&domain[..domain_size as usize]);

        Ok(format!("{name}\\{domain}"))
    }
}

impl Drop for ProcessToken {
    fn drop(&mut self) {
        // SAFETY: We got `inner` from `OpenProcessToken` and didn't mutate it after that.
        // Closing a pseudo-handle is a harmless no-op, though this is a real handle.
        // <https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getcurrentprocess>
        // > The pseudo handle need not be closed when it is no longer needed. Calling the CloseHandle function with a pseudo handle has no effect. If the pseudo handle is duplicated by DuplicateHandle, the duplicate handle must be closed.
        unsafe { CloseHandle(self.inner) }.expect("`CloseHandle` should always succeed");
        self.inner = HANDLE::default();
    }
}

pub(crate) fn install_ipc_service() -> Result<()> {
    let manager_access = ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE;
    let service_manager = ServiceManager::local_computer(None::<&str>, manager_access)?;

    let name = "FirezoneClientIpcServiceDebug";

    // Un-install existing one first if needed
    if let Err(e) =
        uninstall_ipc_service(&service_manager, name).with_context(|| format!("Failed to uninstall `{name}`"))
    {
        tracing::debug!("{e:#}");
    }

    let executable_path = std::env::current_exe()?;
    let service_info = ServiceInfo {
        name: OsString::from(name),
        display_name: OsString::from("Firezone Client IPC (Debug)"),
        service_type: ServiceType::OWN_PROCESS,
        start_type: ServiceStartType::AutoStart,
        error_control: ServiceErrorControl::Normal,
        executable_path,
        launch_arguments: vec!["run".into()],
        dependencies: vec![],
        account_name: None,
        account_password: None,
    };
    let service = service_manager.create_service(&service_info, ServiceAccess::CHANGE_CONFIG)?;
    service.set_description("Description")?;
    Ok(())
}

fn uninstall_ipc_service(service_manager: &ServiceManager, name: impl AsRef<OsStr>) -> Result<()> {
    let service_access = ServiceAccess::DELETE;
    let service = service_manager.open_service(name, service_access)?;
    service.delete()?;

    Ok(())
}

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub(crate) fn run_ipc_service(_cli: CliCommon) -> Result<()> {
    windows_service::service_dispatcher::start(SERVICE_NAME, ffi_service_run).context("windows_service::service_dispatcher failed. This isn't running in an interactive terminal, right?")
}

// Generates `ffi_service_run` from `service_run`
windows_service::define_windows_service!(ffi_service_run, service_run);

fn service_run(arguments: Vec<OsString>) {
    // `arguments` doesn't seem to work right when running as a Windows service
    // (even though it's meant for that) so just use the default log dir.
    let (handle, log_filter_reloader) =
        super::setup_logging(None).expect("Should be able to set up logging");
    if let Err(error) = fallible_service_run(arguments, handle, log_filter_reloader) {
        tracing::error!("`fallible_windows_service_run` returned an error: {error:#}");
    }
}

// Most of the Windows-specific service stuff should go here
//
// The arguments don't seem to match the ones passed to the main thread at all.
//
// If Windows stops us gracefully, this function may never return.
fn fallible_service_run(
    arguments: Vec<OsString>,
    logging_handle: firezone_logging::file::Handle,
    log_filter_reloader: crate::LogFilterReloader,
) -> Result<()> {
    tracing::info!(?arguments, "fallible_windows_service_run");
    if !elevation_check()? {
        bail!("IPC service failed its elevation check, try running as admin / root");
    }

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let (mut shutdown_tx, shutdown_rx) = mpsc::channel(1);

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
                if shutdown_tx.try_send(()).is_err() {
                    tracing::error!("Should be able to send shutdown signal");
                }
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

    let mut telemetry = Telemetry::default();

    // Add new features in `service_run_async` if possible.
    // We don't want to bail out of `fallible_service_run` and forget to tell
    // Windows that we're shutting down.
    let result = rt
        .block_on(service_run_async(
            &log_filter_reloader,
            &mut telemetry,
            shutdown_rx,
        ))
        .inspect(|_| rt.block_on(telemetry.stop()))
        .inspect_err(|e| {
            tracing::error!("IPC service failed: {e:#}");

            rt.block_on(telemetry.stop_on_crash())
        });

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
        .context("Should be able to tell Windows we're stopping")?;
    // Generally unreachable. Windows typically kills the process first,
    // but doesn't guarantee it.
    Ok(())
}

/// The main loop for the Windows service
///
/// This is split off from other functions because we don't want to accidentally
/// bail out of a fallible function and not tell Windows that we're stopping
/// the service. So it's okay to bail out of `service_run_async`, but not
/// out of its caller.
///
/// Logging must already be set up before calling this.
async fn service_run_async(
    log_filter_reloader: &crate::LogFilterReloader,
    telemetry: &mut Telemetry,
    shutdown_rx: mpsc::Receiver<()>,
) -> Result<()> {
    // Useless - Windows will never send us Ctrl+C when running as a service
    // This just keeps the signatures simpler
    let mut signals = crate::signals::Terminate::from_channel(shutdown_rx);
    super::ipc_listen(
        DnsControlMethod::Nrpt,
        log_filter_reloader,
        &mut signals,
        telemetry,
    )
    .await
    .context("`ipc_listen` threw an error")?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[expect(clippy::print_stdout, reason = "We want to see the output in the test")]
    fn get_username_of_current_process() {
        let process_token = ProcessToken::our_process().unwrap();
        let username = process_token.username().unwrap(); // If this doesn't panic, we are good.

        println!("Running as user: {username}")
    }
}

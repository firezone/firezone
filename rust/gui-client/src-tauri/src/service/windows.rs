use anyhow::{Context as _, Result};
use bin_shared::DnsControlMethod;
use futures::channel::mpsc;
use std::path::PathBuf;
use std::{
    ffi::{OsStr, OsString, c_void},
    mem::size_of,
    time::Duration,
};
use windows::{
    Win32::{
        Foundation::{CloseHandle, HANDLE},
        Security::{
            GetTokenInformation, LookupAccountSidW, SID_NAME_USE, TOKEN_ELEVATION, TOKEN_QUERY,
            TOKEN_USER, TokenElevation, TokenUser,
        },
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    },
    core::PWSTR,
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

/// Returns true if the Tunnel service can run properly
pub fn elevation_check() -> Result<bool> {
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
                Some(PWSTR::from_raw(name.as_mut_ptr())),
                &mut name_size,
                Some(PWSTR::from_raw(domain.as_mut_ptr())),
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

pub fn install() -> Result<()> {
    let manager_access = ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE;
    let service_manager = ServiceManager::local_computer(None::<&str>, manager_access)?;

    let name = "FirezoneClientTunnelServiceDebug";

    // Un-install existing one first if needed
    if let Err(e) = uninstall_tunnel_service(&service_manager, name)
        .with_context(|| format!("Failed to uninstall `{name}`"))
    {
        tracing::debug!("{e:#}");
    }

    let executable_path = std::env::current_exe()?;
    let service_info = ServiceInfo {
        name: OsString::from(name),
        display_name: OsString::from("Firezone Tunnel Service (Debug)"),
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

fn uninstall_tunnel_service(
    service_manager: &ServiceManager,
    name: impl AsRef<OsStr>,
) -> Result<()> {
    let service_access = ServiceAccess::DELETE;
    let service = service_manager.open_service(name, service_access)?;
    service.delete()?;

    Ok(())
}

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub fn run(_log_dir: Option<PathBuf>, _dns_control: DnsControlMethod) -> Result<()> {
    windows_service::service_dispatcher::start(SERVICE_NAME, run_service_ffi).context("windows_service::service_dispatcher failed. This isn't running in an interactive terminal, right?")
}

// Generates `run_service_ffi` from `service_run`
windows_service::define_windows_service!(run_service_ffi, run_service);

fn run_service(arguments: Vec<OsString>) {
    // `arguments` doesn't seem to work right when running as a Windows service
    // (even though it's meant for that) so just use the default log dir.
    let (_handle, log_filter_reloader) =
        crate::logging::setup_tunnel(None).expect("Should be able to set up logging");

    tracing::info!(?arguments, "run_service");

    if !elevation_check().is_ok_and(|elevated| elevated) {
        tracing::info!("Tunnel service failed its elevation check, try running as admin / root");

        return;
    }

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("connlib")
        .enable_all()
        .build()
        .expect("Failed to create tokio runtime");

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

    let status_handle = match service_control_handler::register(SERVICE_NAME, event_handler)
        .context("Failed to register Windows service")
    {
        Ok(handle) => handle,
        Err(e) => {
            tracing::error!("{e:#}");
            return;
        }
    };

    // Tell Windows that we're running (equivalent to sd_notify in systemd)
    let _ = status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::POWER_EVENT
            | ServiceControlAccept::SHUTDOWN
            | ServiceControlAccept::STOP,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    });

    let mut signals = bin_shared::signals::Terminate::from_channel(shutdown_rx);

    let result = rt
        .block_on(super::ipc_listen(
            DnsControlMethod::Nrpt,
            &log_filter_reloader,
            &mut signals,
        ))
        .inspect_err(|e| tracing::error!("Tunnel service failed: {e:#}"));

    // Tell Windows that we're stopping
    // Per Windows docs, this will cause Windows to kill our process eventually.
    let _ = status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Stopped,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(if result.is_ok() { 0 } else { 1 }),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    });

    rt.shutdown_timeout(Duration::from_secs(1)); // Ensure we don't block forever on a task in the blocking pool.
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

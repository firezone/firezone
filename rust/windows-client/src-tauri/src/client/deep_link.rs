//! A module for registering deep links that are sent over to the app's already-running instance
//! Based on reading some of the Windows code from <https://github.com/FabianLars/tauri-plugin-deep-link>, which is licensed "MIT OR Apache-2.0"

use std::{ffi::c_void, io, path::Path};
use tokio::{io::AsyncReadExt, io::AsyncWriteExt, net::windows::named_pipe};
use windows::Win32::Security as WinSec;

pub(crate) const FZ_SCHEME: &str = "firezone-fd0020211111";

#[derive(thiserror::Error, Debug)]
pub enum Error {
    /// Error from client's POV
    #[error(transparent)]
    ClientCommunications(io::Error),
    /// Error while connecting to the server
    #[error(transparent)]
    Connect(io::Error),
    /// Something went wrong finding the path to our own exe
    #[error(transparent)]
    CurrentExe(io::Error),
    /// We got some data but it's not UTF-8
    #[error(transparent)]
    LinkNotUtf8(std::string::FromUtf8Error),
    /// This means we are probably the second instance
    #[error("named pipe server couldn't start listening")]
    Listen,
    /// Error from server's POV
    #[error(transparent)]
    ServerCommunications(io::Error),
    /// Something went wrong setting up the registry
    #[error(transparent)]
    WindowsRegistry(io::Error),
}

/// Accepts one incoming deep link from a named pipe client
pub async fn accept(id: &str) -> Result<(), Error> {
    // This isn't air-tight - We recreate the whole server on each loop,
    // rather than binding 1 socket and accepting many streams like a normal socket API.
    // I can only assume Tokio is following Windows' underlying API.

    // We could instead pick an ephemeral TCP port and write that to a file,
    // akin to how Unix processes will write their PID to a file to manage long-running instances
    // But this doesn't require us to listen on TCP.

    let mut server_options = named_pipe::ServerOptions::new();
    server_options.first_pipe_instance(true);

    // This will allow non-admin clients to connect to us even if we're running as admin
    let mut sd = WinSec::SECURITY_DESCRIPTOR::default();
    let psd = WinSec::PSECURITY_DESCRIPTOR(&mut sd as *mut _ as *mut c_void);
    unsafe {
        // ChatGPT pointed me to these functions, it's better than the official MS docs
        WinSec::InitializeSecurityDescriptor(
            psd,
            windows::Win32::System::SystemServices::SECURITY_DESCRIPTOR_REVISION,
        )
        .map_err(|_| Error::Listen)?;
        WinSec::SetSecurityDescriptorDacl(psd, true, None, false).map_err(|_| Error::Listen)?;
    }

    let mut sa = WinSec::SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<WinSec::SECURITY_ATTRIBUTES>()
            .try_into()
            .unwrap(),
        lpSecurityDescriptor: psd.0,
        bInheritHandle: false.into(),
    };

    let path = named_pipe_path(id);
    let mut server = unsafe {
        server_options.create_with_security_attributes_raw(path, &mut sa as *mut _ as *mut c_void)
    }
    .map_err(|_| Error::Listen)?;

    tracing::debug!("server is bound");
    server
        .connect()
        .await
        .map_err(Error::ServerCommunications)?;
    tracing::debug!("server got connection");

    // TODO: Limit the read size here. Our typical callback is 350 bytes, so 4,096 bytes should be more than enough.
    // Also, I think `read_to_end` can do partial reads because this is a network socket,
    // not a file. We might need a length-prefixed or newline-terminated format for IPC.
    let mut req = vec![];
    server
        .read_to_end(&mut req)
        .await
        .map_err(Error::ServerCommunications)?;

    server.disconnect().ok();

    tracing::debug!("Server read");
    let req = String::from_utf8(req).map_err(Error::LinkNotUtf8)?;
    tracing::info!("{}", req);

    Ok(())
}

/// Open a deep link by sending it to the already-running instance of the app
pub async fn open(id: &str, url: &url::Url) -> Result<(), Error> {
    let path = named_pipe_path(id);
    let mut client = named_pipe::ClientOptions::new()
        .open(path)
        .map_err(Error::Connect)?;
    client
        .write_all(url.as_str().as_bytes())
        .await
        .map_err(Error::ClientCommunications)?;
    Ok(())
}

/// Registers the current exe as the handler for our deep link scheme.
///
/// This is copied almost verbatim from tauri-plugin-deep-link's `register` fn, with an improvement
/// that we send the deep link to a subcommand so the URL won't confuse `clap`
///
/// * `id` A unique ID for the app, e.g. "com.contoso.todo-list" or "dev.firezone.client"
pub fn register(id: &str) -> Result<(), Error> {
    let exe = tauri_utils::platform::current_exe()
        .map_err(Error::CurrentExe)?
        .display()
        .to_string()
        .replace("\\\\?\\", "");

    set_registry_values(id, &exe).map_err(Error::WindowsRegistry)?;

    Ok(())
}

/// Set up the Windows registry to call the given exe when our deep link scheme is used
///
/// All errors from this function are registry-related
fn set_registry_values(id: &str, exe: &str) -> Result<(), io::Error> {
    let hkcu = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER);
    let base = Path::new("Software").join("Classes").join(FZ_SCHEME);

    let (key, _) = hkcu.create_subkey(&base)?;
    key.set_value("", &format!("URL:{}", id))?;
    key.set_value("URL Protocol", &"")?;

    let (icon, _) = hkcu.create_subkey(base.join("DefaultIcon"))?;
    icon.set_value("", &format!("{},0", &exe))?;

    let (cmd, _) = hkcu.create_subkey(base.join("shell").join("open").join("command"))?;
    cmd.set_value("", &format!("{} open-deep-link \"%1\"", &exe))?;

    Ok(())
}

fn named_pipe_path(id: &str) -> String {
    format!(r"\\.\pipe\{}", id)
}

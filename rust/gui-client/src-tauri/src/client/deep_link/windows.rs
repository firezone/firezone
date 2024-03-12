//! A module for registering, catching, and parsing deep links that are sent over to the app's already-running instance
//! Based on reading some of the Windows code from <https://github.com/FabianLars/tauri-plugin-deep-link>, which is licensed "MIT OR Apache-2.0"

use super::{Error, FZ_SCHEME};
use anyhow::Result;
use connlib_shared::BUNDLE_ID;
use secrecy::Secret;
use std::{ffi::c_void, io, path::Path};
use tokio::{io::AsyncReadExt, io::AsyncWriteExt, net::windows::named_pipe};
use windows::Win32::Security as WinSec;

/// A server for a named pipe, so we can receive deep links from other instances
/// of the client launched by web browsers
pub(crate) struct Server {
    inner: named_pipe::NamedPipeServer,
}

impl Server {
    /// Construct a server, but don't await client connections yet
    ///
    /// Panics if there is no Tokio runtime
    pub(crate) fn new() -> Result<Self> {
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
        // SAFETY: Unsafe needed to call Win32 API. There shouldn't be any threading
        // or lifetime problems because we only pass pointers to our local vars to
        // Win32, and Win32 shouldn't save them anywhere.
        unsafe {
            // ChatGPT pointed me to these functions, it's better than the official MS docs
            WinSec::InitializeSecurityDescriptor(
                psd,
                windows::Win32::System::SystemServices::SECURITY_DESCRIPTOR_REVISION,
            )
            .map_err(|_| Error::SecurityDescriptor)?;
            WinSec::SetSecurityDescriptorDacl(psd, true, None, false)
                .map_err(|_| Error::SecurityDescriptor)?;
        }

        let mut sa = WinSec::SECURITY_ATTRIBUTES {
            // TODO: Try `size_of_val` here instead
            nLength: std::mem::size_of::<WinSec::SECURITY_ATTRIBUTES>()
                .try_into()
                .unwrap(),
            lpSecurityDescriptor: psd.0,
            bInheritHandle: false.into(),
        };

        // TODO: On the IPC branch I found that this will cause prefix issues
        // with other named pipes. Change it.
        let path = named_pipe_path(BUNDLE_ID);
        let sa_ptr = &mut sa as *mut _ as *mut c_void;
        // SAFETY: Unsafe needed to call Win32 API. There shouldn't be any threading
        // or lifetime problems because we only pass pointers to our local vars to
        // Win32, and Win32 shouldn't save them anywhere.
        let server = unsafe { server_options.create_with_security_attributes_raw(path, sa_ptr) }
            .map_err(|_| Error::CantListen)?;

        tracing::debug!("server is bound");
        Ok(Server { inner: server })
    }

    /// Await one incoming deep link from a named pipe client
    /// Tokio's API is strange, so this consumes the server.
    /// I assume this is based on the underlying Windows API.
    /// I tried re-using the server and it acted strange. The official Tokio
    /// examples are not clear on this.
    pub(crate) async fn accept(mut self) -> Result<Secret<Vec<u8>>> {
        self.inner
            .connect()
            .await
            .map_err(Error::ServerCommunications)?;
        tracing::debug!("server got connection");

        // TODO: Limit the read size here. Our typical callback is 350 bytes, so 4,096 bytes should be more than enough.
        // Also, I think `read_to_end` can do partial reads because this is a named pipe,
        // not a file. We might need a length-prefixed or newline-terminated format for IPC.
        let mut bytes = vec![];
        self.inner
            .read_to_end(&mut bytes)
            .await
            .map_err(Error::ServerCommunications)?;
        let bytes = Secret::new(bytes);

        self.inner.disconnect().ok();
        Ok(bytes)
    }
}

/// Open a deep link by sending it to the already-running instance of the app
pub async fn open(url: &url::Url) -> Result<(), Error> {
    let path = named_pipe_path(BUNDLE_ID);
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
pub fn register() -> Result<(), Error> {
    let exe = tauri_utils::platform::current_exe()
        .map_err(Error::CurrentExe)?
        .display()
        .to_string()
        .replace("\\\\?\\", "");

    set_registry_values(BUNDLE_ID, &exe).map_err(Error::WindowsRegistry)?;

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

/// Returns a valid name for a Windows named pipe
///
/// # Arguments
///
/// * `id` - BUNDLE_ID, e.g. `dev.firezone.client`
fn named_pipe_path(id: &str) -> String {
    format!(r"\\.\pipe\{}", id)
}

#[cfg(test)]
mod tests {
    #[test]
    fn named_pipe_path() {
        assert_eq!(
            super::named_pipe_path("dev.firezone.client"),
            r"\\.\pipe\dev.firezone.client"
        );
    }
}

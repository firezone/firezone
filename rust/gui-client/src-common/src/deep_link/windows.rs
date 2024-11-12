//! A module for registering, catching, and parsing deep links that are sent over to the app's already-running instance
//! Based on reading some of the Windows code from <https://github.com/FabianLars/tauri-plugin-deep-link>, which is licensed "MIT OR Apache-2.0"

use super::FZ_SCHEME;
use anyhow::{Context, Result};
use firezone_bin_shared::BUNDLE_ID;
use firezone_logging::std_dyn_err;
use secrecy::Secret;
use std::{
    io,
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::{io::AsyncReadExt, io::AsyncWriteExt, net::windows::named_pipe};

/// A server for a named pipe, so we can receive deep links from other instances
/// of the client launched by web browsers
pub struct Server {
    inner: named_pipe::NamedPipeServer,
}

impl Server {
    /// Construct a server, but don't await client connections yet
    ///
    /// Panics if there is no Tokio runtime
    /// Still uses `thiserror` so we can catch the deep_link `CantListen` error
    pub async fn new() -> Result<Self, super::Error> {
        // This isn't air-tight - We recreate the whole server on each loop,
        // rather than binding 1 socket and accepting many streams like a normal socket API.
        // Tokio appears to be following Windows' underlying API here, so not
        // much we can do until Unix domain sockets have wide support in Windows.
        let server = bind_to_pipe(&pipe_path()).await?;

        tracing::debug!("server is bound");
        Ok(Server { inner: server })
    }

    /// Await one incoming deep link from a named pipe client
    /// Tokio's API is strange, so this consumes the server.
    /// I assume this is based on the underlying Windows API.
    /// I tried re-using the server and it acted strange. The official Tokio
    /// examples are not clear on this.
    pub async fn accept(mut self) -> Result<Option<Secret<Vec<u8>>>> {
        self.inner
            .connect()
            .await
            .context("Couldn't accept connection from named pipe client")?;
        tracing::debug!("server got connection");

        // TODO: Limit the read size here. Our typical callback is 350 bytes, so 4,096 bytes should be more than enough.
        // Also, I think `read_to_end` can do partial reads because this is a named pipe,
        // not a file. We might need a length-prefixed or newline-terminated format for IPC.
        let mut bytes = vec![];
        self.inner
            .read_to_end(&mut bytes)
            .await
            .context("Couldn't read bytes from named pipe client")?;
        let bytes = Secret::new(bytes);

        self.inner.disconnect().ok();
        Ok(Some(bytes))
    }
}

async fn bind_to_pipe(pipe_path: &str) -> Result<named_pipe::NamedPipeServer, super::Error> {
    const NUM_ITERS: usize = 10;
    // Relating to #5143 and #5566, sometimes re-creating a named pipe server
    // in a loop fails. This is copied from `firezone_headless_client::ipc_service::ipc::windows`.
    for i in 0..NUM_ITERS {
        match create_pipe_server(pipe_path) {
            Ok(server) => return Ok(server),
            Err(e) => {
                tracing::debug!(
                    error = std_dyn_err(&e),
                    "`create_pipe_server` failed, sleeping... (attempt {i}/{NUM_ITERS})"
                );
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
    Err(super::Error::CantListen)
}

fn create_pipe_server(pipe_path: &str) -> io::Result<named_pipe::NamedPipeServer> {
    let mut server_options = named_pipe::ServerOptions::new();
    server_options.first_pipe_instance(true);

    let server = server_options.create(pipe_path)?;

    Ok(server)
}

/// Open a deep link by sending it to the already-running instance of the app
pub async fn open(url: &url::Url) -> Result<()> {
    let path = pipe_path();
    let mut client = named_pipe::ClientOptions::new()
        .open(&path)
        .with_context(|| format!("Couldn't connect to named pipe server at `{path}`"))?;
    client
        .write_all(url.as_str().as_bytes())
        .await
        .with_context(|| format!("Couldn't write bytes to named pipe server at `{path}`"))?;
    Ok(())
}

fn pipe_path() -> String {
    firezone_headless_client::ipc::platform::named_pipe_path(&format!("{BUNDLE_ID}.deep_link"))
}

/// Registers the current exe as the handler for our deep link scheme.
///
/// This is copied almost verbatim from tauri-plugin-deep-link's `register` fn, with an improvement
/// that we send the deep link to a subcommand so the URL won't confuse `clap`
pub fn register(exe: PathBuf) -> Result<()> {
    let exe = exe.display().to_string().replace("\\\\?\\", "");

    set_registry_values(BUNDLE_ID, &exe).context("Can't set Windows Registry values")?;

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

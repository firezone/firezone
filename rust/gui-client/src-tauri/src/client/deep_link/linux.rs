use crate::client::known_dirs;
use anyhow::{bail, Context, Result};
use secrecy::{ExposeSecret, Secret};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
};

const SOCK_NAME: &str = "deep_link.sock";

pub(crate) struct Server {
    listener: UnixListener,
}

impl Server {
    /// Create a new deep link server to make sure we're the only instance
    pub(crate) fn new() -> Result<Self> {
        let dir = known_dirs::runtime().context("couldn't find runtime dir")?;
        let path = dir.join(SOCK_NAME);
        // TODO: This breaks single instance. Can we enforce it some other way?
        std::fs::remove_file(&path).ok();
        std::fs::create_dir_all(&dir).context("Can't create dir for deep link socket")?;

        let listener = UnixListener::bind(&path).context("Couldn't bind listener Unix socket")?;

        // Figure out who we were before `sudo`, if using sudo
        if let Ok(username) = std::env::var("SUDO_USER") {
            std::process::Command::new("chown")
                .arg(username)
                .arg(&path)
                .status()?;
        }

        Ok(Self { listener })
    }

    /// Await one incoming deep link
    ///
    /// To match the Windows API, this consumes the `Server`.
    pub(crate) async fn accept(self) -> Result<Secret<Vec<u8>>> {
        tracing::debug!("deep_link::accept");
        let (mut stream, _) = self.listener.accept().await?;
        tracing::debug!("Accepted Unix domain socket connection");

        // TODO: Limit reads to 4,096 bytes. Partial reads will probably never happen
        // since it's a local socket transferring very small data.
        let mut bytes = vec![];
        stream
            .read_to_end(&mut bytes)
            .await
            .context("failed to read incoming deep link over Unix socket stream")?;
        let bytes = Secret::new(bytes);
        tracing::debug!(
            len = bytes.expose_secret().len(),
            "Got data from Unix domain socket"
        );
        Ok(bytes)
    }
}

pub(crate) async fn open(url: &url::Url) -> Result<()> {
    crate::client::logging::debug_command_setup()?;

    let dir = known_dirs::runtime().context("deep_link::open couldn't find runtime dir")?;
    let path = dir.join(SOCK_NAME);
    let mut stream = UnixStream::connect(&path).await?;

    stream.write_all(url.to_string().as_bytes()).await?;

    Ok(())
}

/// Register a URI scheme so that browser can deep link into our app for auth
///
/// Performs blocking I/O (Waits on `xdg-desktop-menu` subprocess)
pub(crate) fn register() -> Result<()> {
    // Write `$HOME/.local/share/applications/firezone-client.desktop`
    // According to <https://wiki.archlinux.org/title/Desktop_entries>, that's the place to put
    // per-user desktop entries.
    let dir = dirs::data_local_dir()
        .context("can't figure out where to put our desktop entry")?
        .join("applications");
    std::fs::create_dir_all(&dir)?;

    // Don't use atomic writes here - If we lose power, we'll just rewrite this file on
    // the next boot anyway.
    let path = dir.join("firezone-client.desktop");
    let exe = std::env::current_exe().context("failed to find our own exe path")?;
    let content = format!(
        "[Desktop Entry]
Version=1.0
Name=Firezone
Comment=Firezone GUI Client
Exec={} open-deep-link %U
Terminal=false
Type=Application
MimeType=x-scheme-handler/{}
Categories=Network;
",
        exe.display(),
        super::FZ_SCHEME
    );
    std::fs::write(&path, content).context("failed to write desktop entry file")?;

    // Run `xdg-desktop-menu install` with that desktop file
    let xdg_desktop_menu = "xdg-desktop-menu";
    let status = std::process::Command::new(xdg_desktop_menu)
        .arg("install")
        .arg(&path)
        .status()
        .with_context(|| format!("failed to run `{xdg_desktop_menu}`"))?;
    if !status.success() {
        bail!("failed to register our deep link scheme")
    }
    Ok(())
}

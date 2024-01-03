//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client::cli::Cli;
use anyhow::Result;
use tokio::runtime::Runtime;

// TODO: In tauri-plugin-deep-link, this is the identifier in tauri.conf.json
const PIPE_NAME: &str = "dev.firezone.client";

#[derive(Clone, Default)]
struct CbHandler {}

#[derive(thiserror::Error, Debug)]
enum CbError {
    #[error("system DNS resolver problem: {0}")]
    Resolvers(#[from] crate::client::resolvers::Error),
}

impl connlib_client_shared::Callbacks for CbHandler {
    type Error = CbError;

    fn on_disconnect(
        &self,
        error: Option<&connlib_client_shared::Error>,
    ) -> Result<(), Self::Error> {
        tracing::debug!(error = ?error, "tunnel_disconnected");
        Ok(())
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        tracing::debug!("tunnel_connected");
        Ok(())
    }

    fn get_system_default_resolvers(&self) -> Result<Option<Vec<std::net::IpAddr>>, Self::Error> {
        Ok(Some(crate::client::resolvers::get()?))
    }
}

struct HeadlessTestClient {
    api_url: url::Url,
    device_id: String,
    token: secrecy::SecretString,
    cb_handler: CbHandler,
}

impl HeadlessTestClient {
    async fn new() -> Result<Self> {
        let device_id = crate::client::device_id::device_id(&crate::client::AppLocalDataDir(
            std::path::PathBuf::from("C:/Users/User/AppData/Local/dev.firezone.client"),
        ))
        .await?;

        let api_url = url::Url::parse("wss://api.firezone.dev")?;
        let token = tokio::task::spawn_blocking(|| {
            Ok::<_, anyhow::Error>(secrecy::SecretString::from(
                keyring::Entry::new_with_target("dev.firezone.client/token", "", "")?
                    .get_password()?,
            ))
        })
        .await??;

        Ok(Self {
            device_id,
            api_url,
            token,
            cb_handler: Default::default(),
        })
    }

    fn start_connlib(&self) -> Result<connlib_client_shared::Session<CbHandler>> {
        Ok(connlib_client_shared::Session::connect(
            self.api_url.clone(),
            self.token.clone(),
            self.device_id.clone(),
            self.cb_handler.clone(),
            std::time::Duration::from_secs(5 * 60),
        )?)
    }
}

/// Use a token from the Credential Manager to cycle connlib on and off forever
pub fn connlib() -> Result<()> {
    tracing_subscriber::fmt::init();
    let rt = Runtime::new()?;

    rt.block_on(async {
        let connlib = HeadlessTestClient::new().await?;
        // Print the normal IP address
        {
            let http = reqwest::Client::new();
            let resp = http
                .get("https://ifconfig.net/ip")
                .send()
                .await?
                .text()
                .await?;
            tracing::info!("{resp}");
        }

        // Start and stop connlib twice, works fine
        for i in 0..2 {
            tracing::info!("start_connlib {i}");
            let mut session = connlib.start_connlib()?;
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            session.disconnect(None);
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }

        // Start and stop connlib twice, but use the ifconfig resource while the tunnel is up
        // the 1st run won't stop properly, causing the 2nd run to not start.
        for i in 0..2 {
            tracing::info!("start_connlib {i}");
            let mut session = connlib.start_connlib()?;
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;

            {
                let http = reqwest::Client::new();
                let resp = http
                    .get("https://ifconfig.net/ip")
                    .send()
                    .await?
                    .text()
                    .await?;
                tracing::info!("{resp}");
            }
            session.disconnect(None);
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
        Ok(())
    })
}

pub fn hostname() -> Result<()> {
    println!(
        "{:?}",
        hostname::get().ok().and_then(|x| x.into_string().ok())
    );
    Ok(())
}

pub fn open_deep_link(path: &url::Url) -> Result<()> {
    tracing_subscriber::fmt::init();

    let rt = Runtime::new()?;
    rt.block_on(crate::client::deep_link::open(PIPE_NAME, path))?;
    Ok(())
}

// Copied the named pipe idea from `interprocess` and `tauri-plugin-deep-link`,
// although I believe it's considered best practice on Windows to use named pipes for
// single-instance apps.
pub fn pipe_server() -> Result<()> {
    tracing_subscriber::fmt::init();

    let rt = Runtime::new()?;
    rt.block_on(async {
        loop {
            let server = crate::client::deep_link::Server::new(PIPE_NAME)?;
            server.accept().await?;
        }
    })
}

// This is copied almost verbatim from tauri-plugin-deep-link's `register` fn, with an improvement
// that we send the deep link to a subcommand so the URL won't confuse `clap`
pub fn register_deep_link() -> Result<()> {
    crate::client::deep_link::register(PIPE_NAME)?;
    Ok(())
}

pub fn wintun(_: Cli) -> Result<()> {
    tracing_subscriber::fmt::init();

    if crate::client::elevation::check()? {
        tracing::info!("Elevated");
    } else {
        tracing::warn!("Not elevated")
    }
    Ok(())
}

use anyhow::{Context, Result};
use clap::Parser;
use ip_network::IpNetwork;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    path::PathBuf,
    str::FromStr,
};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::{fmt, prelude::*};

use firezone_client_connlib::{
    file_logger, get_device_id, get_user_agent, Callbacks, Error, ResourceDescription, Session,
};
use url::Url;

#[derive(Clone)]
pub struct CallbackHandler;

impl Callbacks for CallbackHandler {
    type Error = std::convert::Infallible;

    fn on_set_interface_config(
        &self,
        _tunnel_address_v4: Ipv4Addr,
        _tunnel_address_v6: Ipv6Addr,
        _dns_address: Ipv4Addr,
        _dns_fallback_strategy: String,
    ) -> Result<RawFd, Self::Error> {
        Ok(-1)
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        tracing::trace!("Tunnel connected");
        Ok(())
    }

    fn on_add_route(&self, _route: IpNetwork) -> Result<(), Self::Error> {
        Ok(())
    }

    fn on_remove_route(&self, _route: IpNetwork) -> Result<(), Self::Error> {
        Ok(())
    }

    fn on_update_resources(
        &self,
        resource_list: Vec<ResourceDescription>,
    ) -> Result<(), Self::Error> {
        tracing::trace!(message = "Resources updated", ?resource_list);
        Ok(())
    }

    fn on_disconnect(&self, error: Option<&Error>) -> Result<(), Self::Error> {
        tracing::trace!("Tunnel disconnected: {error:?}");
        // Note that we can't panic here, since we already hooked the panic to this function.
        std::process::exit(0);
    }

    fn on_error(&self, error: &Error) -> Result<(), Self::Error> {
        tracing::warn!("Encountered recoverable error: {error}");
        Ok(())
    }
}

const URL_ENV_VAR: &str = "FZ_URL";
const SECRET_ENV_VAR: &str = "FZ_SECRET";
const LOG_DIR_ENV_VAR: &str = "FZ_LOG_DIR";
const DEFAULT_LOG_DIR: &str = "/var/log/firezone";

fn block_on_ctrl_c() {
    let (tx, rx) = std::sync::mpsc::channel();
    ctrlc::set_handler(move || tx.send(()).expect("Could not send stop signal on channel."))
        .expect("Error setting Ctrl-C handler");
    rx.recv().expect("Could not receive ctrl-c signal");
}

fn init_logging(log_dir: PathBuf) -> WorkerGuard {
    let (file_layer, guard) = file_logger::layer(log_dir);

    // Calling init twice causes a panic; instead use try_init which will fail
    // gracefully if this is called more than once.
    let _ = tracing_subscriber::registry()
        .with(fmt::layer())
        .with(file_layer)
        .try_init();

    guard
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    if cli.print_agent {
        println!("{}", get_user_agent());
        return Ok(());
    }

    // TODO: allow passing as arg vars
    let url = parse_env_var::<Url>(URL_ENV_VAR)?;
    let secret = parse_env_var::<String>(SECRET_ENV_VAR)?;
    let device_id = get_device_id();
    let log_dir = parse_env_var::<PathBuf>(LOG_DIR_ENV_VAR).unwrap_or(DEFAULT_LOG_DIR.into());

    let guard = init_logging(log_dir);

    let mut session =
        Session::connect(url, secret, device_id, Some(guard), CallbackHandler).unwrap();
    tracing::info!("Started new session");

    block_on_ctrl_c();

    session.disconnect(None);
    Ok(())
}

fn parse_env_var<T>(key: &str) -> Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    let res = std::env::var(key)
        .with_context(|| format!("`{key}` env variable is unset"))?
        .parse()
        .with_context(|| format!("failed to parse {key} env variable"))?;

    Ok(res)
}

// probably will change this to a subcommand in the future
#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[arg(short, long)]
    print_agent: bool,
}

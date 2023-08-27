use anyhow::{Context, Result};
use ip_network::IpNetwork;
use std::os::fd::RawFd;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    str::FromStr,
};

use firezone_gateway_connlib::{get_external_id, Callbacks, Error, ResourceDescription, Session};
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
        tracing::trace!("Tunnel connected with address");
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
        tracing::trace!("Resources updated, current list: {resource_list:?}");
        Ok(())
    }

    fn on_disconnect(&self, error: Option<&Error>) -> Result<(), Self::Error> {
        tracing::warn!("Tunnel disconnected: {error:?}");
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

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    // TODO: allow passing as arg vars
    let url = parse_env_var::<Url>(URL_ENV_VAR)?;
    let secret = parse_env_var::<String>(SECRET_ENV_VAR)?;
    let external_id = get_external_id();
    let mut session = Session::connect(url, secret, external_id, CallbackHandler).unwrap();

    let (tx, rx) = std::sync::mpsc::channel();
    ctrlc::set_handler(move || tx.send(()).expect("Could not send stop signal on channel."))
        .expect("Error setting Ctrl-C handler");
    rx.recv().expect("Could not receive ctrl-c signal");

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

use anyhow::{Context, Result};
use clap::Parser;
use std::str::FromStr;

use firezone_client_connlib::{
    get_user_agent, Callbacks, Error, ErrorType, ResourceList, Session, TunnelAddresses,
};
use url::Url;

enum CallbackHandler {}

impl Callbacks for CallbackHandler {
    fn on_update_resources(_resource_list: ResourceList) {
        todo!()
    }

    fn on_set_tunnel_adresses(_tunnel_addresses: TunnelAddresses) {
        todo!()
    }

    fn on_error(error: &Error, error_type: ErrorType) {
        match error_type {
            ErrorType::Recoverable => tracing::warn!("Encountered error: {error}"),
            ErrorType::Fatal => panic!("Encountered fatal error: {error}"),
        }
    }
}

const URL_ENV_VAR: &str = "FZ_URL";
const SECRET_ENV_VAR: &str = "FZ_SECRET";

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let cli = Cli::parse();
    if cli.print_agent {
        println!("{}", get_user_agent());
        return Ok(());
    }

    // TODO: allow passing as arg vars
    let url = parse_env_var::<Url>(URL_ENV_VAR)?;
    let secret = parse_env_var::<String>(SECRET_ENV_VAR)?;
    // TODO: This is disgusting
    let mut session = Session::<CallbackHandler>::connect::<CallbackHandler>(url, secret).unwrap();
    tracing::info!("Started new session");
    session.wait_for_ctrl_c().unwrap();
    session.disconnect();
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

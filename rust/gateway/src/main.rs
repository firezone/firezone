use crate::eventloop::{Eventloop, PHOENIX_TOPIC};
use anyhow::{Context, Result};
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use firezone_bin_shared::{
    http_health_check,
    linux::{tcp_socket_factory, udp_socket_factory},
    TunDeviceManager,
};
use firezone_logging::anyhow_dyn_err;
use firezone_telemetry::Telemetry;
use firezone_tunnel::messages::Interface;
use firezone_tunnel::{GatewayTunnel, IPV4_PEERS, IPV6_PEERS};
use phoenix_channel::get_user_agent;
use phoenix_channel::LoginUrl;

use futures::channel::mpsc;
use futures::{future, StreamExt, TryFutureExt};
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use secrecy::{Secret, SecretString};
use std::convert::Infallible;
use std::path::Path;
use std::pin::pin;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::signal::ctrl_c;
use tracing_subscriber::layer;
use url::Url;
use uuid::Uuid;

mod eventloop;

const ID_PATH: &str = "/var/lib/firezone/gateway_id";

fn main() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    let cli = Cli::parse();

    let mut telemetry = Telemetry::default();
    if cli.is_telemetry_allowed() {
        telemetry.start(
            cli.api_url.as_str(),
            env!("CARGO_PKG_VERSION"),
            firezone_telemetry::GATEWAY_DSN,
        );
    }

    let runtime = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");

    match runtime.block_on(try_main(cli, &mut telemetry)) {
        Ok(()) => runtime.block_on(telemetry.stop()),
        Err(e) => {
            // Enforce errors only being printed on a single line using the technique recommended in the anyhow docs:
            // https://docs.rs/anyhow/latest/anyhow/struct.Error.html#display-representations
            //
            // By default, `anyhow` prints a stacktrace when it exits.
            // That looks like a "crash" but we "just" exit with a fatal error.
            tracing::error!(error = anyhow_dyn_err(&e));
            runtime.block_on(telemetry.stop_on_crash());

            std::process::exit(1);
        }
    }
}

async fn try_main(cli: Cli, telemetry: &mut Telemetry) -> Result<()> {
    firezone_logging::setup_global_subscriber(layer::Identity::default())?;

    let firezone_id = get_firezone_id(cli.firezone_id).await
        .context("Couldn't read FIREZONE_ID or write it to disk: Please provide it through the env variable or provide rw access to /var/lib/firezone/")?;
    telemetry.set_firezone_id(firezone_id.clone());

    let login = LoginUrl::gateway(
        cli.api_url,
        &SecretString::new(cli.token),
        firezone_id,
        cli.firezone_name,
    )?;

    let task = tokio::spawn(run(login)).err_into();

    let ctrl_c = pin!(ctrl_c().map_err(anyhow::Error::new));

    tokio::spawn(http_health_check::serve(
        cli.health_check.health_check_addr,
        || true,
    ));

    match future::try_select(task, ctrl_c)
        .await
        .map_err(|e| e.factor_first().0)?
    {
        future::Either::Left((res, _)) => {
            res?;
        }
        future::Either::Right(_) => {}
    };

    Ok(())
}

async fn get_firezone_id(env_id: Option<String>) -> Result<String> {
    if let Some(id) = env_id {
        if !id.is_empty() {
            return Ok(id);
        }
    }

    if let Ok(id) = tokio::fs::read_to_string(ID_PATH).await {
        if !id.is_empty() {
            return Ok(id);
        }
    }

    let id_path = Path::new(ID_PATH);
    tokio::fs::create_dir_all(id_path.parent().context("Missing parent")?).await?;
    let mut id_file = tokio::fs::File::create(id_path).await?;
    let id = Uuid::new_v4().to_string();
    id_file.write_all(id.as_bytes()).await?;
    Ok(id)
}

async fn run(login: LoginUrl<PublicKeyParam>) -> Result<Infallible> {
    let mut tunnel = GatewayTunnel::new(Arc::new(tcp_socket_factory), Arc::new(udp_socket_factory));
    let portal = PhoenixChannel::disconnected(
        Secret::new(login),
        get_user_agent(None, env!("CARGO_PKG_VERSION")),
        PHOENIX_TOPIC,
        (),
        ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(None)
            .build(),
        Arc::new(tcp_socket_factory),
    )?;

    let (sender, receiver) = mpsc::channel::<Interface>(10);
    let mut tun_device_manager = TunDeviceManager::new(ip_packet::PACKET_SIZE)?;
    let tun = tun_device_manager.make_tun()?;
    tunnel.set_tun(Box::new(tun));

    let update_device_task = update_device_task(tun_device_manager, receiver);

    let mut eventloop = Eventloop::new(tunnel, portal, sender);
    let eventloop_task = future::poll_fn(move |cx| eventloop.poll(cx));

    let ((), result) = futures::join!(update_device_task, eventloop_task);

    result.context("Eventloop failed")?;

    unreachable!()
}

async fn update_device_task(
    mut tun_device: TunDeviceManager,
    mut receiver: mpsc::Receiver<Interface>,
) {
    while let Some(next_interface) = receiver.next().await {
        if let Err(e) = tun_device
            .set_ips(next_interface.ipv4, next_interface.ipv6)
            .await
        {
            tracing::warn!(error = anyhow_dyn_err(&e), "Failed to set interface");
        }

        if let Err(e) = tun_device
            .set_routes(vec![IPV4_PEERS], vec![IPV6_PEERS])
            .await
        {
            tracing::warn!(error = anyhow_dyn_err(&e), "Failed; to set routes");
        };
    }
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[arg(
        short = 'u',
        long,
        hide = true,
        env = "FIREZONE_API_URL",
        default_value = "wss://api.firezone.dev"
    )]
    api_url: Url,
    /// Token generated by the portal to authorize websocket connection.
    #[arg(env = "FIREZONE_TOKEN")]
    token: String,
    /// Friendly name to display in the UI
    #[arg(short = 'n', long, env = "FIREZONE_NAME")]
    firezone_name: Option<String>,

    /// Disable sentry.io crash-reporting agent.
    #[arg(long, env = "FIREZONE_NO_TELEMETRY", default_value_t = false)]
    no_telemetry: bool,

    #[command(flatten)]
    health_check: http_health_check::HealthCheckArgs,

    /// Identifier generated by the portal to identify and display the device.
    #[arg(short = 'i', long, env = "FIREZONE_ID")]
    pub firezone_id: Option<String>,
}

impl Cli {
    fn is_telemetry_allowed(&self) -> bool {
        !self.no_telemetry
    }
}

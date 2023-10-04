use clap::Args;
use tracing_subscriber::{
    fmt, prelude::__tracing_subscriber_SubscriberExt, EnvFilter, Layer, Registry,
};
use url::Url;

pub fn block_on_ctrl_c() {
    let (tx, rx) = std::sync::mpsc::channel();
    ctrlc::set_handler(move || tx.send(()).expect("Could not send stop signal on channel."))
        .expect("Error setting Ctrl-C handler");
    rx.recv().expect("Could not receive ctrl-c signal");
}

pub fn setup_global_subscriber<L>(additional_layer: L)
where
    L: Layer<Registry> + Send + Sync,
{
    let subscriber = Registry::default()
        .with(additional_layer.with_filter(EnvFilter::from_default_env()))
        .with(fmt::layer().with_filter(EnvFilter::from_default_env()));
    tracing::subscriber::set_global_default(subscriber).expect("Could not set global default");
}

/// Arguments common to all headless FZ apps.
#[derive(Args, Clone)]
pub struct CommonArgs {
    /// Portal's websocket url
    #[arg(short, long, env = "FZ_URL")]
    pub url: Url,
    /// Service token
    #[arg(short, long, env = "FZ_SECRET")]
    pub secret: String,
}

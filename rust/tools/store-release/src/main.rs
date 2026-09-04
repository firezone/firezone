#![allow(clippy::print_stdout, clippy::print_stderr)]

mod android;
mod apple;
mod http;

use std::{path::PathBuf, str::FromStr};

use anyhow::{Result, anyhow};
use clap::{Args, Parser, Subcommand, ValueEnum};

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    command: Store,
}

#[derive(Subcommand)]
enum Store {
    Apple(Apple),
    Android(Android),
}

#[derive(Args)]
struct Apple {
    #[command(subcommand)]
    command: AppleCommand,
}

#[derive(Subcommand)]
enum AppleCommand {
    UploadBuild(AppleUploadBuild),
    PrepareVersion(ApplePrepareVersion),
}

#[derive(Args)]
struct Android {
    #[command(subcommand)]
    command: AndroidCommand,
}

#[derive(Subcommand)]
enum AndroidCommand {
    Prepare(AndroidPrepare),
}

#[derive(Args)]
struct AppleAuth {
    #[arg(long, env = "ISSUER_ID")]
    issuer_id: String,
    #[arg(long, env = "API_KEY_ID")]
    key_id: String,
    #[arg(long, env = "API_KEY")]
    private_key_base64: String,
}

#[derive(Args)]
struct AppleUploadBuild {
    #[command(flatten)]
    auth: AppleAuth,
    #[arg(long)]
    version: String,
    #[arg(long)]
    build_number: String,
    #[arg(long, value_enum)]
    platform: ApplePlatform,
    #[arg(long)]
    artifact: PathBuf,
}

#[derive(Args)]
struct ApplePrepareVersion {
    #[command(flatten)]
    auth: AppleAuth,
    #[arg(long)]
    version: String,
    #[arg(long)]
    build_number: String,
    #[arg(long, value_enum)]
    platform: ApplePlatform,
    #[arg(long, required = true)]
    screenshot: Vec<AppleScreenshot>,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum ApplePlatform {
    Ios,
    MacOs,
}

impl ApplePlatform {
    fn api_name(self) -> &'static str {
        match self {
            Self::Ios => "IOS",
            Self::MacOs => "MAC_OS",
        }
    }
}

#[derive(Clone, Debug)]
struct AppleScreenshot {
    display_type: String,
    path: PathBuf,
}

impl FromStr for AppleScreenshot {
    type Err = String;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        let (display_type, path) = value
            .split_once('=')
            .ok_or_else(|| "expected DISPLAY_TYPE=PATH".to_owned())?;
        if display_type.is_empty() || path.is_empty() {
            return Err("expected non-empty DISPLAY_TYPE=PATH".to_owned());
        }

        Ok(Self {
            display_type: display_type.to_owned(),
            path: path.into(),
        })
    }
}

#[derive(Args)]
struct AndroidPrepare {
    #[arg(long, env = "ACCESS_TOKEN")]
    access_token: String,
    #[arg(long)]
    bundle: PathBuf,
    #[arg(long)]
    version: String,
    #[arg(long, required = true)]
    screenshot: Vec<PathBuf>,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow!("Failed to install the rustls crypto provider"))?;

    let cli = Cli::parse();
    match cli.command {
        Store::Apple(Apple {
            command: AppleCommand::UploadBuild(args),
        }) => apple::upload_build(args).await?,
        Store::Apple(Apple {
            command: AppleCommand::PrepareVersion(args),
        }) => apple::prepare_version(args).await?,
        Store::Android(Android {
            command: AndroidCommand::Prepare(args),
        }) => android::prepare(args).await?,
    }

    Ok(())
}

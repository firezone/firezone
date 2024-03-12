use anyhow::{Context, Result};
use clap::Parser;
use connlib_client_shared::{file_logger, Callbacks, Session};
use connlib_shared::{
    keypair,
    linux::{etc_resolv_conf, get_dns_control_from_env, DnsControlMethod},
    LoginUrl,
};
use firezone_cli_utils::{block_on_ctrl_c, setup_global_subscriber, CommonArgs};
use secrecy::SecretString;
use std::{net::IpAddr, path::PathBuf, str::FromStr};

fn main() -> Result<()> {
    let cli = Cli::parse();
    let max_partition_time = cli.max_partition_time.map(|d| d.into());

    let (layer, handle) = cli.log_dir.as_deref().map(file_logger::layer).unzip();
    setup_global_subscriber(layer);

    let dns_control_method = get_dns_control_from_env();
    let callbacks = CallbackHandler {
        dns_control_method: dns_control_method.clone(),
        handle,
    };

    // AKA "Device ID", not the Firezone slug
    let firezone_id = match cli.firezone_id {
        Some(id) => id,
        None => connlib_shared::device_id::get().context("Could not get `firezone_id` from CLI, could not read it from disk, could not generate it and save it to disk")?,
    };

    let (private_key, public_key) = keypair();
    let login = LoginUrl::client(
        cli.common.api_url,
        &SecretString::from(cli.common.token),
        firezone_id,
        None,
        public_key.to_bytes(),
    )?;

    let session =
        Session::connect(login, private_key, None, callbacks, max_partition_time).unwrap();

    block_on_ctrl_c();

    if let Some(DnsControlMethod::EtcResolvConf) = dns_control_method {
        etc_resolv_conf::unconfigure_dns()?;
    }

    session.disconnect();
    Ok(())
}

#[derive(Clone)]
struct CallbackHandler {
    dns_control_method: Option<DnsControlMethod>,
    handle: Option<file_logger::Handle>,
}

#[derive(Debug, thiserror::Error)]
enum CbError {
    #[error(transparent)]
    Any(#[from] anyhow::Error),
}

impl Callbacks for CallbackHandler {
    // I spent several minutes messing with `anyhow` and couldn't figure out how to make
    // it implement `std::error::Error`: <https://github.com/dtolnay/anyhow/issues/25>
    type Error = CbError;

    /// May return Firezone's own servers, e.g. `100.100.111.1`.
    fn get_system_default_resolvers(&self) -> Result<Option<Vec<IpAddr>>, Self::Error> {
        let default_resolvers = match self.dns_control_method {
            None => get_system_default_resolvers_resolv_conf()?,
            Some(DnsControlMethod::EtcResolvConf) => get_system_default_resolvers_resolv_conf()?,
            Some(DnsControlMethod::NetworkManager) => {
                get_system_default_resolvers_network_manager()?
            }
            Some(DnsControlMethod::Systemd) => get_system_default_resolvers_systemd_resolved()?,
        };
        tracing::info!(?default_resolvers);
        Ok(Some(default_resolvers))
    }

    fn on_disconnect(&self, error: &connlib_client_shared::Error) -> Result<(), Self::Error> {
        tracing::error!(?error, "Disconnected");
        Ok(())
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.handle
            .as_ref()?
            .roll_to_new_file()
            .unwrap_or_else(|e| {
                tracing::debug!("Failed to roll over to new file: {e}");
                None
            })
    }
}

fn get_system_default_resolvers_resolv_conf() -> Result<Vec<IpAddr>> {
    // Assume that `configure_resolv_conf` has run in `tun_linux.rs`

    let s = std::fs::read_to_string(etc_resolv_conf::ETC_RESOLV_CONF_BACKUP)
        .or_else(|_| std::fs::read_to_string(etc_resolv_conf::ETC_RESOLV_CONF))
        .context("`resolv.conf` should be readable")?;
    let parsed = resolv_conf::Config::parse(s).context("`resolv.conf` should be parsable")?;

    // Drop the scoping info for IPv6 since connlib doesn't take it
    let nameservers = parsed
        .nameservers
        .into_iter()
        .map(|addr| addr.into())
        .collect();
    Ok(nameservers)
}

fn get_system_default_resolvers_network_manager() -> Result<Vec<IpAddr>> {
    tracing::error!("get_system_default_resolvers_network_manager not implemented yet");
    Ok(vec![])
}

/// Returns the DNS servers listed in `resolvectl dns`
fn get_system_default_resolvers_systemd_resolved() -> Result<Vec<IpAddr>> {
    // Unfortunately systemd-resolved does not have a machine-readable
    // text output for this command: <https://github.com/systemd/systemd/issues/29755>
    //
    // The officially supported way is probably to use D-Bus.
    let output = std::process::Command::new("resolvectl")
        .arg("dns")
        .output()
        .context("Failed to run `resolvectl dns` and read output")?;
    if !output.status.success() {
        anyhow::bail!("`resolvectl dns` returned non-zero exit code");
    }
    let output = String::from_utf8(output.stdout).context("`resolvectl` output was not UTF-8")?;
    Ok(parse_resolvectl_output(&output))
}

/// Parses the text output of `resolvectl dns`
///
/// Cannot fail. If the parsing code is wrong, the IP address vec will just be incomplete.
fn parse_resolvectl_output(s: &str) -> Vec<IpAddr> {
    s.lines()
        .flat_map(|line| line.split(' '))
        .filter_map(|word| IpAddr::from_str(word).ok())
        .collect()
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(flatten)]
    common: CommonArgs,

    /// Identifier used by the portal to identify and display the device.
    ///
    /// AKA `device_id` in the Windows and Linux GUI clients
    #[arg(short = 'i', long, env = "FIREZONE_ID")]
    pub firezone_id: Option<String>,

    /// File logging directory. Should be a path that's writeable by the current user.
    #[arg(short, long, env = "LOG_DIR")]
    log_dir: Option<PathBuf>,

    /// Maximum length of time to retry connecting to the portal if we're having internet issues or
    /// it's down. Accepts human times. e.g. "5m" or "1h" or "30d".
    #[arg(short, long, env = "MAX_PARTITION_TIME")]
    max_partition_time: Option<humantime::Duration>,
}

#[cfg(test)]
mod tests {
    use std::net::IpAddr;

    #[test]
    fn parse_resolvectl_output() {
        let cases = [
            // WSL
            (
                r"Global: 172.24.80.1
Link 2 (eth0):
Link 3 (docker0):
Link 24 (br-fc0b71997a3c):
Link 25 (br-0c129dafb204):
Link 26 (br-e67e83b19dce):
",
                [IpAddr::from([172, 24, 80, 1])],
            ),
            // Ubuntu 20.04
            (
                r"Global:
Link 2 (enp0s3): 192.168.1.1",
                [IpAddr::from([192, 168, 1, 1])],
            ),
        ];

        for (i, (input, expected)) in cases.iter().enumerate() {
            let actual = super::parse_resolvectl_output(input);
            assert_eq!(actual, expected, "Case {i} failed");
        }
    }
}

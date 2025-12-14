use anyhow::{Context, Result, bail};
use dns_types::DomainName;
use std::{
    fs,
    io::{self, Write},
    net::IpAddr,
    path::{Path, PathBuf},
};

pub(crate) const ETC_RESOLV_CONF: &str = "/etc/resolv.conf";
pub(crate) const ETC_RESOLV_CONF_BACKUP: &str = "/etc/resolv.conf.before-firezone";
/// Used to figure out whether we crashed on our last run or not.
///
/// If we did crash, we need to restore the system-wide DNS from the backup file.
/// If we did not crash, we need to make a new backup and then overwrite `resolv.conf`
const MAGIC_HEADER: &str = "# BEGIN Firezone DNS configuration";

// Wanted these args to have names so they don't get mixed up
#[derive(Clone)]
pub(crate) struct ResolvPaths {
    resolv: PathBuf,
    backup: PathBuf,
}

impl Default for ResolvPaths {
    fn default() -> Self {
        Self {
            resolv: PathBuf::from(ETC_RESOLV_CONF),
            backup: PathBuf::from(ETC_RESOLV_CONF_BACKUP),
        }
    }
}

/// Back up `/etc/resolv.conf`(sic) and then modify it in-place
///
/// This is async because it's called in a Tokio context and it's nice to use their
/// `fs` module
pub(crate) fn configure(dns_config: &[IpAddr], search_domain: Option<DomainName>) -> Result<()> {
    configure_at_paths(dns_config, search_domain, &ResolvPaths::default())
}

/// Revert changes Firezone made to `/etc/resolv.conf`
///
/// Must be sync because it's called in `Drop` impls
pub(crate) fn revert() -> Result<()> {
    revert_at_paths(&ResolvPaths::default())
}

fn configure_at_paths(
    dns_config: &[IpAddr],
    search_domain: Option<DomainName>,
    paths: &ResolvPaths,
) -> Result<()> {
    if dns_config.is_empty() {
        tracing::warn!("`dns_config` is empty, leaving `/etc/resolv.conf` unchanged");
        return Ok(());
    }

    // There is a TOCTOU here, if the user somehow enables `systemd-resolved` while Firezone is booting up.
    ensure_regular_file(&paths.resolv)?;

    let text = fs::read_to_string(&paths.resolv).context("Failed to read `resolv.conf`")?;
    let text = if text.starts_with(MAGIC_HEADER) {
        tracing::info!(
            "The last run of Firezone crashed before reverting `/etc/resolv.conf`. Reverting it now before re-writing it."
        );
        let resolv_path = &paths.resolv;
        let paths = paths.clone();
        revert_at_paths(&paths).context("Failed to revert `'resolv.conf`")?;
        fs::read_to_string(resolv_path)
            .context("Failed to re-read `resolv.conf` after reverting it")?
    } else {
        // The last run of Firezone reverted resolv.conf successfully,
        // or the user manually reverted it between runs.
        // Do the backup as normal
        text
    };

    let parsed = resolv_conf::Config::parse(&text).context("Failed to parse `resolv.conf`")?;

    // Back up the original resolv.conf. Overwrite any existing backup:
    // - If we crashed, and MAGIC_HEADER is still present, we already called `revert` above.
    // - If we crashed, but the user rewrote the file, our backup is out of date
    // - If we didn't crash, we should have reverted, so the backup is not needed.
    //
    // `atomicwrites` handles the fsync and rename-into-place tricks to resist file corruption
    // if we lose power during the write.
    let backup_file = atomicwrites::AtomicFile::new(
        &paths.backup,
        atomicwrites::OverwriteBehavior::AllowOverwrite,
    );
    backup_file
        .write(|f| f.write_all(text.as_bytes()))
        .context("Failed to back up `resolv.conf`")?;

    let mut new_resolv_conf = parsed;

    new_resolv_conf.nameservers = dns_config.iter().map(|addr| (*addr).into()).collect();
    new_resolv_conf.set_search(search_domain.into_iter().map(|d| d.to_string()).collect());
    new_resolv_conf.ndots = 1; // Must be 1 (e.g. the default) for search-domains to work

    // Over-writing `/etc/resolv.conf` actually violates Docker's plan for handling DNS
    // https://docs.docker.com/network/#dns-services
    // But this is just a hack to get a smoke test working in CI for now.
    //
    // Because Docker bind-mounts resolv.conf into the container, (visible in `mount`) we can't
    // use the rename trick to safely update it, nor can we delete it. The best
    // we can do is rewrite it in-place.
    //
    // TODO: Allow atomic writes for non-container systems, e.g. minimal Debian without NetworkManager or systemd-resolved.
    let new_text = format!(
        r"{MAGIC_HEADER}
# If you modify this file, delete the above magic header line so that Firezone will
# obey your new default DNS config.
# If you see this text and Firezone is not running, then the last run of Firezone crashed.
# The original `resolv.conf` is backed up at {}
{}
",
        paths.backup.display(),
        new_resolv_conf,
    );

    fs::write(&paths.resolv, new_text).context("Failed to rewrite `resolv.conf`")?;

    Ok(())
}

// Must be sync so we can call it from `Drop` impls
fn revert_at_paths(paths: &ResolvPaths) -> Result<()> {
    ensure_regular_file(&paths.resolv)?;
    match fs::copy(&paths.backup, &paths.resolv) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            tracing::debug!("Didn't revert `/etc/resolv.conf`, no backup file found");
            return Ok(());
        }
        Err(e) => Err(e).context("Failed to restore `/etc/resolv.conf` backup")?,
        Ok(_) => {}
    }
    // Don't delete the backup file - If we lose power here, and the revert is rolled back,
    // we may want it. Filesystems are not atomic by default, and have weak ordering,
    // so we don't want to end up in a state where the backup is deleted and the revert was rolled back.
    tracing::info!("Reverted `/etc/resolv.conf`l");
    Ok(())
}

fn ensure_regular_file(path: &Path) -> Result<()> {
    let file_type = fs::symlink_metadata(path)?.file_type();
    if !file_type.is_file() {
        bail!("File `{path:?}` is not a regular file, cannot use it to control DNS");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{ResolvPaths, configure_at_paths, revert_at_paths};
    use anyhow::{Context, Result, ensure};
    use std::{
        net::{IpAddr, Ipv4Addr, Ipv6Addr},
        path::Path,
    };

    const CLOUDFLARE_DNS: Ipv4Addr = Ipv4Addr::new(1, 1, 1, 1);
    const GOOGLE_DNS: Ipv4Addr = Ipv4Addr::new(8, 8, 8, 8);

    const DEBIAN_VM_RESOLV_CONF: &str = r#"
# This is /run/systemd/resolve/stub-resolv.conf managed by man:systemd-resolved(8).
# Do not edit.
#
# This file might be symlinked as /etc/resolv.conf. If you're looking at
# /etc/resolv.conf and seeing this text, you have followed the symlink.
#
# This is a dynamic resolv.conf file for connecting local clients to the
# internal DNS stub resolver of systemd-resolved. This file lists all
# configured search domains.
#
# Run "resolvectl status" to see details about the uplink DNS servers
# currently in use.
#
# Third party programs should typically not access this file directly, but only
# through the symlink at /etc/resolv.conf. To manage man:resolv.conf(5) in a
# different way, replace this symlink by a static file or a different symlink.
#
# See man:systemd-resolved.service(8) for details about the supported modes of
# operation for /etc/resolv.conf.
nameserver 127.0.0.53
options edns0 trust-ad
search .
"#;

    // Docker seems to have injected the WSL host's resolv.conf into the Alpine container
    // Also the nameserver is changed for privacy
    const ALPINE_CONTAINER_RESOLV_CONF: &str = r#"
# This file was automatically generated by WSL. To stop automatic generation of this file, add the following entry to /etc/wsl.conf:
# [network]
# generateResolvConf = false
nameserver 9.9.9.9
"#;

    // From a Debian desktop
    const NETWORK_MANAGER_RESOLV_CONF: &str = r"
# Generated by NetworkManager
nameserver 192.168.1.1
nameserver 2001:db8::%eno1
";

    #[test]
    fn parse_resolv_conf() {
        let parsed = resolv_conf::Config::parse(DEBIAN_VM_RESOLV_CONF).unwrap();
        let mut config = resolv_conf::Config::new();
        config
            .nameservers
            .push(resolv_conf::ScopedIp::V4(Ipv4Addr::new(127, 0, 0, 53)));
        config.set_search(vec![".".into()]);
        config.edns0 = true;
        config.trust_ad = true;
        assert_eq!(parsed, config);

        let parsed = resolv_conf::Config::parse(ALPINE_CONTAINER_RESOLV_CONF).unwrap();
        let mut config = resolv_conf::Config::new();
        config
            .nameservers
            .push(resolv_conf::ScopedIp::V4(Ipv4Addr::new(9, 9, 9, 9)));
        assert_eq!(parsed, config);

        let parsed = resolv_conf::Config::parse(NETWORK_MANAGER_RESOLV_CONF).unwrap();
        let mut config = resolv_conf::Config::new();
        config
            .nameservers
            .push(resolv_conf::ScopedIp::V4(Ipv4Addr::new(192, 168, 1, 1)));
        config.nameservers.push(resolv_conf::ScopedIp::V6(
            Ipv6Addr::new(
                0x2001, 0x0db8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
            ),
            Some("eno1".into()),
        ));
        assert_eq!(parsed, config);

        assert!(resolv_conf::Config::parse("").is_ok());
        assert!(resolv_conf::Config::parse("An invalid resolv.conf file.").is_err());
    }

    #[test]
    fn print_resolv_conf() {
        let mut new_resolv_conf = resolv_conf::Config::new();
        for addr in [
            IpAddr::from([100, 100, 111, 1]),
            IpAddr::from([100, 100, 111, 2]),
        ] {
            new_resolv_conf.nameservers.push(addr.into());
        }

        let actual = new_resolv_conf.to_string();
        assert_eq!(
            actual,
            r"nameserver 100.100.111.1
nameserver 100.100.111.2
"
        );
    }

    /// Returns `Ok(())` if the file at the given path contains the expected sentinels
    ///
    /// Return `Err(_)` if the file can't be parsed, the sentinels don't match, or
    /// any DNS options are set in the file.
    fn check_resolv_conf(path: &Path, expected_sentinels: &[IpAddr]) -> Result<()> {
        let text = std::fs::read_to_string(path).context("could not read file")?;
        let parsed = resolv_conf::Config::parse(text)?;

        let mut expected = resolv_conf::Config::new();
        expected_sentinels
            .iter()
            .for_each(|addr| expected.nameservers.push((*addr).into()));

        ensure!(
            parsed == expected,
            "Parsed resolv config {:?} didn't match expected resolv config {:?}",
            parsed,
            expected,
        );
        Ok(())
    }

    // Not shared with prod code because prod also writes the "Generated by" comment,
    fn write_resolv_conf(path: &Path, nameservers: &[IpAddr]) -> Result<()> {
        let mut conf = resolv_conf::Config::new();
        conf.nameservers = nameservers.iter().map(|addr| (*addr).into()).collect();
        std::fs::write(path, conf.to_string())?;
        Ok(())
    }

    fn create_temp_paths() -> (tempfile::TempDir, super::ResolvPaths) {
        // Using `TempDir` instead of `tempfile` because I need the path, and instead
        // of `NamedTempFile` because those get deleted immediately on Linux, which confuses
        // `configure_dns_at_paths when it tries to read from the path.
        let temp_dir = tempfile::TempDir::with_prefix("firezone-dns-test-")
            .expect("Should always be able to create a temp dir");
        let paths = ResolvPaths {
            resolv: temp_dir.path().join("resolv.conf"),
            backup: temp_dir.path().join("resolv.conf.before-firezone"),
        };
        (temp_dir, paths)
    }

    /// The original resolv.conf should be backed up, and the new one should only
    /// contain our sentinels.
    #[tokio::test]
    async fn happy_path() -> Result<()> {
        // Try not to panic, it may leave temp files behind
        let (_temp_dir, paths) = create_temp_paths();

        write_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;

        configure_at_paths(&[IpAddr::from([100, 100, 111, 1])], None, &paths)?;

        check_resolv_conf(&paths.resolv, &[IpAddr::from([100, 100, 111, 1])])?;
        check_resolv_conf(&paths.backup, &[GOOGLE_DNS.into()])?;

        revert_at_paths(&paths)?;

        check_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;
        // The backup file is intentionally left in place because we don't
        // do any fsyncs to ensure that the revert is committed.
        ensure!(tokio::fs::try_exists(&paths.backup).await?);

        Ok(())
    }

    /// If there are no sentinels for some reason, don't change resolv.conf
    #[tokio::test]
    async fn no_sentinels() -> Result<()> {
        let (_temp_dir, paths) = create_temp_paths();

        write_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;

        configure_at_paths(&[], None, &paths)?;

        check_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;
        // No backup since we didn't touch the original file
        ensure!(!tokio::fs::try_exists(&paths.backup).await?);

        Ok(())
    }

    /// If we run twice, make sure the reverting and everything works
    #[tokio::test]
    async fn run_twice() -> Result<()> {
        let (_temp_dir, paths) = create_temp_paths();

        write_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;
        configure_at_paths(&[IpAddr::from([100, 100, 111, 1])], None, &paths)?;
        revert_at_paths(&paths)?;

        write_resolv_conf(&paths.resolv, &[CLOUDFLARE_DNS.into()])?;
        configure_at_paths(&[IpAddr::from([100, 100, 111, 2])], None, &paths)?;
        check_resolv_conf(&paths.resolv, &[IpAddr::from([100, 100, 111, 2])])?;
        check_resolv_conf(&paths.backup, &[CLOUDFLARE_DNS.into()])?;
        revert_at_paths(&paths)?;

        check_resolv_conf(&paths.resolv, &[CLOUDFLARE_DNS.into()])?;
        // Backup is preserved even after reverting in case the FS re-orders
        // transactions on power loss.
        ensure!(tokio::fs::try_exists(&paths.backup).await?);

        Ok(())
    }

    /// If we crash and fail to revert, the next run should not modify the backup,
    /// just continue as if it was already configured, then revert when it exits
    #[tokio::test]
    async fn crash() -> Result<()> {
        let (_temp_dir, paths) = create_temp_paths();

        // User wants Google as their default
        write_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;

        // First run
        configure_at_paths(&[IpAddr::from([100, 100, 111, 1])], None, &paths)?;
        check_resolv_conf(&paths.resolv, &[IpAddr::from([100, 100, 111, 1])])
            .context("First run, resolv.conf should have sentinel")?;
        check_resolv_conf(&paths.backup, &[GOOGLE_DNS.into()])
            .context("First run, backup should have GOOGLE_DNS")?;

        // Crash happens

        // Second run
        configure_at_paths(&[IpAddr::from([100, 100, 111, 2])], None, &paths)?;
        check_resolv_conf(&paths.resolv, &[IpAddr::from([100, 100, 111, 2])])
            .context("Second run, resolv.conf should have new sentinel")?;
        check_resolv_conf(&paths.backup, &[GOOGLE_DNS.into()])
            .context("Second run, backup should have GOOGLE_DNS")?;
        revert_at_paths(&paths)?;

        // Second run ended
        check_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])
            .context("After second run, resolv.conf should be reverted")?;
        ensure!(tokio::fs::try_exists(&paths.backup).await?);

        Ok(())
    }

    /// If we crash, then user manually changes their DNS, we should respect their change
    #[tokio::test]
    async fn crash_manual_revert() -> Result<()> {
        let (_temp_dir, paths) = create_temp_paths();

        // User wants Google as their default
        write_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;

        // First run
        configure_at_paths(&[IpAddr::from([100, 100, 111, 1])], None, &paths)?;
        check_resolv_conf(&paths.resolv, &[IpAddr::from([100, 100, 111, 1])])
            .context("First run, resolv.conf should have sentinel")?;
        check_resolv_conf(&paths.backup, &[GOOGLE_DNS.into()])
            .context("First run, backup should have GOOGLE_DNS")?;

        // Crash happens
        // User switches to Cloudflare
        write_resolv_conf(&paths.resolv, &[CLOUDFLARE_DNS.into()])?;

        // Second run
        configure_at_paths(&[IpAddr::from([100, 100, 111, 2])], None, &paths)?;
        check_resolv_conf(&paths.resolv, &[IpAddr::from([100, 100, 111, 2])])
            .context("Second run, resolv.conf should have new sentinel")?;
        check_resolv_conf(&paths.backup, &[CLOUDFLARE_DNS.into()])
            .context("Second run, backup should have CLOUDFLARE_DNS")?;
        revert_at_paths(&paths)?;

        // Second run ended
        check_resolv_conf(&paths.resolv, &[CLOUDFLARE_DNS.into()])
            .context("After second run, resolv.conf should be reverted")?;
        ensure!(tokio::fs::try_exists(&paths.backup).await?);

        Ok(())
    }

    /// Configuring and reverting should both be idempotent, just in case
    /// the GUI Client accidentally reverts twice or something.
    #[tokio::test]
    async fn idempotence() -> Result<()> {
        let (_temp_dir, paths) = create_temp_paths();

        // User wants the default to be Google.
        write_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;

        // Configure twice
        configure_at_paths(&[IpAddr::from([100, 100, 111, 1])], None, &paths)?;
        check_resolv_conf(&paths.resolv, &[IpAddr::from([100, 100, 111, 1])])?;
        check_resolv_conf(&paths.backup, &[GOOGLE_DNS.into()])?;

        configure_at_paths(&[IpAddr::from([100, 100, 111, 1])], None, &paths)?;
        check_resolv_conf(&paths.resolv, &[IpAddr::from([100, 100, 111, 1])])?;
        check_resolv_conf(&paths.backup, &[GOOGLE_DNS.into()])?;

        // Revert twice
        revert_at_paths(&paths)?;
        check_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;
        ensure!(tokio::fs::try_exists(&paths.backup).await?);

        revert_at_paths(&paths)?;
        check_resolv_conf(&paths.resolv, &[GOOGLE_DNS.into()])?;
        ensure!(tokio::fs::try_exists(&paths.backup).await?);

        Ok(())
    }
}

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{borrow::Cow, net::IpAddr};

use anyhow::Result;

#[cfg(unix)]
pub fn resolve<H>(host: H) -> impl Future<Output = Result<Vec<IpAddr>>> + use<H>
where
    H: Into<Cow<'static, str>>,
{
    use anyhow::Context as _;

    let host = host.into();

    async move {
        let content = tokio::fs::read_to_string("/etc/hosts")
            .await
            .context("Failed to read `/etc/hosts`")?;

        let ips = parse(&content, &host);

        tracing::debug!(?ips, %host, "Resolved host");

        Ok(ips)
    }
}

#[cfg(any(unix, test))]
fn parse(content: &str, host: &str) -> Vec<IpAddr> {
    content
        .lines()
        .filter_map(|line| {
            tracing::trace!(%line, "Parsing entry");

            let mut tokens = line.split_ascii_whitespace();
            let ip = tokens.next()?;
            let ip = ip
                .parse::<IpAddr>()
                .inspect_err(|e| tracing::debug!(%ip, "Failed to parse IP address: {e}"))
                .ok()?;

            for candidate in tokens {
                if candidate == host {
                    return Some(ip);
                }
            }

            None
        })
        .collect()
}

#[cfg(not(unix))]
pub fn resolve<H>(_: H) -> impl Future<Output = Result<Vec<IpAddr>>> + use<H>
where
    H: Into<Cow<'static, str>>,
{
    async { Ok(Vec::default()) }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv6Addr;

    use super::*;

    #[cfg(unix)]
    #[tokio::test]
    async fn can_resolve_localhost() {
        use std::net::Ipv4Addr;

        let ips = resolve("localhost").await.unwrap();

        assert!(ips.contains(&IpAddr::V4(Ipv4Addr::LOCALHOST)));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn returns_no_ips_for_unknown_host() {
        let ips = resolve("example.com").await.unwrap();

        assert_eq!(ips, Vec::<IpAddr>::default());
    }

    #[cfg(not(unix))]
    #[tokio::test]
    async fn does_not_fail_on_non_unix() {
        let ips = resolve("localhost").await.unwrap();

        assert_eq!(ips, Vec::<IpAddr>::default());
    }

    #[test]
    fn can_parse_docker_etc_hosts() {
        let content = r#"127.0.0.1       localhost
        ::1     localhost ip6-localhost ip6-loopback
        fe00::  ip6-localnet
        ff00::  ip6-mcastprefix
        ff02::1 ip6-allnodes
        ff02::2 ip6-allrouters
        203.0.113.10    portal
        203:0:113::10   portal
        172.30.0.100    20b5b769ce8f
        172:30::100     20b5b769ce8f"#;

        let ips = parse(content, "portal");

        assert_eq!(
            ips,
            vec![
                IpAddr::from([203, 0, 113, 10]),
                IpAddr::from([
                    0x0203, 0x0000, 0x0113, 0x0000, 0x0000, 0x0000, 0x0000, 0x0010
                ]),
            ]
        );
    }

    #[test]
    fn can_parse_additional_hostnames() {
        let content = r#"127.0.0.1       localhost
        ::1     localhost ip6-localhost ip6-loopback
        "#;

        let ips = parse(content, "ip6-loopback");

        assert_eq!(ips, vec![IpAddr::from(Ipv6Addr::LOCALHOST),]);
    }

    #[test]
    fn ignores_lines_with_missing_host() {
        let content = r#"
            127.0.0.1       localhost
            fe00::
            203.0.113.10    portal
        "#;

        let ips = parse(content, "portal");

        assert_eq!(ips, vec![IpAddr::from([203, 0, 113, 10])]);
    }
}

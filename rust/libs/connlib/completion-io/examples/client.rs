//! Native client using the shared portal, route/DNS managers, and completion packet transport.

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn main() -> anyhow::Result<()> {
    use completion_io::{host::Config, native};
    let config = serde_json::from_reader::<_, Config>(std::io::stdin())?;
    let core = std::env::var("FIREZONE_COMPLETION_CORE")
        .ok()
        .map(|core| core.parse())
        .transpose()?;
    native::run(connect(config), core)??;
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
async fn connect(mut config: completion_io::host::Config) -> anyhow::Result<()> {
    use anyhow::Context as _;
    use bin_shared::{
        DnsControlMethod, DnsController, TunDeviceManager,
        platform::{UdpSocketFactory, tcp_socket_factory},
    };
    use clap::ValueEnum as _;
    use completion_io::native;
    use futures::StreamExt as _;
    use std::sync::Arc;

    let method = std::env::var("FIREZONE_DNS_CONTROL").unwrap_or_else(|_| {
        #[cfg(target_os = "linux")]
        {
            "systemd-resolved".into()
        }
        #[cfg(target_os = "windows")]
        {
            "nrpt".into()
        }
    });
    let method = DnsControlMethod::from_str(&method, false).map_err(anyhow::Error::msg)?;
    let mut dns = DnsController {
        dns_control_method: method,
    };
    dns.deactivate()?;
    if config.dns_servers.is_empty() {
        config.dns_servers = dns.system_resolvers();
    }
    let (session, mut events, port) = config.connect(
        Arc::new(tcp_socket_factory),
        Arc::new(UdpSocketFactory::default()),
    )?;
    let mut manager = TunDeviceManager::new(ip_packet::MAX_IP_SIZE)?;
    #[cfg(target_os = "linux")]
    let device = native::OffloadedTun::from_fd(manager.make_tun_fd()?)?;
    #[cfg(target_os = "windows")]
    let rings = manager.make_completion_tun()?;
    #[cfg(target_os = "windows")]
    let device = native::Wintun(rings.session.clone());

    let mut terminate = bin_shared::signals::Terminate::new()?;
    let mut hangup = bin_shared::signals::Hangup::new()?;
    let mut networks = bin_shared::new_network_notifier().await?;
    let mut resolvers =
        bin_shared::new_dns_notifier(tokio::runtime::Handle::current(), method).await?;
    let packet_port = port.clone();
    let packets = native::drive_with_factory(packet_port, device, || {
        let v4 = bind("0.0.0.0:52625".parse()?)?;
        let v6 = bind("[::]:52625".parse()?).ok();
        Ok((v4, v6))
    });
    let control = async {
        let mut stopping = false;
        loop {
            let event = tokio::select! {
                () = terminate.recv(), if !stopping => { session.stop(); stopping = true; continue; }
                () = hangup.recv(), if !stopping => { session.reset("SIGHUP".into()); continue; }
                result = networks.next(), if !stopping => { result.context("Network notifier closed")??; session.reset("network changed".into()); continue; }
                result = resolvers.next(), if !stopping => { result.context("DNS notifier closed")??; session.set_dns(dns.system_resolvers()); continue; }
                event = events.next() => event,
            };
            let Some(event) = event else {
                break;
            };
            match event {
                client_shared::Event::TunInterfaceUpdated(config) => {
                    let stack = manager.set_ips(config.ip.v4, config.ip.v6).await?;
                    dns.set_dns(config.dns_by_sentinel.sentinel_ips(), config.search_domain)
                        .await?;
                    manager
                        .set_routes(config.routes.into_iter().filter(|route| {
                            if route.is_ipv4() {
                                stack.supports_ipv4()
                            } else {
                                stack.supports_ipv6()
                            }
                        }))
                        .await?;
                }
                client_shared::Event::ResourcesUpdated(_) => dns.flush()?,
                client_shared::Event::ConnectedToPortal(_) => {}
                client_shared::Event::AllGatewaysOffline { .. } => {}
                client_shared::Event::GatewayVersionMismatch { .. } => {}
                client_shared::Event::Disconnected(error) => {
                    anyhow::bail!("{}", error.log_message())
                }
            }
        }
        port.close();
        anyhow::Ok(())
    };
    futures::try_join!(packets, control)?;
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn bind(address: std::net::SocketAddr) -> anyhow::Result<std::net::UdpSocket> {
    let socket = completion_io::native::bind_udp(address)?;
    #[cfg(target_os = "linux")]
    socket2::SockRef::from(&socket).set_mark(bin_shared::FIREZONE_MARK)?;
    Ok(socket)
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
fn main() {}

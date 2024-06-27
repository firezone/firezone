use crate::MTU;
use connlib_shared::{
    windows::{CREATE_NO_WINDOW, TUNNEL_NAME},
    Callbacks, Result,
};
use ip_network::IpNetwork;
use std::{
    collections::HashSet,
    io,
    net::{SocketAddrV4, SocketAddrV6},
    os::windows::process::CommandExt,
    process::{Command, Stdio},
    str::FromStr,
    sync::Arc,
    task::{ready, Context, Poll},
};
use tokio::sync::mpsc;
use windows::Win32::{
    NetworkManagement::{
        IpHelper::{
            CreateIpForwardEntry2, DeleteIpForwardEntry2, GetIpInterfaceEntry,
            InitializeIpForwardEntry, SetIpInterfaceEntry, MIB_IPFORWARD_ROW2, MIB_IPINTERFACE_ROW,
        },
        Ndis::NET_LUID_LH,
    },
    Networking::WinSock::{AF_INET, AF_INET6},
};
use wintun::Adapter;

// Not sure how this and `TUNNEL_NAME` differ
const ADAPTER_NAME: &str = "Firezone";

pub(crate) struct Tun {
    /// The index of our network adapter, we can use this when asking Windows to add / remove routes / DNS rules
    /// It's stable across app restarts and I'm assuming across system reboots too.
    iface_idx: u32,
    packet_rx: mpsc::Receiver<wintun::Packet>,
    recv_thread: Option<std::thread::JoinHandle<()>>,
    session: Arc<wintun::Session>,
    routes: HashSet<IpNetwork>,
}

impl Drop for Tun {
    fn drop(&mut self) {
        tracing::debug!(
            channel_capacity = self.packet_rx.capacity(),
            "Shutting down packet channel..."
        );
        self.packet_rx.close(); // This avoids a deadlock when we join the worker thread, see PR 5571
        if let Err(error) = self.session.shutdown() {
            tracing::error!(?error, "wintun::Session::shutdown");
        }
        if let Err(error) = self
            .recv_thread
            .take()
            .expect("`recv_thread` should always be `Some` until `Tun` drops")
            .join()
        {
            tracing::error!(?error, "`Tun::recv_thread` panicked");
        }
    }
}

impl Tun {
    #[tracing::instrument(level = "debug")]
    pub fn new() -> Result<Self> {
        const TUNNEL_UUID: &str = "e9245bc1-b8c1-44ca-ab1d-c6aad4f13b9c";

        // SAFETY: we're loading a DLL from disk and it has arbitrary C code in it.
        // The Windows client, in `wintun_install` hashes the DLL at startup, before calling connlib, so it's unlikely for the DLL to be accidentally corrupted by the time we get here.
        let path = connlib_shared::windows::wintun_dll_path()?;
        let wintun = unsafe { wintun::load_from_path(path) }?;

        // Create wintun adapter
        let uuid = uuid::Uuid::from_str(TUNNEL_UUID)
            .expect("static UUID should always parse correctly")
            .as_u128();
        let adapter = &Adapter::create(&wintun, ADAPTER_NAME, TUNNEL_NAME, Some(uuid))?;
        let iface_idx = adapter.get_adapter_index()?;

        // Remove any routes that were previously associated with us
        // TODO: Pick a more elegant way to do this
        Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("-Command")
            .arg(format!(
                "Remove-NetRoute -InterfaceIndex {iface_idx} -Confirm:$false"
            ))
            .stdout(Stdio::null())
            .status()?;

        set_iface_config(adapter.get_luid(), MTU as u32)?;

        let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);
        // 4 is a nice power of two. Wintun already queues packets for us, so we don't
        // need much capacity here.
        let (packet_tx, packet_rx) = mpsc::channel(4);
        let recv_thread = start_recv_thread(packet_tx, Arc::clone(&session))?;

        Ok(Self {
            iface_idx,
            recv_thread: Some(recv_thread),
            packet_rx,
            session: Arc::clone(&session),
            routes: HashSet::new(),
        })
    }

    // It's okay if this blocks until the route is added in the OS.
    pub fn set_routes(
        &mut self,
        new_routes: HashSet<IpNetwork>,
        _callbacks: &impl Callbacks,
    ) -> Result<()> {
        if new_routes == self.routes {
            return Ok(());
        }

        for new_route in new_routes.difference(&self.routes) {
            self.add_route(*new_route)?;
        }

        for old_route in self.routes.difference(&new_routes) {
            self.remove_route(*old_route)?;
        }

        // TODO: Might be calling this more often than it needs
        flush_dns().expect("Should be able to flush Windows' DNS cache");
        self.routes = new_routes;
        Ok(())
    }

    // Moves packets from the user towards the Internet
    pub fn poll_read(&mut self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        let pkt = ready!(self.packet_rx.poll_recv(cx));

        match pkt {
            Some(pkt) => {
                let bytes = pkt.bytes();
                let len = bytes.len();
                if len > buf.len() {
                    // This shouldn't happen now that we set IPv4 and IPv6 MTU
                    // If it does, something is wrong.
                    tracing::warn!("Packet is too long to read ({len} bytes)");
                    return Poll::Ready(Ok(0));
                }
                buf[0..len].copy_from_slice(bytes);
                Poll::Ready(Ok(len))
            }
            None => {
                tracing::error!("error receiving packet from mpsc channel");
                Poll::Ready(Err(std::io::ErrorKind::Other.into()))
            }
        }
    }

    pub fn name(&self) -> &str {
        TUNNEL_NAME
    }

    pub fn write4(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }

    pub fn write6(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }

    // Moves packets from the Internet towards the user
    #[allow(clippy::unnecessary_wraps)] // Fn signature must align with other platform implementations.
    fn write(&self, bytes: &[u8]) -> io::Result<usize> {
        let len = bytes
            .len()
            .try_into()
            .expect("Packet length should fit into u16");

        let Ok(mut pkt) = self.session.allocate_send_packet(len) else {
            // Ring buffer is full, just drop the packet since we're at the IP layer
            return Ok(0);
        };

        pkt.bytes_mut().copy_from_slice(bytes);
        // `send_packet` cannot fail to enqueue the packet, since we already allocated
        // space in the ring buffer.
        self.session.send_packet(pkt);
        Ok(bytes.len())
    }

    // It's okay if this blocks until the route is added in the OS.
    fn add_route(&self, route: IpNetwork) -> Result<()> {
        const DUPLICATE_ERR: u32 = 0x80071392;
        let entry = self.forward_entry(route);

        // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.
        match unsafe { CreateIpForwardEntry2(&entry) }.ok() {
            Ok(()) => Ok(()),
            Err(e) if e.code().0 as u32 == DUPLICATE_ERR => {
                tracing::debug!(%route, "Failed to add duplicate route, ignoring");
                Ok(())
            }
            Err(e) => Err(e.into()),
        }
    }

    // It's okay if this blocks until the route is removed in the OS.
    fn remove_route(&self, route: IpNetwork) -> Result<()> {
        let entry = self.forward_entry(route);

        // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.
        unsafe { DeleteIpForwardEntry2(&entry) }.ok()?;
        Ok(())
    }

    fn forward_entry(&self, route: IpNetwork) -> MIB_IPFORWARD_ROW2 {
        let mut row = MIB_IPFORWARD_ROW2::default();
        // SAFETY: Windows shouldn't store the reference anywhere, it's just setting defaults
        unsafe { InitializeIpForwardEntry(&mut row) };

        let prefix = &mut row.DestinationPrefix;
        match route {
            IpNetwork::V4(x) => {
                prefix.PrefixLength = x.netmask();
                prefix.Prefix.Ipv4 = SocketAddrV4::new(x.network_address(), 0).into();
            }
            IpNetwork::V6(x) => {
                prefix.PrefixLength = x.netmask();
                prefix.Prefix.Ipv6 = SocketAddrV6::new(x.network_address(), 0, 0, 0).into();
            }
        }

        row.InterfaceIndex = self.iface_idx;
        row.Metric = 0;

        row
    }
}

/// Flush Windows' system-wide DNS cache
pub(crate) fn flush_dns() -> Result<()> {
    tracing::info!("Flushing Windows DNS cache");
    Command::new("powershell")
        .creation_flags(CREATE_NO_WINDOW)
        .args(["-Command", "Clear-DnsClientCache"])
        .status()?;
    Ok(())
}

// Moves packets from the user towards the Internet
fn start_recv_thread(
    packet_tx: mpsc::Sender<wintun::Packet>,
    session: Arc<wintun::Session>,
) -> io::Result<std::thread::JoinHandle<()>> {
    std::thread::Builder::new()
        .name("Firezone wintun worker".into())
        .spawn(move || {
            loop {
                match session.receive_blocking() {
                    Ok(pkt) => {
                        // Use `blocking_send` so that if connlib is behind by a few packets,
                        // Wintun will queue up new packets in its ring buffer while we
                        // wait for our MPSC channel to clear.
                        match packet_tx.blocking_send(pkt) {
                            Ok(()) => {}
                            Err(_) => {
                                tracing::info!(
                                    "Stopping outbound worker thread because the packet channel closed"
                                );
                                break;
                            }
                        }
                    }
                    Err(wintun::Error::ShuttingDown) => {
                        tracing::info!("Stopping outbound worker thread because Wintun is shutting down");
                        break;
                    }
                    Err(e) => {
                        tracing::error!("wintun::Session::receive_blocking: {e:#?}");
                        break;
                    }
                }
            }
        })
}

/// Sets MTU on the interface
/// TODO: Set IP and other things in here too, so the code is more organized
fn set_iface_config(luid: wintun::NET_LUID_LH, mtu: u32) -> Result<()> {
    // SAFETY: Both NET_LUID_LH unions should be the same. We're just copying out
    // the u64 value and re-wrapping it, since wintun doesn't refer to the windows
    // crate's version of NET_LUID_LH.
    let luid = NET_LUID_LH {
        Value: unsafe { luid.Value },
    };

    // Set MTU for IPv4
    {
        let mut row = MIB_IPINTERFACE_ROW {
            Family: AF_INET,
            InterfaceLuid: luid,
            ..Default::default()
        };

        // SAFETY: TODO
        unsafe { GetIpInterfaceEntry(&mut row) }.ok()?;

        // https://stackoverflow.com/questions/54857292/setipinterfaceentry-returns-error-invalid-parameter
        row.SitePrefixLength = 0;

        // Set MTU for IPv4
        row.NlMtu = mtu;

        // SAFETY: TODO
        unsafe { SetIpInterfaceEntry(&mut row) }.ok()?;
    }

    // Set MTU for IPv6
    {
        let mut row = MIB_IPINTERFACE_ROW {
            Family: AF_INET6,
            InterfaceLuid: luid,
            ..Default::default()
        };

        // SAFETY: TODO
        unsafe { GetIpInterfaceEntry(&mut row) }.ok()?;

        // https://stackoverflow.com/questions/54857292/setipinterfaceentry-returns-error-invalid-parameter
        row.SitePrefixLength = 0;

        // Set MTU for IPv4
        row.NlMtu = mtu;

        // SAFETY: TODO
        unsafe { SetIpInterfaceEntry(&mut row) }.ok()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::Tun;
    use anyhow::Result;
    use ip_packet::{
        udp::MutableUdpPacket, IpPacket, MutableIpPacket, MutablePacket as _, Packet as _,
        PacketSize as _,
    };
    use std::{
        future::poll_fn,
        net::{Ipv4Addr, Ipv6Addr},
        time::Duration,
    };
    use tokio::{
        net::UdpSocket,
        time::{timeout, Instant},
    };
    use tracing_subscriber::EnvFilter;

    /// Runs multiple Wintun tests.
    ///
    /// We don't have test names and UUIDs for the interfaces, and some are performance
    /// tests, so we don't want to run these in parallel in multiple tests.
    #[test]
    #[ignore = "Needs admin privileges"]
    fn wintun() {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(EnvFilter::from_default_env())
            .with_test_writer()
            .try_init();
        perf().unwrap();
        tunnel_drop();
    }

    /// Synthetic performance test
    ///
    /// Echoes UDP packets between a local socket and the Wintun interface
    fn perf() -> Result<()> {
        let rt = tokio::runtime::Runtime::new()?;
        rt.block_on(async {
            let mut tun = Tun::new()?;

            const MTU: usize = 1_280;
            const NUM_REQUESTS: u64 = 1_000;
            const REQ_CODE: u8 = 42;
            const REQ_LEN: usize = 1_000;
            const RESP_CODE: u8 = 43;
            const UDP_HEADER_SIZE: usize = 8;
            const SERVER_PORT: u16 = 3000;

            let ipv4 = Ipv4Addr::from([100, 90, 215, 97]);
            let ipv6 = Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0016, 0x588f]);
            let mut device_manager =
                connlib_shared::tun_device_manager::platform::TunDeviceManager::new()?;
            device_manager.set_ips(ipv4, ipv6).await?;
            tun.add_route(ipv4.into())?;

            let server_addr = (ipv4, SERVER_PORT).into();

            // Listen for incoming packets on Wintun, and echo them.
            let server_task = tokio::spawn(async move {
                tracing::debug!("Server task entered");
                let mut requests_served = 0;
                // We aren't interested in allocator speed or doing any processing,
                // so just cache the response packet
                let mut response_pkt = None;
                let mut time_spent = Duration::from_millis(0);
                loop {
                    let mut req_buf = [0u8; MTU];
                    poll_fn(|cx| tun.poll_read(&mut req_buf, cx)).await?;
                    let start = Instant::now();
                    // Copied from the DNS module in `firezone-tunnel`
                    let mut answer = vec![RESP_CODE];
                    let response_len = answer.len();
                    let original_pkt = IpPacket::new(&req_buf).unwrap();
                    let Some(original_dgm) = original_pkt.as_udp() else {
                        continue;
                    };
                    if original_dgm.get_destination() != SERVER_PORT {
                        continue;
                    }
                    if original_dgm.payload()[0] != REQ_CODE {
                        panic!("Wrong request code");
                    }
                    let res_buf = response_pkt.get_or_insert_with(|| {
                        let hdr_len = original_pkt.packet_size() - original_dgm.payload().len();
                        let mut res_buf = Vec::with_capacity(hdr_len + response_len + 20);

                        // TODO: this is some weirdness due to how MutableIpPacket is implemented
                        // we need an extra 20 bytes padding.
                        res_buf.extend_from_slice(&[0; 20]);
                        res_buf.extend_from_slice(&original_pkt.packet()[..hdr_len]);
                        res_buf.append(&mut answer);

                        let mut pkt = MutableIpPacket::new(&mut res_buf).unwrap();
                        let dgm_len = UDP_HEADER_SIZE + response_len;
                        match &mut pkt {
                            MutableIpPacket::Ipv4(p) => {
                                p.set_total_length((hdr_len + response_len) as u16)
                            }
                            MutableIpPacket::Ipv6(p) => p.set_payload_length(dgm_len as u16),
                        }
                        pkt.swap_src_dst();

                        let mut dgm = MutableUdpPacket::new(pkt.payload_mut()).unwrap();
                        dgm.set_length(dgm_len as u16);
                        dgm.set_source(original_dgm.get_destination());
                        dgm.set_destination(original_dgm.get_source());

                        let mut pkt = MutableIpPacket::new(&mut res_buf).unwrap();
                        let udp_checksum = pkt
                            .to_immutable()
                            .udp_checksum(&pkt.to_immutable().unwrap_as_udp());
                        pkt.unwrap_as_udp().set_checksum(udp_checksum);
                        pkt.set_ipv4_checksum();

                        // TODO: more of this weirdness
                        res_buf.drain(0..20);
                        res_buf
                    });
                    tun.write(res_buf)?;
                    requests_served += 1;
                    time_spent += start.elapsed();
                    if requests_served >= NUM_REQUESTS {
                        break;
                    }
                }

                tracing::info!(time_spent = format!("{:?}", time_spent), "Server all good");
                Ok::<_, anyhow::Error>(())
            });

            // Wait for Wintun to be ready, then send it UDP packets and listen for
            // the echo.
            let client_task = tokio::spawn(async move {
                // We'd like to hit 100 Mbps up which is nothing special but it's a good
                // start.
                const EXPECTED_BITS_PER_SECOND: u64 = 100_000_000;
                // This has to be an `Option` because Windows takes about 4 seconds
                // to get the interface ready.
                let mut start_instant = None;

                tracing::debug!("Client task entered");
                let sock = UdpSocket::bind("0.0.0.0:0").await?;
                let mut responses_received = 0;
                let mut req_buf = vec![0u8; REQ_LEN];
                req_buf[0] = REQ_CODE;
                loop {
                    let Ok(_) = sock.send_to(&req_buf, server_addr).await else {
                        // It seems to take a few seconds for Windows to set everything up.
                        tracing::warn!("Failed to send");
                        tokio::time::sleep(Duration::from_secs(1)).await;
                        continue;
                    };
                    start_instant.get_or_insert_with(|| Instant::now());
                    let mut recv_buf = [0u8; MTU];
                    let Ok((bytes_received, packet_src)) = sock.recv_from(&mut recv_buf).await
                    else {
                        tracing::warn!("Timeout or couldn't recv packet");
                        continue;
                    };
                    if packet_src != server_addr {
                        tracing::warn!("Packet not from server");
                        continue;
                    }
                    assert_eq!(bytes_received, 1);
                    assert_eq!(recv_buf[0], RESP_CODE);
                    responses_received += 1;
                    if responses_received >= NUM_REQUESTS {
                        break;
                    }
                }

                let actual_dur = start_instant.unwrap().elapsed();
                // The 1_000_000 is needed to get decent precision without floats
                let actual_bps =
                    NUM_REQUESTS * REQ_LEN as u64 * 8 * 1_000_000 / actual_dur.as_micros() as u64;
                assert!(
                    actual_bps >= EXPECTED_BITS_PER_SECOND,
                    "{:?} < {:?}",
                    actual_bps,
                    EXPECTED_BITS_PER_SECOND
                );
                tracing::info!(?actual_bps, "Client all good");
                Ok::<_, anyhow::Error>(())
            });

            timeout(Duration::from_secs(30), async move {
                client_task.await??;
                server_task.await??;
                Ok::<_, anyhow::Error>(())
            })
            .await??;

            Ok(())
        })
    }

    /// Checks for regressions in issue #4765, un-initializing Wintun
    fn tunnel_drop() {
        // Each cycle takes about half a second, so this will need over a minute to run.
        for _ in 0..150 {
            let _tun = Tun::new().unwrap(); // This will panic if we don't correctly clean-up the wintun interface.
        }
    }
}

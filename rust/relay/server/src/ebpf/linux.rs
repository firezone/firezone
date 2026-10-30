use std::{
    ffi::CString,
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};

use anyhow::{Context as _, Result};
use aya::{
    Pod,
    maps::{
        HashMap, MapData, PerCpuArray, PerCpuValues, PerfEventArray,
        perf::{PerfEvent, PerfEventArrayBuffer},
    },
    programs::{Xdp, XdpMode},
};
use aya_log::EbpfLogger;
use ebpf_shared::{
    ClientAndChannelV4, ClientAndChannelV6, PacketCounter, PortAndPeerV4, PortAndPeerV6,
    RateLimitCounter, Route, StatsEvent,
};
use stun_codec::rfc5766::attributes::ChannelNumber;
use tokio::io::{Interest, unix::AsyncFd};
use tracing::level_filters::LevelFilter;

use crate::ebpf::AttachMode;

use crate::{AllocationPort, ClientSocket, PeerSocket, ThroughputLimit};

/// How many pages each per-CPU perf ring buffer spans.
///
/// Must be a power of two, hence it is defined as a hex value.
/// Must be sufficiently large to buffer large batches of [`StatsEvent`]s until we get scheduled.
/// Otherwise the kernel has to drop some and we skew our metrics.
/// Only a sample of packets is reported, so this buffers well over a second of events even at line rate.
const PAGE_COUNT: usize = 0x40;

/// How often we read the per-CPU packet counters of the eBPF program.
const PACKET_COUNTERS_INTERVAL: Duration = Duration::from_secs(1);

pub struct Program {
    ebpf: aya::Ebpf,

    #[expect(dead_code, reason = "We are just keeping it alive.")]
    stats: PerfEventArray<MapData>,
}

impl Program {
    pub fn try_load(
        interface: &str,
        attach_mode: AttachMode,
        log_level: LevelFilter,
        ipv4_interface_addr: Option<Ipv4Addr>,
        ipv6_interface_addr: Option<Ipv6Addr>,
        ipv4_public_addr: Option<Ipv4Addr>,
        ipv6_public_addr: Option<Ipv6Addr>,
    ) -> Result<Self> {
        let mut ebpf = load(
            log_level,
            ipv4_interface_addr,
            ipv6_interface_addr,
            ipv4_public_addr,
            ipv6_public_addr,
        )?;
        let logger = EbpfLogger::init(&mut ebpf)?;
        // SAFETY: `EbpfLogger` owns its descriptor, so it stays open as long as we hold it.
        let mut logger = unsafe { AsyncFd::register_with_interest(logger, Interest::READABLE)? };
        tokio::task::spawn(async move {
            loop {
                let mut guard = match logger.readable_mut().await {
                    Ok(guard) => guard,
                    Err(e) => {
                        tracing::warn!("Failed to wait for logger to be readable: {e}");
                        return;
                    }
                };
                guard.get_inner_mut().flush();
                guard.clear_ready();
            }
        });

        let program: &mut Xdp = ebpf
            .program_mut("handle_turn")
            .context("No program")?
            .try_into()?;

        let xdp_mode = match attach_mode {
            AttachMode::Generic => XdpMode::Skb,
            AttachMode::Driver => XdpMode::Driver,
        };

        program
            .attach(CString::new(interface)?.as_c_str(), xdp_mode)
            .with_context(|| format!("Failed to attached to interface {interface}"))?;

        let mut stats = PerfEventArray::try_from(
            ebpf.take_map("STATS")
                .context("`STATS` perf array not found")?,
        )?;

        let packet_size = otel_instruments::relay_packet_size();

        let processing_duration = otel_instruments::relay_xdp_processing_duration();

        let packet_counters = PerCpuArray::try_from(
            ebpf.take_map("PACKET_COUNTERS")
                .context("`PACKET_COUNTERS` array not found")?,
        )?;
        tokio::task::spawn(record_packet_counters(packet_counters));

        for cpu_id in aya::util::online_cpus()
            .map_err(|(_, error)| error)
            .context("Failed to determine number of CPUs")?
        {
            // open a separate perf buffer for each cpu
            let stats_array_buf = PerfEventArrayBuffer::open(cpu_id, PAGE_COUNT)?;
            stats.set(cpu_id, &stats_array_buf)?;
            // SAFETY: `PerfEventArrayBuffer` owns its descriptor, so it stays open as long as we hold it.
            let mut fd = unsafe { AsyncFd::register(stats_array_buf)? };

            tracing::debug!(%cpu_id, "Subscribing to stats events from eBPF kernel");

            // process each perf buffer in a separate task
            tokio::task::spawn({
                let packet_size = packet_size.clone();
                let processing_duration = processing_duration.clone();

                async move {
                    loop {
                        let events = fd
                            .async_io_mut(Interest::READABLE, |fd| {
                                if !fd.readable() {
                                    return Err(io::Error::from(io::ErrorKind::WouldBlock));
                                }

                                let events = fd.fold(
                                    (0_u64, 0_u64),
                                    |(num_read, num_lost), event| match event {
                                        PerfEvent::Sample { head, tail } => {
                                            let Some(stats) = StatsEvent::from_chunks(head, tail)
                                            else {
                                                tracing::warn!(
                                                    ?head,
                                                    ?tail,
                                                    "Failed to create stats event from byte buffer"
                                                );

                                                return (num_read + 1, num_lost);
                                            };

                                            packet_size.record(
                                                stats.relayed_data(),
                                                &[otel_attributes::relay_datapath_xdp()],
                                            );
                                            processing_duration.record(
                                                stats.processing_duration().as_nanos() as u64,
                                                &[],
                                            );

                                            (num_read + 1, num_lost)
                                        }
                                        PerfEvent::Lost { count } => (num_read, num_lost + count),
                                    },
                                );

                                Ok(events)
                            })
                            .await;

                        let (num_read, num_lost) = match events {
                            Ok(events) => events,
                            Err(e) => {
                                tracing::warn!("Failed to read perf events: {e}");
                                break;
                            }
                        };

                        if num_lost > 0 {
                            tracing::warn!(%cpu_id, %num_lost, "Lost perf events");
                        }

                        tracing::trace!(%cpu_id, %num_read, "Read perf events from eBPF kernel");
                    }
                }
            });
        }

        tracing::info!("eBPF TURN router loaded and attached to interface {interface}");

        Ok(Self { ebpf, stats })
    }

    /// Adds or replaces a channel binding, resetting its rate limiters.
    pub fn add_channel_binding(
        &mut self,
        client: ClientSocket,
        channel_number: ChannelNumber,
        peer: PeerSocket,
        allocation_port: AllocationPort,
        throughput_limit: Option<ThroughputLimit>,
    ) -> Result<()> {
        let client = client.into_socket();
        let peer = peer.into_socket();
        let limiter = ThroughputLimit::rate_limiter(throughput_limit);

        match (client, peer) {
            (SocketAddr::V4(client), SocketAddr::V4(peer)) => {
                let client_and_channel =
                    ClientAndChannelV4::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV4::from_socket(peer, allocation_port.value());

                self.chan_to_udp_44_map_mut()?.insert(
                    &client_and_channel,
                    &Route::new(port_and_peer, limiter),
                    0,
                )?;
                self.udp_to_chan_44_map_mut()?.insert(
                    &port_and_peer,
                    &Route::new(client_and_channel, limiter),
                    0,
                )?;
            }
            (SocketAddr::V6(client), SocketAddr::V6(peer)) => {
                let client_and_channel =
                    ClientAndChannelV6::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV6::from_socket(peer, allocation_port.value());

                self.chan_to_udp_66_map_mut()?.insert(
                    &client_and_channel,
                    &Route::new(port_and_peer, limiter),
                    0,
                )?;
                self.udp_to_chan_66_map_mut()?.insert(
                    &port_and_peer,
                    &Route::new(client_and_channel, limiter),
                    0,
                )?;
            }
            (SocketAddr::V4(client), SocketAddr::V6(peer)) => {
                let client_and_channel =
                    ClientAndChannelV4::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV6::from_socket(peer, allocation_port.value());

                self.chan_to_udp_46_map_mut()?.insert(
                    &client_and_channel,
                    &Route::new(port_and_peer, limiter),
                    0,
                )?;
                self.udp_to_chan_64_map_mut()?.insert(
                    &port_and_peer,
                    &Route::new(client_and_channel, limiter),
                    0,
                )?;
            }
            (SocketAddr::V6(client), SocketAddr::V4(peer)) => {
                let client_and_channel =
                    ClientAndChannelV6::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV4::from_socket(peer, allocation_port.value());

                self.chan_to_udp_64_map_mut()?.insert(
                    &client_and_channel,
                    &Route::new(port_and_peer, limiter),
                    0,
                )?;
                self.udp_to_chan_46_map_mut()?.insert(
                    &port_and_peer,
                    &Route::new(client_and_channel, limiter),
                    0,
                )?;
            }
        }

        Ok(())
    }

    pub fn remove_channel_binding(
        &mut self,
        client: ClientSocket,
        channel_number: ChannelNumber,
        peer: PeerSocket,
        allocation_port: AllocationPort,
    ) -> Result<()> {
        let client = client.into_socket();
        let peer = peer.into_socket();

        match (client, peer) {
            (SocketAddr::V4(client), SocketAddr::V4(peer)) => {
                let client_and_channel =
                    ClientAndChannelV4::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV4::from_socket(peer, allocation_port.value());

                self.chan_to_udp_44_map_mut()?.remove(&client_and_channel)?;
                self.udp_to_chan_44_map_mut()?.remove(&port_and_peer)?;
            }
            (SocketAddr::V6(client), SocketAddr::V6(peer)) => {
                let client_and_channel =
                    ClientAndChannelV6::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV6::from_socket(peer, allocation_port.value());

                self.chan_to_udp_66_map_mut()?.remove(&client_and_channel)?;
                self.udp_to_chan_66_map_mut()?.remove(&port_and_peer)?;
            }
            (SocketAddr::V4(client), SocketAddr::V6(peer)) => {
                let client_and_channel =
                    ClientAndChannelV4::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV6::from_socket(peer, allocation_port.value());

                self.chan_to_udp_46_map_mut()?.remove(&client_and_channel)?;
                self.udp_to_chan_64_map_mut()?.remove(&port_and_peer)?;
            }
            (SocketAddr::V6(client), SocketAddr::V4(peer)) => {
                let client_and_channel =
                    ClientAndChannelV6::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV4::from_socket(peer, allocation_port.value());

                self.chan_to_udp_64_map_mut()?.remove(&client_and_channel)?;
                self.udp_to_chan_46_map_mut()?.remove(&port_and_peer)?;
            }
        }

        Ok(())
    }

    /// Returns the total number of packets marked and dropped by rate limiting since the program was loaded.
    pub fn rate_limited_packets(&self) -> Result<RateLimitedPackets> {
        let map = self
            .ebpf
            .map("RATE_LIMIT_COUNTERS")
            .context("Map `RATE_LIMIT_COUNTERS` not found")?;
        let counters = PerCpuArray::<_, u64>::try_from(map)?;

        let sum = |counter: RateLimitCounter| -> Result<u64> {
            let values = counters.get(&(counter as u32), 0)?;

            Ok(values.iter().sum())
        };

        Ok(RateLimitedPackets {
            marked: sum(RateLimitCounter::Marked)?,
            dropped: sum(RateLimitCounter::Dropped)?,
        })
    }

    fn chan_to_udp_44_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, ClientAndChannelV4, Route<PortAndPeerV4>>> {
        self.hash_map_mut("CHAN_TO_UDP_44")
    }

    fn udp_to_chan_44_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, PortAndPeerV4, Route<ClientAndChannelV4>>> {
        self.hash_map_mut("UDP_TO_CHAN_44")
    }

    fn chan_to_udp_66_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, ClientAndChannelV6, Route<PortAndPeerV6>>> {
        self.hash_map_mut("CHAN_TO_UDP_66")
    }

    fn udp_to_chan_66_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, PortAndPeerV6, Route<ClientAndChannelV6>>> {
        self.hash_map_mut("UDP_TO_CHAN_66")
    }

    fn chan_to_udp_46_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, ClientAndChannelV4, Route<PortAndPeerV6>>> {
        self.hash_map_mut("CHAN_TO_UDP_46")
    }

    fn udp_to_chan_46_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, PortAndPeerV4, Route<ClientAndChannelV6>>> {
        self.hash_map_mut("UDP_TO_CHAN_46")
    }

    fn chan_to_udp_64_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, ClientAndChannelV6, Route<PortAndPeerV4>>> {
        self.hash_map_mut("CHAN_TO_UDP_64")
    }

    fn udp_to_chan_64_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, PortAndPeerV6, Route<ClientAndChannelV4>>> {
        self.hash_map_mut("UDP_TO_CHAN_64")
    }

    fn hash_map_mut<K, V>(&mut self, name: &'static str) -> Result<HashMap<&mut MapData, K, V>>
    where
        K: Pod,
        V: Pod,
    {
        let map = self
            .ebpf
            .map_mut(name)
            .with_context(|| format!("Map `{name}` not found"))?;
        let map = HashMap::<_, K, V>::try_from(map).context("Failed to convert map")?;

        Ok(map)
    }
}

/// Reports the packets relayed by the eBPF program as the deltas of its per-CPU counters.
async fn record_packet_counters(counters: PerCpuArray<MapData, u64>) {
    let packets = otel_instruments::relay_packets();
    let mut last_counts = [0_u64; PacketCounter::NUM_ENTRIES as usize];
    let mut interval = tokio::time::interval(PACKET_COUNTERS_INTERVAL);

    loop {
        interval.tick().await;

        for (index, last_count) in (0..PacketCounter::NUM_ENTRIES).zip(&mut last_counts) {
            let count = match counters.get(&index, 0) {
                Ok(values) => values.iter().sum::<u64>(),
                Err(e) => {
                    tracing::debug!("Failed to read packet counter from eBPF map: {e}");
                    continue;
                }
            };
            let delta = count.saturating_sub(*last_count);
            *last_count = count;

            if delta == 0 {
                continue;
            }

            let Some((ip_version, ecn)) = PacketCounter::ip_version_and_ecn(index) else {
                continue;
            };
            packets.add(
                delta,
                &[
                    otel_attributes::relay_datapath_xdp(),
                    otel_attributes::network_type_for_ip_version(ip_version),
                    otel_attributes::network_ecn(ecn),
                ],
            );
        }
    }
}

/// Loads the eBPF program into the kernel and configures it, without attaching it to an interface.
fn load(
    log_level: LevelFilter,
    ipv4_interface_addr: Option<Ipv4Addr>,
    ipv6_interface_addr: Option<Ipv6Addr>,
    ipv4_public_addr: Option<Ipv4Addr>,
    ipv6_public_addr: Option<Ipv6Addr>,
) -> Result<aya::Ebpf> {
    tracing::debug!(%log_level, "Setting eBPF log level");

    let mut ebpf = aya::EbpfLoader::new()
        .override_global(aya_log::LEVEL, &aya_log_level(log_level), true)
        .load(aya::include_bytes_aligned!(concat!(
            env!("OUT_DIR"),
            "/ebpf-turn-router-main"
        )))?;

    let program: &mut Xdp = ebpf
        .program_mut("handle_turn")
        .context("No program")?
        .try_into()?;
    program.load().context("Failed to load program")?;

    if let Some(ipv4) = ipv4_interface_addr {
        set_interface_ipv4_address(&mut ebpf, ipv4)?;
    }
    if let Some(ipv6) = ipv6_interface_addr {
        set_interface_ipv6_address(&mut ebpf, ipv6)?;
    }
    if let Some(ipv4) = ipv4_public_addr {
        set_public_ipv4_address(&mut ebpf, ipv4)?;
    }
    if let Some(ipv6) = ipv6_public_addr {
        set_public_ipv6_address(&mut ebpf, ipv6)?;
    }

    Ok(ebpf)
}

#[derive(Debug, Default, Clone, Copy)]
pub struct RateLimitedPackets {
    pub marked: u64,
    pub dropped: u64,
}

fn set_interface_ipv4_address(ebpf: &mut aya::Ebpf, addr: Ipv4Addr) -> Result<()> {
    set_per_cpu_map(ebpf, "INT_ADDR_V4", addr.octets())
        .context("Failed to set IPv4 interface address")?;

    tracing::info!(%addr, "Set eBPF interface IPv4 address");
    Ok(())
}

fn set_interface_ipv6_address(ebpf: &mut aya::Ebpf, addr: Ipv6Addr) -> Result<()> {
    set_per_cpu_map(ebpf, "INT_ADDR_V6", addr.octets())
        .context("Failed to set IPv6 interface address")?;

    tracing::info!(%addr, "Set eBPF interface IPv6 address");
    Ok(())
}

fn set_public_ipv4_address(ebpf: &mut aya::Ebpf, addr: Ipv4Addr) -> Result<()> {
    set_per_cpu_map(ebpf, "PUBLIC_ADDR_V4", addr.octets())
        .context("Failed to set IPv4 public address")?;

    tracing::info!(%addr, "Set eBPF public IPv4 address");
    Ok(())
}

fn set_public_ipv6_address(ebpf: &mut aya::Ebpf, addr: Ipv6Addr) -> Result<()> {
    set_per_cpu_map(ebpf, "PUBLIC_ADDR_V6", addr.octets())
        .context("Failed to set IPv6 public address")?;

    tracing::info!(%addr, "Set eBPF public IPv6 address");
    Ok(())
}

/// Converts the most verbose level of log records to emit into the value of [`aya_log::LEVEL`].
///
/// Without this, the eBPF program emits every log record and leaves filtering to userspace.
/// Log records go through a ring buffer that is shared by all CPUs, so emitting records for every
/// packet serialises the entire datapath on the ring buffer's lock.
///
/// The level is a constant to the verifier, so it removes disabled log statements entirely.
/// As a result, changing the log filter at runtime does not affect the eBPF program.
fn aya_log_level(level: LevelFilter) -> u8 {
    let Some(level) = level.into_level() else {
        return 0;
    };

    let level = match level {
        tracing::Level::ERROR => aya_log::Level::Error,
        tracing::Level::WARN => aya_log::Level::Warn,
        tracing::Level::INFO => aya_log::Level::Info,
        tracing::Level::DEBUG => aya_log::Level::Debug,
        tracing::Level::TRACE => aya_log::Level::Trace,
    };

    level as u8
}

fn set_per_cpu_map<T>(ebpf: &mut aya::Ebpf, map_name: &str, value: T) -> Result<()>
where
    T: Pod + Clone,
{
    let map = ebpf
        .map_mut(map_name)
        .with_context(|| format!("{map_name} map not found"))?;
    let mut per_cpu_map: PerCpuArray<&mut MapData, T> = PerCpuArray::try_from(map)?;

    // Get the number of CPUs and create a value for each CPU
    let num_cpus =
        aya::util::nr_cpus().map_err(|(_, e)| anyhow::anyhow!("Failed to get CPU count: {}", e))?;
    let values = vec![value; num_cpus];

    per_cpu_map
        .set(0, PerCpuValues::try_from(values)?, 0)
        .with_context(|| format!("Failed to set per-CPU values in {map_name}"))?;

    tracing::debug!(%map_name, %num_cpus, "Set per-CPU map with value");
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::net::{SocketAddrV4, SocketAddrV6};

    use aya::{TestRun as _, TestRunOptions};

    use super::*;

    const RELAY_V4: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 1);
    const RELAY_V6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0x100);
    const CLIENT_V4: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::new(198, 51, 100, 1), 40000);
    const CLIENT_V6: SocketAddrV6 =
        SocketAddrV6::new(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 40000, 0, 0);
    const PEER_V4: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::new(192, 0, 2, 1), 50000);
    const PEER_V6: SocketAddrV6 =
        SocketAddrV6::new(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2), 50000, 0, 0);
    const ALLOCATION: u16 = 49152;
    const OTHER_CLIENT_V4: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::new(198, 51, 100, 2), 40000);
    const OTHER_ALLOCATION: u16 = 49153;
    const CHANNEL: u16 = 0x4000;

    /// 1 Mbit/s makes every [`PAYLOAD_LEN`] packet cost 8ms of the 250ms burst tolerance at the limit
    /// and 10ms at the marking rate.
    const LIMIT_BPS: u64 = 1_000_000;
    const PAYLOAD_LEN: usize = 1000;
    /// Packets that fit into the burst tolerance: 11 pass (0 - 100ms ahead of the marking rate)
    /// and 21 are marked (88 - 248ms ahead of the limit).
    const PACKETS_IN_BURST: usize = 32;
    const NUM_PACKETS: usize = 60;

    const DST_MAC: [u8; 6] = [0x02, 0, 0, 0, 0, 1];
    const SRC_MAC: [u8; 6] = [0x02, 0, 0, 0, 0, 2];

    const XDP_DROP: u32 = 1;
    const XDP_TX: u32 = 3;

    const NOT_ECT: u8 = 0b00;
    const ECT0: u8 = 0b10;
    const CE: u8 = 0b11;

    #[test]
    #[ignore = "Needs root to load eBPF programs"]
    fn throughput_limit_marks_ecn_capable_ipv4_packets_before_dropping() {
        let mut program = Program::load_detached();
        program.bind_channel(CLIENT_V4.into(), PEER_V4.into(), LIMIT_BPS);
        let packet = channel_data_ipv4(ECT0);

        let outcomes = (0..NUM_PACKETS)
            .map(|_| program.run(&packet))
            .collect::<Vec<_>>();

        assert_marks_before_dropping(&outcomes);
        let counters = program.rate_limited_packets().unwrap();
        assert!(counters.marked >= 1, "{counters:?}");
        assert!(counters.dropped >= 1, "{counters:?}");
    }

    #[test]
    #[ignore = "Needs root to load eBPF programs"]
    fn throughput_limit_marks_ecn_capable_ipv6_packets_before_dropping() {
        let mut program = Program::load_detached();
        program.bind_channel(CLIENT_V6.into(), PEER_V6.into(), LIMIT_BPS);
        let packet = channel_data_ipv6(ECT0);

        let outcomes = (0..NUM_PACKETS)
            .map(|_| program.run(&packet))
            .collect::<Vec<_>>();

        assert_marks_before_dropping(&outcomes);
    }

    #[test]
    #[ignore = "Needs root to load eBPF programs"]
    fn throughput_limit_never_marks_packets_that_are_not_ecn_capable() {
        let mut program = Program::load_detached();
        program.bind_channel(CLIENT_V4.into(), PEER_V4.into(), LIMIT_BPS);
        let packet = channel_data_ipv4(NOT_ECT);

        let outcomes = (0..NUM_PACKETS)
            .map(|_| program.run(&packet))
            .collect::<Vec<_>>();

        assert!(outcomes.contains(&Outcome::Dropped));
        assert!(!outcomes.contains(&Outcome::Forwarded { ecn: CE }));
        assert_eq!(program.rate_limited_packets().unwrap().marked, 0);
    }

    #[test]
    #[ignore = "Needs root to load eBPF programs"]
    fn throughput_limit_applies_to_traffic_between_two_allocations() {
        let mut program = Program::load_detached();
        program.bind_channel(
            CLIENT_V4.into(),
            SocketAddrV4::new(RELAY_V4, OTHER_ALLOCATION).into(),
            0,
        );
        program.bind_channel_on(
            OTHER_ALLOCATION,
            OTHER_CLIENT_V4.into(),
            SocketAddrV4::new(RELAY_V4, ALLOCATION).into(),
            LIMIT_BPS,
        );
        let packet = channel_data_ipv4(ECT0);

        let outcomes = (0..NUM_PACKETS)
            .map(|_| program.run(&packet))
            .collect::<Vec<_>>();

        assert_marks_before_dropping(&outcomes);
    }

    #[test]
    #[ignore = "Needs root to load eBPF programs"]
    fn rebinding_a_channel_applies_its_new_throughput_limit() {
        let mut program = Program::load_detached();
        program.bind_channel(CLIENT_V4.into(), PEER_V4.into(), LIMIT_BPS);
        let packet = channel_data_ipv4(ECT0);
        let limited = (0..NUM_PACKETS)
            .map(|_| program.run(&packet))
            .collect::<Vec<_>>();
        assert_eq!(limited.last(), Some(&Outcome::Dropped));

        program.bind_channel(CLIENT_V4.into(), PEER_V4.into(), 0);
        let unlimited = (0..1000).map(|_| program.run(&packet)).collect::<Vec<_>>();

        assert!(
            unlimited
                .iter()
                .all(|o| *o == Outcome::Forwarded { ecn: ECT0 })
        );
    }

    #[test]
    #[ignore = "Needs root to load eBPF programs"]
    fn sends_packets_back_to_the_mac_address_they_came_from() {
        let mut program = Program::load_detached();
        program.bind_channel(CLIENT_V4.into(), PEER_V4.into(), 0);

        let (action, frame) = program.run_raw(&channel_data_ipv4(ECT0));

        assert_eq!(action, XDP_TX);
        assert_eq!(frame[..6], SRC_MAC);
        assert_eq!(frame[6..12], DST_MAC);
    }

    #[test]
    #[ignore = "Needs root to load eBPF programs"]
    fn relays_channel_data_without_public_ipv6_address() {
        let mut program = Program::load_detached_with(Some(RELAY_V4), None);
        program.bind_channel(CLIENT_V4.into(), PEER_V4.into(), 0);

        let outcome = program.run(&channel_data_ipv4(ECT0));

        assert_eq!(outcome, Outcome::Forwarded { ecn: ECT0 });
    }

    #[test]
    #[ignore = "Needs root to load eBPF programs"]
    fn relays_channel_data_without_public_ipv4_address() {
        let mut program = Program::load_detached_with(None, Some(RELAY_V6));
        program.bind_channel(CLIENT_V6.into(), PEER_V6.into(), 0);

        let outcome = program.run(&channel_data_ipv6(ECT0));

        assert_eq!(outcome, Outcome::Forwarded { ecn: ECT0 });
    }

    #[test]
    #[ignore = "Needs root to load eBPF programs"]
    fn counts_relayed_packets_by_ip_version_and_ecn() {
        let mut program = Program::load_detached();
        program.bind_channel(CLIENT_V4.into(), PEER_V4.into(), 0);
        program.bind_channel(CLIENT_V6.into(), PEER_V6.into(), 0);

        for _ in 0..3 {
            program.run(&channel_data_ipv4(ECT0));
        }
        program.run(&channel_data_ipv6(NOT_ECT));

        assert_eq!(program.packet_count(4, ECT0), 3);
        assert_eq!(program.packet_count(6, NOT_ECT), 1);
        assert_eq!(program.packet_count(4, NOT_ECT), 0);
    }

    #[derive(Debug, PartialEq)]
    enum Outcome {
        Forwarded { ecn: u8 },
        Dropped,
    }

    fn assert_marks_before_dropping(outcomes: &[Outcome]) {
        let first_mark = outcomes
            .iter()
            .position(|o| *o == Outcome::Forwarded { ecn: CE })
            .expect("some packets to be marked");
        let first_drop = outcomes
            .iter()
            .position(|o| *o == Outcome::Dropped)
            .expect("some packets to be dropped");
        let num_forwarded = outcomes.iter().filter(|o| **o != Outcome::Dropped).count();

        assert!(
            outcomes[..first_mark]
                .iter()
                .all(|o| *o == Outcome::Forwarded { ecn: ECT0 }),
            "{outcomes:?}"
        );
        assert!(first_mark < first_drop, "{outcomes:?}");
        // Allow a little slack for the burst allowance that refills while the test runs.
        assert!(
            (PACKETS_IN_BURST..PACKETS_IN_BURST + 4).contains(&num_forwarded),
            "{outcomes:?}"
        );
    }

    impl Program {
        fn load_detached() -> Self {
            Self::load_detached_with(Some(RELAY_V4), Some(RELAY_V6))
        }

        fn load_detached_with(ipv4: Option<Ipv4Addr>, ipv6: Option<Ipv6Addr>) -> Self {
            let mut ebpf = load(LevelFilter::OFF, ipv4, ipv6, ipv4, ipv6).unwrap();
            let stats = PerfEventArray::try_from(ebpf.take_map("STATS").unwrap()).unwrap();

            Self { ebpf, stats }
        }

        fn bind_channel(&mut self, client: SocketAddr, peer: SocketAddr, limit_bps: u64) {
            self.bind_channel_on(ALLOCATION, client, peer, limit_bps);
        }

        fn bind_channel_on(
            &mut self,
            allocation: u16,
            client: SocketAddr,
            peer: SocketAddr,
            limit_bps: u64,
        ) {
            self.add_channel_binding(
                ClientSocket::new(client),
                ChannelNumber::new(CHANNEL).unwrap(),
                PeerSocket::new(peer),
                AllocationPort::new(allocation),
                ThroughputLimit::from_bits_per_second(limit_bps),
            )
            .unwrap();
        }

        fn packet_count(&self, ip_version: u8, ecn: u8) -> u64 {
            let counters =
                PerCpuArray::<_, u64>::try_from(self.ebpf.map("PACKET_COUNTERS").unwrap()).unwrap();

            counters
                .get(&PacketCounter::index(ip_version, ecn), 0)
                .unwrap()
                .iter()
                .sum()
        }

        fn run(&self, packet: &[u8]) -> Outcome {
            let (action, frame) = self.run_raw(packet);

            match action {
                XDP_TX => Outcome::Forwarded {
                    ecn: ecn_of(&frame),
                },
                XDP_DROP => Outcome::Dropped,
                other => panic!("Unexpected XDP action {other}"),
            }
        }

        fn run_raw(&self, packet: &[u8]) -> (u32, Vec<u8>) {
            let program: &Xdp = self
                .ebpf
                .program("handle_turn")
                .unwrap()
                .try_into()
                .unwrap();
            let mut data_out = vec![0; packet.len() + 64];

            let result = program
                .test_run(TestRunOptions {
                    data_in: Some(packet),
                    data_out: Some(&mut data_out),
                    ..TestRunOptions::default()
                })
                .unwrap();

            data_out.truncate(result.data_size_out as usize);

            (result.return_value, data_out)
        }
    }

    /// Reads the ECN codepoint of an Ethernet frame, asserting that the IPv4 header checksum is still valid.
    fn ecn_of(frame: &[u8]) -> u8 {
        let ip = &frame[14..];

        match ip[0] >> 4 {
            4 => {
                assert_eq!(ones_complement_sum(&ip[..20]), 0xffff, "Bad IPv4 checksum");

                ip[1] & 0b11
            }
            6 => (ip[1] >> 4) & 0b11,
            v => panic!("Unexpected IP version {v}"),
        }
    }

    fn channel_data_ipv4(ecn: u8) -> Vec<u8> {
        let udp = channel_data_udp(CLIENT_V4.port());

        let mut ip = Vec::new();
        ip.extend_from_slice(&[0x45, ecn]);
        ip.extend_from_slice(&(20 + udp.len() as u16).to_be_bytes());
        ip.extend_from_slice(&[0, 0, 0x40, 0, 64, 17, 0, 0]);
        ip.extend_from_slice(&CLIENT_V4.ip().octets());
        ip.extend_from_slice(&RELAY_V4.octets());
        let checksum = !ones_complement_sum(&ip);
        ip[10..12].copy_from_slice(&checksum.to_be_bytes());
        ip.extend_from_slice(&udp);

        ethernet_frame(0x0800, &ip)
    }

    fn channel_data_ipv6(ecn: u8) -> Vec<u8> {
        let udp = channel_data_udp(CLIENT_V6.port());

        let mut ip = Vec::new();
        ip.extend_from_slice(&[0x60, ecn << 4, 0, 0]);
        ip.extend_from_slice(&(udp.len() as u16).to_be_bytes());
        ip.extend_from_slice(&[17, 64]);
        ip.extend_from_slice(&CLIENT_V6.ip().octets());
        ip.extend_from_slice(&RELAY_V6.octets());
        ip.extend_from_slice(&udp);

        ethernet_frame(0x86dd, &ip)
    }

    /// A UDP datagram carrying a ChannelData message; the checksum is left empty because the XDP program only updates it.
    fn channel_data_udp(src_port: u16) -> Vec<u8> {
        let mut udp = Vec::new();
        udp.extend_from_slice(&src_port.to_be_bytes());
        udp.extend_from_slice(&3478_u16.to_be_bytes());
        udp.extend_from_slice(&(8 + 4 + PAYLOAD_LEN as u16).to_be_bytes());
        udp.extend_from_slice(&[0, 0]);
        udp.extend_from_slice(&CHANNEL.to_be_bytes());
        udp.extend_from_slice(&(PAYLOAD_LEN as u16).to_be_bytes());
        udp.resize(udp.len() + PAYLOAD_LEN, 0xab);

        udp
    }

    fn ethernet_frame(ether_type: u16, payload: &[u8]) -> Vec<u8> {
        let mut frame = Vec::new();
        frame.extend_from_slice(&DST_MAC);
        frame.extend_from_slice(&SRC_MAC);
        frame.extend_from_slice(&ether_type.to_be_bytes());
        frame.extend_from_slice(payload);

        frame
    }

    fn ones_complement_sum(bytes: &[u8]) -> u16 {
        let mut sum = bytes
            .chunks(2)
            .map(|word| u32::from(u16::from_be_bytes([word[0], *word.get(1).unwrap_or(&0)])))
            .sum::<u32>();

        while sum > 0xffff {
            sum = (sum & 0xffff) + (sum >> 16);
        }

        sum as u16
    }
}

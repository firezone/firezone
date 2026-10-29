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
    ClientAndChannelV4, ClientAndChannelV6, PacketCounter, PortAndPeerV4, PortAndPeerV6, StatsEvent,
};
use stun_codec::rfc5766::attributes::ChannelNumber;
use tokio::io::{Interest, unix::AsyncFd};
use tracing::level_filters::LevelFilter;

use crate::ebpf::AttachMode;

use crate::{AllocationPort, ClientSocket, PeerSocket};

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
        tracing::debug!(%log_level, "Setting eBPF log level");

        let mut ebpf = aya::EbpfLoader::new()
            .override_global(aya_log::LEVEL, &aya_log_level(log_level), true)
            .load(aya::include_bytes_aligned!(concat!(
                env!("OUT_DIR"),
                "/ebpf-turn-router-main"
            )))?;
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
        program.load().context("Failed to load program")?;

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

        // Set interface addresses if provided
        if let Some(ipv4) = ipv4_interface_addr {
            set_interface_ipv4_address(&mut ebpf, ipv4)?;
        }
        if let Some(ipv6) = ipv6_interface_addr {
            set_interface_ipv6_address(&mut ebpf, ipv6)?;
        }

        // Set public addresses if provided
        if let Some(ipv4) = ipv4_public_addr {
            set_public_ipv4_address(&mut ebpf, ipv4)?;
        }
        if let Some(ipv6) = ipv6_public_addr {
            set_public_ipv6_address(&mut ebpf, ipv6)?;
        }

        tracing::info!("eBPF TURN router loaded and attached to interface {interface}");

        Ok(Self { ebpf, stats })
    }

    pub fn add_channel_binding(
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

                self.chan_to_udp_44_map_mut()?
                    .insert(&client_and_channel, &port_and_peer, 0)?;
                self.udp_to_chan_44_map_mut()?
                    .insert(&port_and_peer, &client_and_channel, 0)?;
            }
            (SocketAddr::V6(client), SocketAddr::V6(peer)) => {
                let client_and_channel =
                    ClientAndChannelV6::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV6::from_socket(peer, allocation_port.value());

                self.chan_to_udp_66_map_mut()?
                    .insert(&client_and_channel, &port_and_peer, 0)?;
                self.udp_to_chan_66_map_mut()?
                    .insert(&port_and_peer, &client_and_channel, 0)?;
            }
            (SocketAddr::V4(client), SocketAddr::V6(peer)) => {
                let client_and_channel =
                    ClientAndChannelV4::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV6::from_socket(peer, allocation_port.value());

                self.chan_to_udp_46_map_mut()?
                    .insert(&client_and_channel, &port_and_peer, 0)?;
                self.udp_to_chan_64_map_mut()?
                    .insert(&port_and_peer, &client_and_channel, 0)?;
            }
            (SocketAddr::V6(client), SocketAddr::V4(peer)) => {
                let client_and_channel =
                    ClientAndChannelV6::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV4::from_socket(peer, allocation_port.value());

                self.chan_to_udp_64_map_mut()?
                    .insert(&client_and_channel, &port_and_peer, 0)?;
                self.udp_to_chan_46_map_mut()?
                    .insert(&port_and_peer, &client_and_channel, 0)?;
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

    fn chan_to_udp_44_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, ClientAndChannelV4, PortAndPeerV4>> {
        self.hash_map_mut("CHAN_TO_UDP_44")
    }

    fn udp_to_chan_44_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, PortAndPeerV4, ClientAndChannelV4>> {
        self.hash_map_mut("UDP_TO_CHAN_44")
    }

    fn chan_to_udp_66_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, ClientAndChannelV6, PortAndPeerV6>> {
        self.hash_map_mut("CHAN_TO_UDP_66")
    }

    fn udp_to_chan_66_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, PortAndPeerV6, ClientAndChannelV6>> {
        self.hash_map_mut("UDP_TO_CHAN_66")
    }

    fn chan_to_udp_46_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, ClientAndChannelV4, PortAndPeerV6>> {
        self.hash_map_mut("CHAN_TO_UDP_46")
    }

    fn udp_to_chan_46_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, PortAndPeerV4, ClientAndChannelV6>> {
        self.hash_map_mut("UDP_TO_CHAN_46")
    }

    fn chan_to_udp_64_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, ClientAndChannelV6, PortAndPeerV4>> {
        self.hash_map_mut("CHAN_TO_UDP_64")
    }

    fn udp_to_chan_64_map_mut(
        &mut self,
    ) -> Result<HashMap<&mut MapData, PortAndPeerV6, ClientAndChannelV4>> {
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

            let (ip_version, ecn) = PacketCounter::ip_version_and_ecn(index);
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

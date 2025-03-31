use std::net::SocketAddr;

use anyhow::{Context as _, Result};
use aya::{
    Pod,
    maps::{Array, HashMap, MapData},
    programs::{Xdp, XdpFlags},
};
use aya_log::EbpfLogger;
use ebpf_shared::{ClientAndChannelV4, ClientAndChannelV6, Config, PortAndPeerV4, PortAndPeerV6};
use stun_codec::rfc5766::attributes::ChannelNumber;

use crate::{AllocationPort, ClientSocket, PeerSocket};

pub struct Program {
    ebpf: aya::Ebpf,
}

impl Program {
    pub fn try_load(interface: &'static str) -> Result<Self> {
        let mut ebpf = aya::Ebpf::load(aya::include_bytes_aligned!(concat!(
            env!("OUT_DIR"),
            "/ebpf-turn-router-main"
        )))?;
        let _ = EbpfLogger::init(&mut ebpf);
        let program: &mut Xdp = ebpf
            .program_mut("handle_turn")
            .context("No program")?
            .try_into()?;
        program.load().context("Failed to load program")?;
        program
            .attach(interface, XdpFlags::default())
            .with_context(|| format!("Failed to attached to interface {interface}"))?;

        Ok(Self { ebpf })
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
                    .insert(client_and_channel, port_and_peer, 0)?;
                self.udp_to_chan_44_map_mut()?
                    .insert(port_and_peer, client_and_channel, 0)?;
            }
            (SocketAddr::V6(client), SocketAddr::V6(peer)) => {
                let client_and_channel =
                    ClientAndChannelV6::from_socket(client, channel_number.value());
                let port_and_peer = PortAndPeerV6::from_socket(peer, allocation_port.value());

                self.chan_to_udp_66_map_mut()?
                    .insert(client_and_channel, port_and_peer, 0)?;
                self.udp_to_chan_66_map_mut()?
                    .insert(port_and_peer, client_and_channel, 0)?;
            }
            (SocketAddr::V4(_), SocketAddr::V6(_)) | (SocketAddr::V6(_), SocketAddr::V4(_)) => {
                // Relaying between IPv4 and IPv6 is not supported in the eBPF kernel.
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
            (SocketAddr::V4(_), SocketAddr::V6(_)) | (SocketAddr::V6(_), SocketAddr::V4(_)) => {
                // Relaying between IPv4 and IPv6 is not supported in the eBPF kernel.
            }
        }

        Ok(())
    }

    pub fn set_config(&mut self, config: Config) -> Result<()> {
        self.config_array_mut()?.set(0, config, 0)?;

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

    fn config_array_mut(&mut self) -> Result<Array<&mut MapData, Config>> {
        self.array_mut("CONFIG")
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

    fn array_mut<T>(&mut self, name: &'static str) -> Result<Array<&mut MapData, T>>
    where
        T: Pod,
    {
        let map = self
            .ebpf
            .map_mut(name)
            .with_context(|| format!("Array `{name}` not found"))?;
        let map = Array::<_, T>::try_from(map).context("Failed to convert array")?;

        Ok(map)
    }
}

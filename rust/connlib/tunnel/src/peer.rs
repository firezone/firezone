use std::{collections::HashMap, net::IpAddr, sync::Arc};

use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::StaticSecret;
use bytes::Bytes;
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ResourceDescription, ResourceId},
    Callbacks, Error, Result,
};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use parking_lot::{Mutex, RwLock};
use pnet_packet::MutablePacket;
use secrecy::ExposeSecret;
use webrtc::data::data_channel::DataChannel;

use crate::{ip_packet::MutableIpPacket, resource_table::ResourceTable, PeerConfig};

type ExpiryingResource = (ResourceDescription, DateTime<Utc>);

pub(crate) struct Peer<TId> {
    pub tunnel: Mutex<Tunn>,
    pub index: u32,
    pub allowed_ips: RwLock<IpNetworkTable<()>>,
    pub channel: Arc<DataChannel>,
    pub conn_id: TId,
    pub resources: Option<RwLock<ResourceTable<ExpiryingResource>>>,
    // Here we store the address that we obtained for the resource that the peer corresponds to.
    // This can have the following problem:
    // 1. Peer sends packet to address.com and it resolves to 1.1.1.1
    // 2. Now Peer sends another packet to address.com but it resolves to 2.2.2.2
    // 3. We receive an outstanding response(or push) from 1.1.1.1
    // This response(or push) is ignored, since we store only the last.
    // so, TODO: store multiple ips and expire them.
    // Note that this case is quite an unlikely edge case so I wouldn't prioritize this fix
    // TODO: Also check if there's any case where we want to talk to ipv4 and ipv6 from the same peer.
    pub translated_resource_addresses: RwLock<HashMap<IpAddr, ResourceId>>,
}

// TODO: For now we only use these fields with debug
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub(crate) struct PeerStats<TId> {
    pub index: u32,
    pub allowed_ips: Vec<IpNetwork>,
    pub conn_id: TId,
    pub dns_resources: HashMap<String, ExpiryingResource>,
    pub network_resources: HashMap<IpNetwork, ExpiryingResource>,
    pub translated_resource_addresses: HashMap<IpAddr, ResourceId>,
}

impl<TId> Peer<TId>
where
    TId: Copy,
{
    pub(crate) fn stats(&self) -> PeerStats<TId> {
        let (network_resources, dns_resources) = self.resources.as_ref().map_or_else(
            || (HashMap::new(), HashMap::new()),
            |resources| {
                let resources = resources.read();
                (resources.network_resources(), resources.dns_resources())
            },
        );
        let allowed_ips = self.allowed_ips.read().iter().map(|(ip, _)| ip).collect();
        let translated_resource_addresses = self.translated_resource_addresses.read().clone();
        PeerStats {
            index: self.index,
            allowed_ips,
            conn_id: self.conn_id,
            dns_resources,
            network_resources,
            translated_resource_addresses,
        }
    }

    #[inline(always)]
    pub(crate) async fn send_infallible<CB: Callbacks>(&self, data: Bytes, callbacks: &CB) {
        if let Err(e) = self.channel.write(&Bytes::copy_from_slice(&data)).await {
            tracing::error!("Couldn't send packet to connected peer: {e}");
            let _ = callbacks.on_error(&e.into());
        }
    }

    pub(crate) fn new(
        private_key: StaticSecret,
        index: u32,
        peer_config: PeerConfig,
        channel: Arc<DataChannel>,
        conn_id: TId,
        resource: Option<(ResourceDescription, DateTime<Utc>)>,
    ) -> Peer<TId> {
        let tunnel = Tunn::new(
            private_key.clone(),
            peer_config.public_key,
            Some(peer_config.preshared_key.expose_secret().0),
            peer_config.persistent_keepalive,
            index,
            None,
        )
        .expect("never actually fails"); // See https://github.com/cloudflare/boringtun/pull/366.

        let mut allowed_ips = IpNetworkTable::new();
        for ip in peer_config.ips {
            allowed_ips.insert(ip, ());
        }
        let allowed_ips = RwLock::new(allowed_ips);
        let resources = resource.map(|r| {
            let mut resource_table = ResourceTable::new();
            resource_table.insert(r);
            RwLock::new(resource_table)
        });

        Peer {
            tunnel: Mutex::new(tunnel),
            index,
            allowed_ips,
            channel,
            conn_id,
            resources,
            translated_resource_addresses: Default::default(),
        }
    }

    pub(crate) fn get_translation(&self, ip: IpAddr) -> Option<ResourceDescription> {
        let id = self.translated_resource_addresses.read().get(&ip).cloned();
        self.resources.as_ref().and_then(|resources| {
            id.and_then(|id| resources.read().get_by_id(&id).map(|r| r.0.clone()))
        })
    }

    pub(crate) fn add_allowed_ip(&self, ip: IpNetwork) {
        self.allowed_ips.write().insert(ip, ());
    }

    pub(crate) fn update_timers<'a>(&self, dst: &'a mut [u8]) -> TunnResult<'a> {
        self.tunnel.lock().update_timers(dst)
    }

    pub(crate) async fn shutdown(&self) -> Result<()> {
        self.channel.close().await?;
        Ok(())
    }

    pub(crate) fn is_emptied(&self) -> bool {
        self.resources.as_ref().is_some_and(|r| r.read().is_empty())
    }

    pub(crate) fn expire_resources(&self) {
        if let Some(resources) = &self.resources {
            // TODO: We could move this to resource_table and make it way faster
            let expire_resources: Vec<_> = resources
                .read()
                .values()
                .filter(|(_, e)| e <= &Utc::now())
                .cloned()
                .collect();
            {
                // Oh oh! 2 Mutexes
                let mut resources = resources.write();
                let mut translated_resource_addresses = self.translated_resource_addresses.write();
                for r in expire_resources {
                    resources.cleanup_resource(&r);
                    translated_resource_addresses.retain(|_, &mut i| r.0.id() != i);
                }
            }
        }
    }

    pub(crate) fn add_resource(&self, resource: ResourceDescription, expires_at: DateTime<Utc>) {
        if let Some(resources) = &self.resources {
            resources.write().insert((resource, expires_at))
        }
    }

    pub(crate) fn is_allowed(&self, addr: IpAddr) -> bool {
        self.allowed_ips.read().longest_match(addr).is_some()
    }

    pub(crate) fn update_translated_resource_address(&self, id: ResourceId, addr: IpAddr) {
        self.translated_resource_addresses.write().insert(addr, id);
    }

    /// Sends the given packet to this peer by encapsulating it in a wireguard packet.
    pub(crate) async fn send<'a>(
        &self,
        mut packet: MutableIpPacket<'a>,
        dest: IpAddr,
        buf: &mut [u8],
    ) -> Result<()> {
        if let Some(resource) = self.get_translation(packet.to_immutable().source()) {
            let ResourceDescription::Dns(resource) = resource else {
                tracing::error!(
                    "Control protocol error: only dns resources should have a resource_address"
                );
                return Err(Error::ControlProtocolError);
            };

            match packet {
                MutableIpPacket::MutableIpv4Packet(ref mut p) => p.set_source(resource.ipv4),
                MutableIpPacket::MutableIpv6Packet(ref mut p) => p.set_source(resource.ipv6),
            }

            packet.update_checksum();
        }
        let packet = match self.tunnel.lock().encapsulate(packet.packet_mut(), buf) {
            TunnResult::Done => return Ok(()),
            TunnResult::Err(e) => return Err(e.into()),
            TunnResult::WriteToNetwork(b) => b,
            _ => panic!("Unexpected result from `encapsulate`"),
        };

        tracing::trace!(target: "wire", action = "writing", from = "iface", to = %dest);

        self.channel.write(&Bytes::copy_from_slice(packet)).await?;

        Ok(())
    }

    pub(crate) fn get_packet_resource(
        &self,
        packet: &mut [u8],
    ) -> Option<(IpAddr, ResourceDescription)> {
        let resources = self.resources.as_ref()?;

        let dst = Tunn::dst_address(packet)?;

        let Some(resource) = resources.read().get_by_ip(dst).map(|r| r.0.clone()) else {
            tracing::warn!("client tried to hijack the tunnel for resource itsn't allowed.");
            return None;
        };

        Some((dst, resource))
    }
}

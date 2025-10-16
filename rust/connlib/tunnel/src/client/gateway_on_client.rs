use std::{
    collections::HashSet,
    net::{IpAddr, SocketAddr},
};

use connlib_model::{GatewayId, ResourceId};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::IpPacket;

use crate::{IpConfig, NotAllowedResource};

/// The state of one gateway on a client.
pub(crate) struct GatewayOnClient {
    id: GatewayId,
    gateway_tun: IpConfig,
    pub allowed_ips: IpNetworkTable<HashSet<ResourceId>>,
}

impl GatewayOnClient {
    pub(crate) fn insert_id(&mut self, ip: &IpNetwork, id: &ResourceId) {
        if let Some(resources) = self.allowed_ips.exact_match_mut(*ip) {
            resources.insert(*id);
        } else {
            self.allowed_ips.insert(*ip, HashSet::from([*id]));
        }
    }

    /// For a given destination IP, return the endpoint to which the DNS query should be sent.
    pub(crate) fn tun_dns_server_endpoint(&self, dst: IpAddr) -> SocketAddr {
        let new_dst_ip = match dst {
            IpAddr::V4(_) => self.gateway_tun.v4.into(),
            IpAddr::V6(_) => self.gateway_tun.v6.into(),
        };
        let new_dst_port = crate::gateway::TUN_DNS_PORT;

        SocketAddr::new(new_dst_ip, new_dst_port)
    }
}

impl GatewayOnClient {
    pub(crate) fn new(id: GatewayId, gateway_tun: IpConfig) -> GatewayOnClient {
        GatewayOnClient {
            id,
            allowed_ips: IpNetworkTable::new(),
            gateway_tun,
        }
    }
}

impl GatewayOnClient {
    pub(crate) fn ensure_allowed_src(&self, packet: &IpPacket) -> anyhow::Result<()> {
        let src = packet.source();

        if self.gateway_tun.is_ip(src) {
            return Ok(());
        }

        if self.allowed_ips.longest_match(src).is_none() {
            return Err(anyhow::Error::new(NotAllowedResource(src)));
        }

        Ok(())
    }

    pub fn id(&self) -> GatewayId {
        self.id
    }
}

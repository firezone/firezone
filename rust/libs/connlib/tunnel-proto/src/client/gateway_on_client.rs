use std::{
    collections::HashSet,
    net::{IpAddr, SocketAddr},
};

use connlib_model::ResourceId;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::IpPacket;

use crate::{IpConfig, NotAllowedResource};

/// The state of one gateway on a client.
pub(crate) struct GatewayOnClient {
    gateway_tun: IpConfig,
    allowed_ips: IpNetworkTable<HashSet<ResourceId>>,
    last_allowed_src: Option<IpAddr>,
}

impl GatewayOnClient {
    pub(crate) fn allow_ip_for_resource(&mut self, ip: impl Into<IpNetwork>, id: ResourceId) {
        let ip = ip.into();

        if let Some(resources) = self.allowed_ips.exact_match_mut(ip) {
            resources.insert(id);
        } else {
            self.allowed_ips.insert(ip, HashSet::from([id]));
        }
    }

    pub(crate) fn remove_resource(&mut self, id: ResourceId) {
        self.last_allowed_src = None;

        // First we remove the id from all allowed ips
        for (_, resources) in self
            .allowed_ips
            .iter_mut()
            .filter(|(_, resources)| resources.contains(&id))
        {
            resources.remove(&id);
        }

        // We remove all empty allowed ips entry since there's no resource that corresponds to it
        self.allowed_ips.retain(|_, r| !r.is_empty());
    }

    pub(crate) fn no_allowed_resources(&self) -> bool {
        self.allowed_ips.is_empty()
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

    pub(crate) fn gateway_tun(&self) -> IpConfig {
        self.gateway_tun
    }
}

impl GatewayOnClient {
    pub(crate) fn new(gateway_tun: IpConfig) -> GatewayOnClient {
        GatewayOnClient {
            allowed_ips: IpNetworkTable::new(),
            last_allowed_src: None,
            gateway_tun,
        }
    }
}

impl GatewayOnClient {
    pub(crate) fn ensure_allowed_src(&mut self, packet: &IpPacket) -> anyhow::Result<()> {
        let src = packet.source();

        if self.gateway_tun.is_ip(src) || self.last_allowed_src == Some(src) {
            return Ok(());
        }

        if self.allowed_ips.longest_match(src).is_none() {
            return Err(anyhow::Error::new(NotAllowedResource(src)));
        }

        self.last_allowed_src = Some(src);

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, Ipv6Addr};

    use super::*;

    #[test]
    fn removed_resource_stops_allowing_previously_seen_source() {
        let mut gateway = GatewayOnClient::new(IpConfig {
            v4: Ipv4Addr::new(100, 64, 0, 1),
            v6: Ipv6Addr::LOCALHOST,
        });
        let resource = ResourceId::from_u128(1);
        let src = Ipv4Addr::new(10, 0, 0, 1);
        gateway.allow_ip_for_resource(src, resource);
        let packet =
            ip_packet::make::udp_packet(src, Ipv4Addr::new(100, 64, 0, 2), 80, 5401, &[]).unwrap();
        gateway.ensure_allowed_src(&packet).unwrap();

        gateway.remove_resource(resource);

        assert!(gateway.ensure_allowed_src(&packet).is_err());
    }
}

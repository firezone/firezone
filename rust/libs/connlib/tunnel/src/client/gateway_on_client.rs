use std::{
    collections::{HashMap, HashSet},
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

    /// The portal's per-flow ingest token for each authorized resource, used to
    /// attribute the Client's (initiator) flow logs. Same lifetime as the resource
    /// authorization.
    ingest_tokens: HashMap<ResourceId, String>,
}

impl GatewayOnClient {
    /// Records the initiator-side ingest token minted for `id`, or clears it when
    /// the portal sent none.
    pub(crate) fn set_ingest_token(&mut self, id: ResourceId, token: Option<String>) {
        match token {
            Some(token) => {
                self.ingest_tokens.insert(id, token);
            }
            None => {
                self.ingest_tokens.remove(&id);
            }
        }
    }

    /// The ingest token for `id`, if one was minted.
    pub(crate) fn ingest_token(&self, id: &ResourceId) -> Option<String> {
        self.ingest_tokens.get(id).cloned()
    }

    pub(crate) fn allow_ip_for_resource(&mut self, ip: impl Into<IpNetwork>, id: ResourceId) {
        let ip = ip.into();

        if let Some(resources) = self.allowed_ips.exact_match_mut(ip) {
            resources.insert(id);
        } else {
            self.allowed_ips.insert(ip, HashSet::from([id]));
        }
    }

    pub(crate) fn remove_resource(&mut self, id: ResourceId) {
        self.ingest_tokens.remove(&id);

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
            gateway_tun,
            ingest_tokens: HashMap::new(),
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
}

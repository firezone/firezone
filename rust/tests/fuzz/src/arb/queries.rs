//! What the generator asks the reference state to learn which transitions it can generate.

use std::{
    collections::{BTreeMap, BTreeSet},
    iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Instant,
};

use connlib_model::{ClientId, ResourceId};
use dns_types::{DomainName, RecordType};
use ip_network::{Ipv4Network, Ipv6Network};
use itertools::Itertools as _;
use tunnel_proto::{dns, messages::Filter};

use crate::dns_records::DnsRecords;
use crate::probe::{FlowId, IcmpFlow, UdpFlow};
use crate::reference::{ReferenceState, has_expired, is_held};
use crate::resource as client;
use crate::stub_portal::StubPortal;
use crate::transition::{Destination, Seq};

impl ReferenceState {
    pub(crate) fn all_resource_ids(&self) -> Vec<ResourceId> {
        self.clients
            .values()
            .flat_map(|c| c.inner().all_resource_ids())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    pub(crate) fn deauthorizable_resource_ids(&self, portal: &StubPortal) -> Vec<ResourceId> {
        self.all_resource_ids()
            .into_iter()
            .filter(|resource| portal.site_for_resource(*resource).is_some())
            .collect()
    }

    /// Peer authorizations a receiving client can expire while the sender keeps its own.
    pub(crate) fn expirable_peer_authorizations(
        &self,
    ) -> Vec<(ClientId, ClientId, BTreeSet<ResourceId>)> {
        let mut expirable = Vec::new();

        for (peer, state) in &self.clients {
            for (client, pools) in state.inner().inbound_peer_pools() {
                let pools = pools
                    .into_iter()
                    .filter(|pool| {
                        self.clients[&client]
                            .inner()
                            .authorized_pools_towards(*peer)
                            .any(|authorized| authorized == *pool)
                    })
                    .collect::<BTreeSet<_>>();

                if pools.is_empty() {
                    continue;
                }

                expirable.push((client, *peer, pools));
            }
        }

        expirable
    }

    /// Resources a Gateway currently holds an authorization for.
    pub(crate) fn revocable_resource_ids(&self, portal: &StubPortal) -> Vec<ResourceId> {
        let authorized = self
            .gateways
            .values()
            .flat_map(|gateway| gateway.inner().authorized_resources())
            .collect::<BTreeSet<_>>();

        self.deauthorizable_resource_ids(portal)
            .into_iter()
            .filter(|resource| authorized.contains(resource))
            .collect()
    }

    /// The ICMP flows whose state the Gateway and the peers still hold.
    pub(crate) fn icmp_flows(&self, now: Instant) -> Vec<(FlowId, Seq)> {
        self.icmp_flows
            .iter()
            .filter(|(_, flow)| is_held(flow.last_round_trip, now))
            .map(|(id, flow)| (*id, flow.next_seq))
            .collect()
    }

    /// The UDP flows whose state the Gateway and the peers still hold.
    pub(crate) fn udp_flows(&self, now: Instant) -> Vec<FlowId> {
        self.udp_flows
            .iter()
            .filter(|(_, flow)| is_held(flow.last_round_trip, now))
            .map(|(id, _)| *id)
            .collect()
    }

    /// The ICMP flows whose state the Gateway and the peers dropped, which a new flow can resume.
    pub(crate) fn expired_icmp_flows(&self, now: Instant) -> Vec<&IcmpFlow> {
        self.icmp_flows
            .values()
            .filter(|flow| has_expired(flow.last_round_trip, now))
            .filter(|flow| self.can_send(flow.client_id, flow.src, &flow.dst))
            .collect()
    }

    /// The UDP flows whose state the Gateway and the peers dropped, which a new flow can resume.
    pub(crate) fn expired_udp_flows(&self, now: Instant) -> Vec<&UdpFlow> {
        self.udp_flows
            .values()
            .filter(|flow| has_expired(flow.last_round_trip, now))
            .filter(|flow| self.can_send(flow.client_id, flow.src, &flow.dst))
            .collect()
    }

    /// Whether the client still sends from `src` and knows where `dst` points.
    fn can_send(&self, client_id: ClientId, src: IpAddr, dst: &Destination) -> bool {
        let client = self.clients[&client_id].inner();
        let resolved_domains = match src {
            IpAddr::V4(ip) if ip == client.tunnel_ip4 => client.resolved_v4_domains(),
            IpAddr::V6(ip) if ip == client.tunnel_ip6 => client.resolved_v6_domains(),
            IpAddr::V4(_) | IpAddr::V6(_) => return false,
        };

        match dst {
            Destination::DomainName { name, .. } => {
                resolved_domains.iter().any(|(domain, _)| domain == name)
            }
            Destination::IpAddr(_) => true,
        }
    }

    pub(crate) fn ipv4_cidr_resource_dsts(&self) -> Vec<(ClientId, Ipv4Network, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .ipv4_cidr_resource_dsts()
                    .into_iter()
                    .map(|(ip, filters)| (*id, ip, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_v4_domains(&self) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_v4_domains()
                    .into_iter()
                    .map(|(domain, filters)| (*id, domain, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_ip4_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
    ) -> Vec<(ClientId, Ipv4Addr)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_ip4_for_non_resources(global_dns_records)
                    .into_iter()
                    .map(|ip| (*id, ip))
            })
            .collect()
    }

    pub(crate) fn ipv6_cidr_resource_dsts(&self) -> Vec<(ClientId, Ipv6Network, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .ipv6_cidr_resource_dsts()
                    .into_iter()
                    .map(|(ip, filters)| (*id, ip, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_v6_domains(&self) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_v6_domains()
                    .into_iter()
                    .map(|(domain, filters)| (*id, domain, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_ip6_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
    ) -> Vec<(ClientId, Ipv6Addr)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_ip6_for_non_resources(global_dns_records)
                    .into_iter()
                    .map(|ip| (*id, ip))
            })
            .collect()
    }

    pub(crate) fn dns_resource_domains(&self) -> Vec<DomainName> {
        // We may have multiple gateways in a site, so we need to dedup.
        let unique_domains = self
            .gateways
            .values()
            .flat_map(|gateway| gateway.inner().dns_records().domains_iter())
            .chain(self.global_dns_records.domains_iter())
            .chain(
                self.clients
                    .values()
                    .flat_map(|client| client.inner().dns_records.keys().cloned()),
            )
            .filter(|domain| {
                self.clients.values().any(|client| {
                    client
                        .inner()
                        .dns_resource_by_domain(domain, |_| true, |_| true)
                        .is_some()
                })
            })
            .collect::<BTreeSet<_>>();

        Vec::from_iter(unique_domains)
    }

    pub(crate) fn reachable_dns_servers(
        &self,
        portal: &StubPortal,
    ) -> Vec<(ClientId, dns::Upstream)> {
        let upstream_do53 = portal.upstream_do53();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                client
                    .inner()
                    .expected_dns_servers(portal.upstream_do53(), portal.upstream_doh())
                    .into_iter()
                    .filter(|s| match s {
                        tunnel_proto::dns::Upstream::Do53 {
                            server: SocketAddr::V4(_),
                        } => client.ip4.is_some(),
                        tunnel_proto::dns::Upstream::Do53 {
                            server: SocketAddr::V6(_),
                        } => client.ip6.is_some(),
                        tunnel_proto::dns::Upstream::DoH { .. } => true,
                    })
                    .filter(|server| {
                        if upstream_do53.is_empty() {
                            return true;
                        }

                        client
                            .inner()
                            .upstream_dns_server_via_resource(server)
                            .is_none_or(|resource| portal.site_for_resource(resource).is_some())
                    })
                    .map(move |server| (*client_id, server))
            })
            .collect()
    }

    pub(crate) fn all_domains(&self) -> Vec<(ClientId, DomainName, Vec<RecordType>)> {
        fn domains_and_rtypes(
            records: &DnsRecords,
        ) -> impl Iterator<Item = (DomainName, Vec<RecordType>)> {
            records
                .domains_iter()
                .map(move |d| (d.clone(), records.domain_rtypes(&d).into_iter().collect()))
        }

        self.clients
            .iter()
            .flat_map(move |(client_id, client)| {
                // Get domains from all gateways that this client can reach
                let mut unique_domains = iter::empty()
                    .chain(
                        self.gateways
                            .values()
                            .flat_map(|g| domains_and_rtypes(g.inner().dns_records())),
                    )
                    .chain(domains_and_rtypes(&self.global_dns_records))
                    .collect::<BTreeMap<_, _>>();

                // Add domains from client's own dns_records
                for (domain, rtypes) in &client.inner().dns_records {
                    unique_domains
                        .entry(domain.clone())
                        .or_default()
                        .extend(rtypes.iter().copied());
                }

                unique_domains
                    .into_iter()
                    .filter(|(_, rtypes)| !rtypes.is_empty())
                    .map(move |(domain, rtypes)| (*client_id, domain, rtypes))
            })
            .collect()
    }

    pub(crate) fn resources_unknown_to_all_clients(
        &self,
        portal: &StubPortal,
    ) -> Vec<client::Resource> {
        portal
            .all_resources()
            .into_iter()
            .filter(|resource| {
                self.clients
                    .values()
                    .all(|client| !client.inner().has_resource(resource.id()))
            })
            .collect()
    }

    pub(crate) fn editable_resources_on_any_client(
        &self,
        portal: &StubPortal,
    ) -> Vec<client::Resource> {
        portal
            .all_resources()
            .into_iter()
            .filter(|resource| {
                let is_editable = match resource {
                    client::Resource::Cidr(_) => true,
                    client::Resource::Dns(_) => true,
                    client::Resource::DevicePool(_) => true,
                    client::Resource::Internet(_) => false,
                };

                is_editable
                    && self
                        .clients
                        .values()
                        .any(|client| client.inner().has_resource(resource.id()))
            })
            .collect()
    }

    pub(crate) fn dns_resources_on_any_client(
        &self,
        portal: &StubPortal,
    ) -> Vec<(ClientId, client::DnsResource)> {
        let dns_resources = portal
            .all_resources()
            .into_iter()
            .filter_map(|r| match r {
                client::Resource::Dns(r) => Some(r),
                client::Resource::Cidr(_) => None,
                client::Resource::Internet(_) => None,
                client::Resource::DevicePool(_) => None,
            })
            .collect::<Vec<_>>();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                dns_resources
                    .iter()
                    .filter(|r| client.inner().has_resource(r.id))
                    .map(move |r| (*client_id, r.clone()))
            })
            .collect()
    }

    pub(crate) fn connected_gateway_ipv4_ips(&self) -> Vec<(ClientId, Ipv4Network)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .connected_resources()
                    .filter_map(|r| {
                        let gateway = client.inner().gateway_for_resource(r)?;
                        let gateway_host = self.gateways.get(&gateway)?;

                        Some((*id, gateway_host.inner().tunnel_ip4.into()))
                    })
                    .unique()
            })
            .collect()
    }

    pub(crate) fn connected_gateway_ipv6_ips(&self) -> Vec<(ClientId, Ipv6Network)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .connected_resources()
                    .filter_map(|r| {
                        let gateway = client.inner().gateway_for_resource(r)?;
                        let gateway_host = self.gateways.get(&gateway)?;

                        Some((*id, gateway_host.inner().tunnel_ip6.into()))
                    })
                    .unique()
            })
            .collect()
    }

    pub(crate) fn all_client_ids(&self) -> Vec<ClientId> {
        self.clients.keys().copied().collect()
    }

    /// Returns every listed pool that some client holds.
    pub(crate) fn listed_device_pool_ids_on_any_client(
        &self,
        portal: &StubPortal,
    ) -> Vec<ResourceId> {
        portal
            .listed_pool_ids()
            .into_iter()
            .filter(|pool| self.clients.values().any(|c| c.inner().has_resource(*pool)))
            .collect()
    }

    /// Generates `(src_client_id, dst_ip)` tuples for both tunnel IP families of every online
    /// client `src_client_id` may reach through a device pool it holds, paired with the
    /// pool filters that authorize the route.
    pub(crate) fn pool_routed_other_client_tun_ips(
        &self,
        portal: &StubPortal,
    ) -> Vec<(ClientId, IpAddr, Vec<Filter>)> {
        let online_ips_by_id = self
            .clients
            .iter()
            .map(|(id, c)| {
                let inner = c.inner();
                (
                    *id,
                    (IpAddr::V4(inner.tunnel_ip4), IpAddr::V6(inner.tunnel_ip6)),
                )
            })
            .collect::<BTreeMap<_, _>>();

        self.clients
            .iter()
            .flat_map(|(src_id, src_client)| {
                let src_id = *src_id;
                let online_ips_by_id = &online_ips_by_id;

                src_client
                    .inner()
                    .all_resources()
                    .into_iter()
                    .filter_map(|r| match r {
                        client::Resource::DevicePool(p) => Some((p.id, p.filters)),
                        client::Resource::Dns(_) => None,
                        client::Resource::Cidr(_) => None,
                        client::Resource::Internet(_) => None,
                    })
                    .filter(|(_, filters)| pool_filters_allow_icmp_or_udp(filters))
                    .flat_map(move |(pool, filters)| {
                        portal
                            .pool_members(pool)
                            .into_iter()
                            .filter(move |member| *member != src_id)
                            .filter_map(move |member| online_ips_by_id.get(&member).copied())
                            .flat_map(|(v4, v6)| [v4, v6])
                            .map(move |ip| (src_id, ip, filters.clone()))
                    })
            })
            .collect()
    }
}

fn pool_filters_allow_icmp_or_udp(filters: &[Filter]) -> bool {
    filters.is_empty()
        || filters.iter().any(|filter| match filter {
            Filter::Icmp => true,
            Filter::Udp(_) => true,
            Filter::Tcp(_) => false,
        })
}

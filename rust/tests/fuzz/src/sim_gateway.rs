use super::{
    dns_records::DnsRecords,
    dns_server_resource::DnsServers,
    probe::{ProbeId, ProbeObservation, ReceivedRequest, Remote},
    sim_net::{ExecMutScope, Host},
    sim_relay::{SimRelay, map_explode},
    site_network::SiteNetwork,
    sut::encrypt,
};
use anyhow::Result;
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId};
use dns_types::DomainName;
use ip_packet::IpPacket;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet},
    iter, mem,
    net::{IpAddr, SocketAddr},
    time::Instant,
};
use tunnel_proto::GatewayState;

/// Simulation state for a particular client.
pub(crate) struct SimGateway {
    id: GatewayId,
    pub(crate) sut: GatewayState,

    pub(crate) probe_observations: Vec<ProbeObservation>,

    dns_resolutions: BTreeMap<(ClientId, DomainName), Vec<DnsResolution>>,
    dns_nat_generations: BTreeMap<ClientId, u64>,
    dns_proxy_owners: BTreeMap<(ClientId, IpAddr), DomainName>,
    next_observation_order: u64,

    authorized_resources: BTreeMap<ClientId, BTreeSet<ResourceId>>,
    clients_by_ip: BTreeMap<IpAddr, ClientId>,

    site_specific_dns_records: DnsRecords,
    /// The DNS servers on the Gateway's tunnel IPs.
    dns_servers: DnsServers,
    network: SiteNetwork,
}

#[derive(Debug, Clone)]
pub(crate) struct DnsResolution {
    pub(crate) at: Instant,
    pub(crate) order: u64,
    pub(crate) dns_nat_generation: u64,
    proxy_ips: Vec<IpAddr>,
    pub(crate) addresses: Vec<IpAddr>,
}

impl SimGateway {
    pub(crate) fn new(
        id: GatewayId,
        mut sut: GatewayState,
        network: SiteNetwork,
        site_specific_dns_records: DnsRecords,
    ) -> Self {
        sut.set_flow_logs_enabled(true);

        Self {
            id,
            sut,
            site_specific_dns_records,
            probe_observations: Default::default(),
            dns_servers: Default::default(),
            network,
            dns_resolutions: Default::default(),
            dns_nat_generations: Default::default(),
            dns_proxy_owners: Default::default(),
            next_observation_order: 0,
            authorized_resources: Default::default(),
            clients_by_ip: Default::default(),
        }
    }

    pub(crate) fn receive(&mut self, transmit: Transmit, now: Instant) -> Option<Transmit> {
        let (local, from) = (transmit.dst, transmit.src.unwrap());
        let Some(packet) = self
            .sut
            .handle_network_input(local, from, &transmit.payload, now)
            .and_then(|decapsulation| {
                let Some(decapsulation) = decapsulation else {
                    return Ok(None);
                };

                self.sut.handle_peer_input(
                    local,
                    from,
                    decapsulation.decrypt(&transmit.payload),
                    now,
                )
            })
            .inspect_err(|e| tracing::warn!("{e:#}"))
            .ok()
            .flatten()
        else {
            self.sut.handle_timeout(now);
            return None;
        };

        self.on_received_packet(packet, now)
    }

    pub(crate) fn advance_resources(
        &mut self,
        global_dns_records: &DnsRecords,
        now: Instant,
    ) -> Vec<Transmit> {
        let packets = iter::empty()
            .chain(
                self.dns_servers
                    .poll_answers(&self.site_specific_dns_records, now),
            )
            .chain(self.network.poll_dns_answers(global_dns_records, now))
            .chain(self.network.poll_tcp_servers(now))
            .collect::<Vec<_>>();

        packets
            .into_iter()
            .filter_map(|packet| match self.handle_tun_input(packet, now) {
                Ok(maybe_transmit) => maybe_transmit,
                // The gateway could not encrypt the packet (e.g. no session during a re-key). In
                // production this error bubbles up to the event loop and the packet is dropped;
                // model that as a drop here rather than panicking.
                Err(e) => {
                    tracing::debug!("Gateway failed to encapsulate resource packet: {e:#}");
                    None
                }
            })
            .collect()
    }

    /// Drive the SUT's TUN -> network path, returning the encrypted datagram (if any).
    fn handle_tun_input(
        &mut self,
        mut packet: IpPacket,
        now: Instant,
    ) -> Result<Option<snownet::Transmit>> {
        let Some(encapsulation) = self.sut.handle_tun_input(&mut packet, now)? else {
            return Ok(None);
        };

        Ok(encrypt(encapsulation, &packet))
    }

    pub(crate) fn deploy_new_dns_servers(
        &mut self,
        dns_servers: impl IntoIterator<Item = SocketAddr>,
    ) {
        self.network.deploy_dns_servers(dns_servers);
        self.dns_servers.clear();

        let tun_dns_server_port = 53535; // Hardcoded here so we think about backwards-compatibility when changing it.
        let Some(ip_config) = self.sut.tunnel_ip_config() else {
            tracing::error!("Tunnel IP configuration not set");
            return;
        };

        self.dns_servers
            .deploy(SocketAddr::from((ip_config.v4, tun_dns_server_port)));
        self.dns_servers
            .deploy(SocketAddr::from((ip_config.v6, tun_dns_server_port)));
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        if self.sut.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.sut.handle_timeout(now)
        }
    }

    /// Process an IP packet received on the gateway.
    fn on_received_packet(&mut self, packet: IpPacket, now: Instant) -> Option<Transmit> {
        if let Some(server) = self.dns_servers.udp_server_for(&packet) {
            server.handle_input(packet);
            return None;
        }

        if let Some(server) = self.dns_servers.tcp_server_for(&packet) {
            server.handle_input(packet, now);
            return None;
        }

        let dns_resolutions = &self.dns_resolutions;
        let delivery = self.network.deliver(
            packet.clone(),
            |domain, ip| resolved_to(dns_resolutions, domain, ip),
            now,
        );
        if delivery.request_received {
            self.record_received_request(packet, now);
        }

        self.handle_tun_input(delivery.reply?, now).unwrap()
    }

    pub(crate) fn update_relays<'a>(
        &mut self,
        to_remove: impl Iterator<Item = RelayId>,
        to_add: impl Iterator<Item = (&'a RelayId, &'a Host<SimRelay>)> + 'a,
        now: Instant,
    ) {
        self.sut.update_relays(
            to_remove.collect(),
            map_explode(to_add, format!("gateway_{}", self.id)).collect(),
            now,
        )
    }

    fn record_received_tcp_syn(&mut self, packet: &IpPacket, now: Instant) {
        let retransmitted = self.probe_observations.iter().any(|observation| {
            observation.as_received_request().is_some_and(|received| {
                received.id.is_none() && tcp_tuple(&received.packet) == tcp_tuple(packet)
            })
        });
        if retransmitted {
            return;
        }

        self.push_received_request(None, packet.clone(), now);
    }

    pub(crate) fn clear_probe_observations(&mut self) {
        self.probe_observations.clear();
    }

    pub(crate) fn drop_unfinished_tcp_connections(&mut self) {
        self.network.drop_unfinished_tcp_connections();
    }

    pub(crate) fn record_dns_resolution(
        &mut self,
        client: ClientId,
        domain: DomainName,
        proxy_ips: Vec<IpAddr>,
        addresses: Vec<IpAddr>,
        at: Instant,
    ) {
        let proxies_were_reassigned = proxy_ips.iter().any(|proxy_ip| {
            self.dns_proxy_owners
                .get(&(client, *proxy_ip))
                .is_some_and(|owner| owner != &domain)
        });
        if proxies_were_reassigned {
            self.start_new_dns_nat_generation(client);
        }

        for proxy_ip in &proxy_ips {
            self.dns_proxy_owners
                .insert((client, *proxy_ip), domain.clone());
        }

        let dns_nat_generation = self.dns_nat_generation(client);
        let resolution = DnsResolution {
            at,
            order: self.next_observation_order(),
            dns_nat_generation,
            proxy_ips,
            addresses,
        };

        self.dns_resolutions
            .entry((client, domain))
            .or_default()
            .push(resolution);
    }

    pub(crate) fn dns_resolution_before(
        &self,
        client: ClientId,
        domain: &DomainName,
        at: Instant,
        order: u64,
        dns_nat_generation: u64,
        proxy_ip: IpAddr,
    ) -> Option<&DnsResolution> {
        self.dns_resolutions(client, domain, dns_nat_generation, proxy_ip)
            .filter(|resolution| (resolution.at, resolution.order) < (at, order))
            .max_by_key(|resolution| (resolution.at, resolution.order))
    }

    pub(crate) fn dns_resolutions(
        &self,
        client: ClientId,
        domain: &DomainName,
        dns_nat_generation: u64,
        proxy_ip: IpAddr,
    ) -> impl Iterator<Item = &DnsResolution> {
        self.dns_resolutions
            .get(&(client, domain.clone()))
            .into_iter()
            .flatten()
            .filter(move |resolution| resolution.dns_nat_generation == dns_nat_generation)
            .filter(move |resolution| resolution.proxy_ips.contains(&proxy_ip))
    }

    pub(crate) fn record_authorization(
        &mut self,
        client: ClientId,
        resource: ResourceId,
        client_ips: [IpAddr; 2],
    ) {
        self.authorized_resources
            .entry(client)
            .or_default()
            .insert(resource);
        self.clients_by_ip.extend(client_ips.map(|ip| (ip, client)));
    }

    pub(crate) fn remove_access(&mut self, client: &ClientId, resource: &ResourceId, now: Instant) {
        self.sut.remove_access(client, resource, now);
        self.record_resource_disabled(*client, *resource);
    }

    pub(crate) fn record_resource_disabled(&mut self, client: ClientId, resource: ResourceId) {
        let Some(resources) = self.authorized_resources.get_mut(&client) else {
            return;
        };
        resources.remove(&resource);

        if !resources.is_empty() {
            return;
        }

        self.authorized_resources.remove(&client);
        self.record_peer_removed(client);
    }

    pub(crate) fn record_client_restart(&mut self, client: ClientId) {
        if self.authorized_resources.remove(&client).is_none() {
            return;
        }

        self.record_peer_removed(client);
    }

    pub(crate) fn retain_authorizations(
        &mut self,
        authorizations: BTreeMap<ClientId, BTreeSet<ResourceId>>,
    ) {
        let previous = mem::take(&mut self.authorized_resources);
        self.authorized_resources = previous
            .iter()
            .filter_map(|(client, resources)| {
                let retained = authorizations.get(client);
                let resources = BTreeSet::from_iter(
                    resources
                        .iter()
                        .filter(|resource| retained.is_some_and(|set| set.contains(resource)))
                        .copied(),
                );

                (!resources.is_empty()).then_some((*client, resources))
            })
            .collect();
        let removed_clients = previous
            .keys()
            .filter(|client| !self.authorized_resources.contains_key(client))
            .copied()
            .collect::<Vec<_>>();

        for client in removed_clients {
            self.record_peer_removed(client);
        }

        self.sut.retain_authorizations(authorizations);
    }

    fn record_received_request(&mut self, packet: IpPacket, at: Instant) {
        if packet.as_tcp().is_some() {
            self.record_received_tcp_syn(&packet, at);
            return;
        }

        let payload = packet
            .as_udp()
            .map(|udp| udp.payload())
            .or_else(|| packet.as_icmpv4().map(|icmp| icmp.payload()))
            .or_else(|| packet.as_icmpv6().map(|icmp| icmp.payload()));
        let Some(id) = payload.and_then(ProbeId::from_payload) else {
            tracing::error!("Probe payload does not contain a probe ID");
            return;
        };

        self.push_received_request(Some(id), packet, at);
    }

    fn push_received_request(&mut self, id: Option<ProbeId>, packet: IpPacket, at: Instant) {
        let gateway_order = Some(self.next_observation_order());
        let dns_nat_generation = self
            .clients_by_ip
            .get(&packet.source())
            .map(|client| self.dns_nat_generation(*client));

        self.probe_observations
            .push(ProbeObservation::RequestReceived(ReceivedRequest {
                id,
                at,
                remote: Remote::Gateway(self.id),
                gateway_order,
                dns_nat_generation,
                packet,
            }));
    }

    pub(crate) fn dns_nat_generation(&self, client: ClientId) -> u64 {
        self.dns_nat_generations
            .get(&client)
            .copied()
            .unwrap_or_default()
    }

    fn start_new_dns_nat_generation(&mut self, client: ClientId) {
        let generation = self.dns_nat_generation(client) + 1;
        self.dns_nat_generations.insert(client, generation);
        for _ in self
            .dns_proxy_owners
            .extract_if(.., |(owner, _), _| *owner == client)
        {}
    }

    fn record_peer_removed(&mut self, client: ClientId) {
        for _ in self
            .clients_by_ip
            .extract_if(.., |_, owner| *owner == client)
        {}
        self.start_new_dns_nat_generation(client);
    }

    fn next_observation_order(&mut self) -> u64 {
        let order = self.next_observation_order;
        self.next_observation_order += 1;

        order
    }
}

impl ExecMutScope for SimGateway {
    type Guard = ();

    fn enter(&self) -> Self::Guard {}
}

fn resolved_to(
    dns_resolutions: &BTreeMap<(ClientId, DomainName), Vec<DnsResolution>>,
    domain: &DomainName,
    ip: IpAddr,
) -> bool {
    dns_resolutions
        .iter()
        .filter(|((_, resolved), _)| resolved == domain)
        .flat_map(|(_, resolutions)| resolutions)
        .any(|resolution| resolution.addresses.contains(&ip))
}

fn tcp_tuple(packet: &IpPacket) -> Option<(IpAddr, u16, IpAddr, u16)> {
    let tcp = packet.as_tcp()?;

    Some((
        packet.source(),
        tcp.source_port(),
        packet.destination(),
        tcp.destination_port(),
    ))
}

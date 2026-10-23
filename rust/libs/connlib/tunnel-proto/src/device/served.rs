//! The half of a device that serves resources to its peers.
//!
//! A device the portal assigns to a site answers for that site's resources:
//! peers open connections to it, it admits their packets through
//! [`PeerInbound`] and forwards them to the resource, and it translates the
//! resource's replies back. This is what a gateway always did; a device that
//! routes resources does it alongside its own, outbound half.

use std::collections::BTreeSet;
use std::net::IpAddr;

use ip_network_table::IpNetworkTable;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context as _, ErrorExt as _, Result};
use connlib_model::{ClientId, RelayId, ResourceId};
use dns_types::DomainName;
use ip_packet::{FzP2pControlSlice, IpPacket};
use secrecy::ExposeSecret as _;
use snownet::{IceConfig, Node};
use zeroize::Zeroizing;

use crate::messages::gateway::{Client, ResourceDescription};
use crate::messages::{IceCredentials, IceRole, IngestToken, Interface, ResolveRequest};
use crate::peer_inbound::PeerInbound;
use crate::peer_store::PeerStore;
use crate::unroutable_packet::UnroutablePacket;
use crate::{ClientEvent, IpConfig, p2p_control};

use super::{DeviceState, encapsulate_and_queue};

/// How often a serving device sweeps its NAT and expired authorizations.
///
/// The sweep is only scheduled while a peer is served something.
pub(super) const SERVING_TICK: Duration = Duration::from_secs(1);

/// The addresses a served DNS resource's domain resolved to, for its NAT.
#[derive(Debug)]
pub struct DnsResourceNatEntry {
    domain: DomainName,
    proxy_ips: Vec<IpAddr>,
    resolved_ips: Vec<IpAddr>,
}

impl DnsResourceNatEntry {
    pub fn new(request: ResolveRequest, resolved_ips: Vec<IpAddr>) -> Self {
        Self {
            domain: request.name,
            proxy_ips: request.proxy_ips,
            resolved_ips,
        }
    }
}

/// The addresses of the CIDR resources the device's sites serve.
///
/// A peer authorized for the Internet resource must not reach into one of
/// them without being authorized for it: the Internet catch-all stops at
/// the resources the device serves, whichever site they belong to.
pub(crate) struct LocalResources {
    networks: IpNetworkTable<ResourceId>,
}

impl Default for LocalResources {
    fn default() -> Self {
        Self {
            networks: IpNetworkTable::new(),
        }
    }
}

impl LocalResources {
    fn set(&mut self, resources: impl IntoIterator<Item = ResourceDescription>) {
        self.networks = IpNetworkTable::new();

        for resource in resources {
            self.upsert(resource);
        }
    }

    fn upsert(&mut self, resource: ResourceDescription) {
        self.remove(resource.id());

        if let ResourceDescription::Cidr(cidr) = resource {
            self.networks.insert(cidr.address, cidr.id);
        }
    }

    fn remove(&mut self, id: ResourceId) {
        let stale = self
            .networks
            .iter()
            .filter(|(_, rid)| **rid == id)
            .map(|(network, _)| network)
            .collect::<Vec<_>>();

        for network in stale {
            self.networks.remove(network);
        }
    }

    pub(crate) fn contains(&self, ip: IpAddr) -> bool {
        self.networks.longest_match(ip).is_some()
    }
}

/// Opaque request struct for when a domain name needs to be resolved.
#[derive(Debug)]
pub struct ResolveDnsRequest {
    domain: DomainName,
    client: ClientId,
    resource: ResourceId,
    proxy_ips: Vec<IpAddr>,
}

impl ResolveDnsRequest {
    pub fn domain(&self) -> &DomainName {
        &self.domain
    }

    pub fn client(&self) -> ClientId {
        self.client
    }

    pub fn proxy_ips(&self) -> &[IpAddr] {
        &self.proxy_ips
    }
}

impl DeviceState {
    /// Replaces the list of resources the device's sites serve.
    pub fn set_local_resources(&mut self, resources: Vec<ResourceDescription>) {
        self.local_resources.set(resources);
    }

    pub fn upsert_local_resource(&mut self, resource: ResourceDescription) {
        self.local_resources.upsert(resource);
    }

    pub fn remove_local_resource(&mut self, id: ResourceId) {
        self.local_resources.remove(id);
    }

    /// Sets the tunnel addresses of a device that is only ever served.
    ///
    /// A device that is also a client learns them, with its DNS settings,
    /// from [`DeviceState::update_interface_config`].
    pub fn update_tun_device(&mut self, config: IpConfig) {
        self.update_interface_config(Interface {
            ipv4: config.v4,
            ipv6: config.v6,
            upstream_dns: Vec::new(),
            upstream_do53: Vec::new(),
            upstream_doh: Vec::new(),
            search_domain: None,
        });
    }

    /// Accepts a connection from `client` so it can reach `resource` through us.
    #[tracing::instrument(level = "debug", skip_all, fields(cid = %client.id))]
    pub fn create_authorization(
        &mut self,
        client: Client,
        client_ice: IceCredentials,
        local_ice: IceCredentials,
        expires_at: Option<Duration>,
        resource: ResourceDescription,
        use_iceless: bool,
        ice_role: IceRole,
        now: Instant,
        flow_logs_ingest_token: IngestToken,
    ) {
        self.node.upsert_connection(
            client.id,
            client.public_key.into(),
            sanstun::StaticSecret::from(Zeroizing::new(client.preshared_key.expose_secret().0)),
            local_ice.into(),
            client_ice.into(),
            ice_role.into(),
            IceConfig::server_default(),
            IceConfig::server_idle(),
            use_iceless,
            now,
        );

        let result = self.allow_access(
            client.id,
            IpConfig {
                v4: client.ipv4,
                v6: client.ipv6,
            },
            flow_logs_ingest_token,
            expires_at,
            resource,
            None,
            now,
        );
        debug_assert!(
            result.is_ok(),
            "`allow_access` should never fail without a `DnsResourceEntry`"
        );
    }

    pub fn allow_access(
        &mut self,
        client: ClientId,
        client_tun: IpConfig,
        flow_logs_ingest_token: IngestToken,
        expires_at: Option<Duration>,
        resource: ResourceDescription,
        dns_resource_nat: Option<DnsResourceNatEntry>,
        now: Instant,
    ) -> Result<()> {
        let local_tun = self
            .tunnel_ip_config()
            .context("TUN device not configured")?;

        let expires_at = expires_at.map(|d| self.unix_ts_clock.instant_at(d, now));
        let expires_in = expires_at.map(|e| e.saturating_duration_since(now));

        tracing::info!(
            cid = %client,
            rid = %resource.id(),
            expires_in = expires_in.map(tracing::field::debug),
            "Allowing access to resource",
        );

        let peer = self.clients.upsert(client, || {
            PeerInbound::new(client, client_tun, local_tun, String::new(), String::new())
        });

        peer.add_resource(resource.clone(), expires_at, now);
        peer.set_ingest_token(resource.id(), flow_logs_ingest_token);

        if let Some(entry) = dns_resource_nat {
            peer.setup_nat(
                entry.domain,
                resource.id(),
                BTreeSet::from_iter(entry.resolved_ips),
                BTreeSet::from_iter(entry.proxy_ips),
            )?;
        }

        self.next_serving_tick.get_or_insert(now + SERVING_TICK);

        Ok(())
    }

    /// Withdraws `rid` from `cid`, closing the connection once nothing is left on it.
    #[tracing::instrument(level = "debug", skip_all, fields(%rid, %cid))]
    pub fn remove_access(&mut self, cid: &ClientId, rid: &ResourceId, now: Instant) {
        let Some(peer) = self.clients.peer_by_id_mut(cid) else {
            return;
        };

        peer.revoke(rid);
        self.close_idle_served_peers(now);

        tracing::debug!("Access removed");
    }

    /// Applies a changed description of a resource we serve.
    pub fn update_served_resource(&mut self, resource: ResourceDescription) {
        for peer in self.clients.iter_mut() {
            peer.update_resource(&resource);
        }
    }

    pub fn handle_domain_resolved(
        &mut self,
        req: ResolveDnsRequest,
        resolve_result: Result<Vec<IpAddr>, Arc<anyhow::Error>>,
        now: Instant,
    ) -> Result<()> {
        use p2p_control::dns_resource_nat;

        let nat_status = resolve_result
            .and_then(|addresses| {
                self.clients
                    .peer_by_id_mut(&req.client)
                    .context("Unknown peer")?
                    .setup_nat(
                        req.domain.clone(),
                        req.resource,
                        BTreeSet::from_iter(addresses),
                        BTreeSet::from_iter(req.proxy_ips),
                    )?;

                Ok(dns_resource_nat::NatStatus::Active)
            })
            .unwrap_or_else(|e| {
                tracing::warn!("Failed to setup DNS resource NAT: {e:#}");

                dns_resource_nat::NatStatus::Inactive
            });

        let packet = dns_resource_nat::domain_status(req.resource, req.domain, nat_status)?;

        encapsulate_and_queue(
            packet,
            req.client,
            now,
            &mut self.node,
            &mut self.buffered_transmits,
            &mut self.pending_peer_packets,
        );

        Ok(())
    }

    /// Closes the connection to every peer we served and now serve nothing.
    ///
    /// A peer we hold an outbound authorization for stays: we may still be the
    /// one sending to it.
    pub(super) fn close_idle_served_peers(&mut self, now: Instant) {
        let idle = self
            .clients
            .iter()
            .filter(|peer| peer.was_served() && peer.is_empty())
            .map(|peer| peer.id())
            .filter(|id| !self.outbound_authorizations.is_client_authorized(*id))
            .collect::<Vec<_>>();

        for id in idle {
            tracing::debug!(cid = %id, "Access to last served resource removed");

            self.cleanup_connected_client(&id);
            self.node.close_connection(id, p2p_control::goodbye(), now);
        }
    }

    /// Whether any peer is served something, so the serving sweep must run.
    pub(super) fn is_serving(&self) -> bool {
        self.clients.iter().any(|peer| peer.serves())
    }

    /// A peer told us the proxy addresses it assigned to a domain of a served DNS resource.
    ///
    /// Returns the immediate reply for the peer, if any; otherwise the domain is
    /// resolved through a [`ClientEvent::ResolveDns`] first.
    pub(super) fn handle_assigned_ips(
        &mut self,
        fz_p2p_control: FzP2pControlSlice,
        cid: ClientId,
    ) -> Result<Option<IpPacket>> {
        use p2p_control::dns_resource_nat;

        let peer = self
            .clients
            .peer_by_id(&cid)
            .with_context(|| format!("No peer for connection {cid}"))?;

        let req = dns_resource_nat::decode_assigned_ips(fz_p2p_control)
            .context("Failed to decode `AssignedIps`")?;

        if !peer.is_allowed(req.resource) {
            tracing::warn!(%cid, rid = %req.resource, domain = %req.domain, "Received `AssignedIpsEvent` for resource that is not allowed");

            let packet = dns_resource_nat::domain_status(
                req.resource,
                req.domain,
                dns_resource_nat::NatStatus::Inactive,
            )
            .context("Failed to create `DomainStatus` packet")?;

            return Ok(Some(packet));
        }

        self.buffered_events
            .push_back(ClientEvent::ResolveDns(ResolveDnsRequest {
                domain: req.domain,
                client: cid,
                resource: req.resource,
                proxy_ips: req.proxy_ips,
            }));

        Ok(None)
    }
}

/// Sends a packet from a resource we serve, or from this device, back to the peer.
///
/// The packet is translated into the peer's view of the resource. Nothing is
/// buffered: a served flow only ever answers the peer, so a packet that finds
/// no established connection is dropped.
///
/// Takes the fields it needs so the caller can keep its flow guard.
pub(super) fn reply_to_served_peer(
    clients: &mut PeerStore<ClientId, PeerInbound>,
    node: &mut Node<ClientId, RelayId>,
    cid: ClientId,
    packet: &mut IpPacket,
    now: Instant,
) -> Result<Option<snownet::PendingEncapsulate>> {
    flow_tracker::record_peer(cid, flow_tracker::Role::Responder);

    clients
        .peer_by_id_mut(&cid)
        .with_context(|| UnroutablePacket::no_peer_state(packet))?
        .translate_inbound(packet, now)
        .context("Failed to translate inbound packet")?;

    let Some(encapsulation) = encapsulate_or_drop(packet, cid, node, now)? else {
        return Ok(None);
    };

    flow_tracker::record_transmit(encapsulation.src(), encapsulation.dst());

    Ok(Some(encapsulation))
}

/// The peer we serve at `dst`, if any.
pub(super) fn served_peer_by_ip(
    clients: &PeerStore<ClientId, PeerInbound>,
    dst: IpAddr,
) -> Option<ClientId> {
    let (cid, peer) = clients.peer_by_ip(dst)?;

    peer.serves().then_some(cid)
}

fn encapsulate_or_drop(
    packet: &IpPacket,
    cid: ClientId,
    node: &mut Node<ClientId, RelayId>,
    now: Instant,
) -> Result<Option<snownet::PendingEncapsulate>> {
    match node.encapsulate(cid, packet, now) {
        Ok(encapsulation) => Ok(encapsulation),
        Err(e) if e.any_is::<snownet::StillConnecting>() => {
            tracing::debug!(%cid, "Connection is still establishing; dropping packet");
            Ok(None)
        }
        Err(e) if e.any_is::<snownet::UnknownConnection>() => {
            Err(e.context(UnroutablePacket::not_connected(packet)))
        }
        Err(e) => Err(e).context("Failed to encapsulate"),
    }
}

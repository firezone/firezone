//! The half of a device that serves resources to its peers.
//!
//! Peers open connections to a device that serves a site. The device admits
//! their packets through [`PeerInbound`], forwards them to the resources it
//! serves and translates the replies back. This is what a Gateway does; a
//! device does it next to reaching resources itself.

use std::collections::BTreeSet;
use std::iter;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context as _, ErrorExt as _, Result};
use connlib_model::{DeviceId, PublicKey, RelayId, ResourceId};
use dns_types::{DomainName, Query, Response, ResponseBuilder, ResponseCode};
use ip_packet::{FzP2pControlSlice, IpPacket};
use secrecy::ExposeSecret as _;
use snownet::{IceConfig, IceRole, Node};
use zeroize::Zeroizing;

use super::DeviceState;
use super::peer_batch::{self, Decision};
use crate::batch::{BatchingKey, TunBatch};
use crate::messages::client::ResourceAuthorization;
use crate::messages::gateway::{Client, ResourceDescription};
use crate::messages::{self, IceCredentials, IngestToken, Interface, Key, SecretKey, device};
use crate::p2p_control::dns_resource_nat::ProxyIps;
use crate::peer_inbound::{
    InboundRewrite, PeerIdentity, PeerInbound, ProxyIpAlreadyAssigned, TooManyDnsDomains,
    TooManyProxyIpsForDomain, TranslateOutboundResult,
};
use crate::unroutable_packet::UnroutablePacket;
use crate::{DeviceEvent, IpConfig, p2p_control};

/// How often a serving device sweeps its flows, NAT sessions and expired authorizations.
///
/// The sweep only runs while the device serves a peer.
pub(super) const SERVING_TICK: Duration = Duration::from_secs(1);

pub struct SiteDnsQuery {
    local: SocketAddr,
    remote: SocketAddr,
    message: Query,
    transport: crate::dns::Transport,
}

impl SiteDnsQuery {
    pub fn into_parts(self) -> (SocketAddr, SocketAddr, Query, crate::dns::Transport) {
        (self.local, self.remote, self.message, self.transport)
    }
}

/// Opaque request struct for when a domain name needs to be resolved.
#[derive(Debug)]
pub struct ResolveDnsRequest {
    domain: DomainName,
    client_public_key: PublicKey,
    resource: ResourceId,
    proxy_ips: ProxyIps,
}

impl ResolveDnsRequest {
    pub fn domain(&self) -> &DomainName {
        &self.domain
    }

    pub fn client_public_key(&self) -> PublicKey {
        self.client_public_key
    }

    pub fn proxy_ips(&self) -> &ProxyIps {
        &self.proxy_ips
    }
}

impl DeviceState {
    /// Sets how many domains of DNS resources we translate at most for each new peer.
    pub fn set_max_dns_domains_per_client(&mut self, max: usize) {
        self.max_dns_domains_per_client = max;
    }

    /// Sets the tunnel addresses of a device that only serves.
    ///
    /// A device that also reaches resources learns them, with its DNS settings,
    /// through [`DeviceState::update_interface_config`].
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

    pub fn handle_site_dns_query(
        &self,
        local: SocketAddr,
        remote: SocketAddr,
        message: Query,
        transport: crate::dns::Transport,
    ) -> Result<SiteDnsQuery, Response> {
        let allowed = self
            .peers
            .peer_by_ip(remote.ip())
            .is_some_and(|(_, peer)| peer.resources().allows_site_dns_query(&message));

        if !allowed {
            return Err(ResponseBuilder::for_query(&message, ResponseCode::REFUSED).build());
        }

        Ok(SiteDnsQuery {
            local,
            remote,
            message,
            transport,
        })
    }

    /// The portal asks us to accept a connection from a peer, see [`device::AuthorizePeer`].
    ///
    /// Once this returns, the authorization is installed and the portal may release the peer.
    #[tracing::instrument(level = "debug", skip_all, fields(peer = %authorize.peer.id))]
    pub fn handle_authorize_peer(
        &mut self,
        authorize: device::AuthorizePeer,
        now: Instant,
    ) -> Result<device::AuthorizationRef> {
        let device::AuthorizePeer {
            reference,
            peer,
            target,
            local_ice_credentials,
            remote_ice_credentials,
            connection,
            expires_at,
            flow_logs_ingest_token,
        } = authorize;
        let (ice_role, use_frostlink) =
            super::connection_params(connection, messages::IceRole::Controlled);
        let peer_tun = IpConfig {
            v4: peer.ipv4,
            v6: peer.ipv6,
        };

        match target {
            device::ServedTarget::Resource { resource } => {
                self.accept_served_peer(
                    peer.id,
                    peer.public_key,
                    &peer.preshared_key,
                    local_ice_credentials,
                    remote_ice_credentials,
                    ice_role.into(),
                    use_frostlink,
                    now,
                );

                let served = self.serve(
                    peer.id,
                    peer.public_key,
                    peer_tun,
                    flow_logs_ingest_token,
                    expires_at,
                    resource,
                    now,
                )?;
                served.set_identity(PeerIdentity {
                    name: peer.name,
                    slug: peer.slug,
                });
            }
            device::ServedTarget::Device { pool_id, filters } => {
                self.handle_client_device_access_authorized(
                    peer.id,
                    PublicKey::from(peer.public_key.0),
                    peer_tun,
                    peer.preshared_key,
                    local_ice_credentials,
                    remote_ice_credentials,
                    ice_role,
                    use_frostlink,
                    peer.name,
                    peer.slug,
                    None,
                    Some(ResourceAuthorization {
                        resource_id: pool_id,
                        filters,
                        expires_at,
                    }),
                    flow_logs_ingest_token,
                    now,
                );
            }
        }

        Ok(reference)
    }

    /// Accepts a connection from `client` so it can reach `resource` through us.
    #[tracing::instrument(level = "debug", skip_all, fields(cid = %client.id))]
    pub fn create_authorization(
        &mut self,
        client: Client,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        expires_at: Option<Duration>,
        resource: ResourceDescription,
        use_frostlink: bool,
        now: Instant,
        flow_logs_ingest_token: IngestToken,
    ) {
        self.accept_served_peer(
            client.id,
            client.public_key,
            &client.preshared_key,
            gateway_ice,
            client_ice,
            IceRole::Controlled,
            use_frostlink,
            now,
        );

        let result = self.allow_access(&client, flow_logs_ingest_token, expires_at, resource, now);
        debug_assert!(result.is_ok(), "`allow_access` should never fail");
    }

    /// Sets up the connection from a peer we serve.
    ///
    /// A peer that reconnected with a new key starts over: its previous state is forgotten.
    fn accept_served_peer(
        &mut self,
        id: DeviceId,
        public_key: Key,
        preshared_key: &SecretKey,
        local_ice: IceCredentials,
        remote_ice: IceCredentials,
        ice_role: IceRole,
        use_frostlink: bool,
        now: Instant,
    ) {
        if self
            .peers
            .peer_by_id(&id)
            .is_some_and(|peer| peer.public_key() != public_key)
        {
            tracing::debug!("Peer reconnected with a new key; clearing its previous state");

            self.peers.remove(&id);
        }

        self.node.upsert_connection(
            id,
            public_key.into(),
            sanstun::StaticSecret::from(Zeroizing::new(preshared_key.expose_secret().0)),
            local_ice.into(),
            remote_ice.into(),
            ice_role,
            IceConfig::server_default(),
            IceConfig::server_idle(),
            use_frostlink,
            now,
        );
    }

    pub fn allow_access(
        &mut self,
        client: &Client,
        flow_logs_ingest_token: IngestToken,
        expires_at: Option<Duration>,
        resource: ResourceDescription,
        now: Instant,
    ) -> Result<()> {
        self.serve(
            client.id,
            client.public_key,
            IpConfig {
                v4: client.ipv4,
                v6: client.ipv6,
            },
            flow_logs_ingest_token,
            expires_at,
            resource,
            now,
        )?;

        Ok(())
    }

    /// Allows the peer `id` to reach `resource` through us.
    fn serve(
        &mut self,
        id: DeviceId,
        public_key: Key,
        peer_tun: IpConfig,
        flow_logs_ingest_token: IngestToken,
        expires_at: Option<Duration>,
        resource: ResourceDescription,
        now: Instant,
    ) -> Result<&mut PeerInbound> {
        let local_tun = self
            .tunnel_ip_config()
            .context("TUN device not configured")?;

        let expires_at = expires_at.map(|d| self.unix_ts_clock.instant_at(d, now));
        let expires_in = expires_at.map(|e| e.saturating_duration_since(now));

        tracing::info!(
            cid = %id,
            rid = %resource.id(),
            expires_in = expires_in.map(tracing::field::debug),
            "Allowing access to resource",
        );

        self.next_serving_tick.get_or_insert(now + SERVING_TICK);

        let max_dns_domains = self.max_dns_domains_per_client;
        let peer = self.peers.upsert(id, || {
            PeerInbound::new(id, public_key, peer_tun, local_tun, max_dns_domains)
        });

        let resources = peer.resources_mut();
        resources.add_resource(resource.clone(), expires_at, now);
        resources.set_ingest_token(resource.id(), flow_logs_ingest_token);

        Ok(peer)
    }

    /// Withdraws `rid` from `cid`, closing the connection once the peer may reach nothing through us.
    #[tracing::instrument(level = "debug", skip_all, fields(%rid, %cid))]
    pub fn remove_access(&mut self, cid: &DeviceId, rid: &ResourceId, now: Instant) {
        let Some(peer) = self.peers.peer_by_id_mut(cid) else {
            return;
        };

        peer.resources_mut().remove_resource(rid);
        tracing::debug!("Access removed");

        if !peer.is_empty() {
            return;
        }

        self.peers.remove(cid);

        // The connection also carries what the peer serves us.
        if self.gateways.peer_by_id(cid).is_some() {
            return;
        }

        self.node
            .close_connection(*cid, p2p_control::goodbye(), now);
    }

    /// Applies the changed description of a resource we serve.
    pub fn update_served_resource(&mut self, resource: ResourceDescription) {
        for peer in self.peers.iter_mut() {
            peer.resources_mut().update_resource(&resource);
        }
    }

    /// Sets the resources we serve, revoking every authorization for a resource we no longer serve.
    pub fn set_served_resources(&mut self, resources: Vec<ResourceDescription>, now: Instant) {
        let served = resources
            .iter()
            .map(ResourceDescription::id)
            .collect::<BTreeSet<_>>();

        for resource in resources {
            self.update_served_resource(resource);
        }

        let unserved = self
            .peers
            .iter()
            .flat_map(|peer| {
                peer.resources()
                    .resource_ids()
                    .filter(|rid| !served.contains(rid))
                    .map(|rid| (peer.id(), rid))
            })
            .collect::<Vec<_>>();

        for (cid, rid) in unserved {
            self.remove_access(&cid, &rid, now);
        }
    }

    /// We stopped serving `rid`: no peer may reach it through us any more.
    pub fn remove_served_resource(&mut self, rid: ResourceId, now: Instant) {
        let peers = self
            .peers
            .iter()
            .filter(|peer| peer.resources().is_allowed(rid))
            .map(PeerInbound::id)
            .collect::<Vec<_>>();

        for cid in peers {
            self.remove_access(&cid, &rid, now);
        }
    }

    /// Ends the authorization of `cid` to reach `rid` through us, whichever kind of target it is.
    pub fn deauthorize_peer(&mut self, cid: DeviceId, rid: ResourceId, now: Instant) {
        if let Some(peer) = self.peers.peer_by_id_mut(&cid) {
            peer.self_targets_mut().remove_resource(&rid);
        }

        self.remove_access(&cid, &rid, now);
    }

    pub fn handle_domain_resolved(
        &mut self,
        req: ResolveDnsRequest,
        resolve_result: Result<Vec<IpAddr>, Arc<anyhow::Error>>,
        now: Instant,
    ) -> Result<()> {
        use p2p_control::dns_resource_nat;

        let Some(client) = self.node.connection_id(req.client_public_key, now) else {
            tracing::debug!("Ignoring DNS resolution for a disconnected Client");

            return Ok(());
        };

        let result = resolve_result.and_then(|addresses| {
            let evicted = self
                .peers
                .peer_by_id_mut(&client)
                .context("Unknown peer")?
                .resources_mut()
                .setup_nat(
                    req.domain.clone(),
                    req.resource,
                    BTreeSet::from_iter(addresses),
                    req.proxy_ips,
                    now,
                )?;

            Ok(evicted)
        });

        let (nat_status, evicted) = match result {
            Ok(evicted) => (dns_resource_nat::NatStatus::Active, evicted),
            Err(e)
                if e.any_is::<ProxyIpAlreadyAssigned>()
                    || e.any_is::<TooManyProxyIpsForDomain>() =>
            {
                tracing::debug!("Conflicting proxy assignment; closing connection: {e:#}");
                self.peers.remove(&client);
                self.node
                    .close_connection(client, p2p_control::goodbye(), now);

                return Ok(());
            }
            Err(e) if e.any_is::<TooManyDnsDomains>() => {
                tracing::debug!(domain = %req.domain, "Not setting up DNS resource NAT: {e:#}");

                (dns_resource_nat::NatStatus::Inactive, None)
            }
            Err(e) => {
                tracing::warn!("Failed to setup DNS resource NAT: {e:#}");

                (dns_resource_nat::NatStatus::Inactive, None)
            }
        };

        let evicted_statuses = evicted.into_iter().flat_map(|evicted| {
            evicted.resources.into_iter().map(move |rid| {
                (
                    rid,
                    evicted.domain.clone(),
                    dns_resource_nat::NatStatus::Evicted,
                )
            })
        });

        for (rid, domain, status) in
            iter::once((req.resource, req.domain, nat_status)).chain(evicted_statuses)
        {
            let packet = dns_resource_nat::domain_status(rid, domain, status)?;

            if let Some(transmit) = encrypt_packet(packet, client, &mut self.node, now)? {
                self.buffered_transmits.push_back(transmit);
            }
        }

        Ok(())
    }

    /// Whether `packet` from the TUN device is a reply to a peer we serve.
    ///
    /// Replies from a served resource carry the resource's address. Replies from
    /// the DNS server we run for served peers carry our own tunnel address and
    /// the port of that server. Everything else from our own tunnel address is
    /// traffic of this device.
    pub(super) fn is_served_reply(&self, packet: &IpPacket) -> bool {
        let Some((_, peer)) = self.peers.peer_by_ip(packet.destination()) else {
            return false;
        };

        if peer.resources().is_empty() {
            return false;
        }

        let Some(local_tun) = self.tunnel_ip_config() else {
            return false;
        };

        if !local_tun.is_ip(packet.source()) {
            return true;
        }

        packet
            .source_protocol()
            .is_ok_and(|protocol| protocol.value() == crate::TUN_DNS_PORT)
    }

    /// Handles a reply from a served resource on its way back to the peer.
    pub(super) fn handle_served_tun_input(
        &mut self,
        mut packet: IpPacket,
        now: Instant,
    ) -> Result<Option<TunBatch<'_, (DeviceId, Option<ResourceId>)>>> {
        let flow = self.flow_tracker.begin_tun_packet(&packet, now);

        let key = BatchingKey::of(&packet);
        let dst = packet.destination();

        anyhow::ensure!(crate::is_peer(dst), UnroutablePacket::not_a_peer(&packet));

        let (cid, peer) = self
            .peers
            .peer_by_ip_mut(dst)
            .with_context(|| UnroutablePacket::no_peer_state(&packet))?;

        flow_tracker::record_peer(cid, flow_tracker::Role::Responder);

        let (key, nat) = match peer.resources_mut().translate_inbound(&mut packet, now) {
            Ok(InboundRewrite::None) => (key, None),
            Ok(InboundRewrite::Source(proto, ip)) => (key, Some((proto, ip))),
            Ok(InboundRewrite::IcmpError) => (None, None),
            Err(e) => return Err(e.context("Failed to translate inbound packet")),
        };

        let Some(tunnel) = encapsulate(&packet, cid, &mut self.node, now)? else {
            return Ok(None);
        };

        flow_tracker::record_transmit(tunnel.src(), tunnel.dst());

        Ok(Some(TunBatch::new(key, nat, tunnel, flow, packet)))
    }

    /// Handles a packet a peer sent to a resource we serve, or to the DNS server we run for it.
    pub(super) fn handle_served_peer_message(
        &mut self,
        cid: DeviceId,
        packet: IpPacket,
        local: SocketAddr,
        from: SocketAddr,
        now: Instant,
    ) -> Result<peer_batch::Outcome> {
        let key = BatchingKey::of(&packet);
        let flow = self.flow_tracker.begin_network_packet(local, from, now);

        if packet.destination().is_multicast() {
            return Ok(peer_batch::Outcome::Consumed);
        }

        flow_tracker::record_decrypted_packet(&packet);

        let Some(peer) = self.peers.peer_by_id_mut(&cid) else {
            tracing::trace!(%cid, "No peer state for connection; closing connection");
            drop(flow);
            self.node.close_connection(cid, p2p_control::goodbye(), now);

            return Ok(peer_batch::Outcome::Consumed);
        };

        flow_tracker::record_peer(cid, flow_tracker::Role::Responder);

        let translated = match peer.resources_mut().translate_outbound(packet, now) {
            Ok(translated) => translated,
            Err(e) => return Err(e.context("Failed to translate outbound packet")),
        };

        match (translated, key) {
            (TranslateOutboundResult::Send(packet, rewrite), Some(key)) => {
                Ok(peer_batch::Outcome::Deliver(
                    packet,
                    Some(Decision {
                        key,
                        rewrite,
                        flow: flow.detach(),
                    }),
                ))
            }
            (TranslateOutboundResult::Send(packet, _), None) => {
                Ok(peer_batch::Outcome::Deliver(packet, None))
            }
            (
                TranslateOutboundResult::IcmpError {
                    reply,
                    no_authorization,
                },
                _,
            ) => {
                flow_tracker::record_icmp_error(&reply);

                if let Some(transmit) = encrypt_packet(reply, cid, &mut self.node, now)? {
                    self.buffered_transmits.push_back(transmit);
                }

                if let Some(event) = no_authorization.and_then(|rejection| {
                    self.authorization_rejections
                        .on_rejected(cid, rejection, now)
                }) && let Some(transmit) = encrypt_packet(event, cid, &mut self.node, now)?
                {
                    self.buffered_transmits.push_back(transmit);
                }

                Ok(peer_batch::Outcome::Consumed)
            }
        }
    }

    /// A peer told us the proxy addresses it assigned to a domain of a DNS resource we serve.
    pub(super) fn handle_assigned_ips(
        &mut self,
        fz_p2p_control: FzP2pControlSlice,
        cid: DeviceId,
        now: Instant,
    ) -> Result<()> {
        let Some(peer) = self.peers.peer_by_id(&cid) else {
            tracing::debug!(%cid, "Ignoring `AssignedIps` from a peer we do not serve");

            return Ok(());
        };

        let Some(response) =
            handle_assigned_ips_event(fz_p2p_control, peer, &mut self.buffered_events)
        else {
            return Ok(());
        };

        if let Some(transmit) = encrypt_packet(response, cid, &mut self.node, now)? {
            self.buffered_transmits.push_back(transmit);
        }

        Ok(())
    }

    /// Whether we serve any peer, so the serving sweep must run.
    pub(super) fn is_serving(&self) -> bool {
        self.peers.iter().any(|peer| !peer.resources().is_empty())
    }

    /// Runs the serving sweep and closes the connections of served peers that may reach nothing any more.
    pub(super) fn handle_serving_timeout(&mut self, now: Instant) {
        let Some(tick) = self.next_serving_tick else {
            return;
        };

        if tick > now {
            return;
        }

        let empty = self
            .peers
            .due_mut(now)
            .filter_map(|(id, peer)| {
                let was_served = !peer.resources().is_empty();

                peer.handle_timeout(now);

                (was_served && peer.is_empty()).then_some(id)
            })
            .collect::<Vec<_>>();
        self.peers.reindex();

        for id in empty {
            self.peers.remove(&id);
            tracing::debug!(cid = %id, "Access to last resource for Client removed");

            self.node.close_connection(id, p2p_control::goodbye(), now);
        }

        self.next_serving_tick = self.is_serving().then_some(now + SERVING_TICK);
    }
}

fn handle_assigned_ips_event(
    fz_p2p_control: FzP2pControlSlice,
    peer: &PeerInbound,
    buffered_events: &mut std::collections::VecDeque<DeviceEvent>,
) -> Option<IpPacket> {
    use p2p_control::dns_resource_nat;

    let Ok(req) = dns_resource_nat::decode_assigned_ips(fz_p2p_control)
        .inspect_err(|e| tracing::debug!("{e:#}"))
    else {
        return None;
    };

    if !peer.resources().is_allowed(req.resource) {
        tracing::warn!(cid = %peer.id(), rid = %req.resource, domain = %req.domain, "Received `AssignedIpsEvent` for resource that is not allowed");

        return inactive_domain_status(req.resource, req.domain);
    }

    let Some(proxy_ips) = req.proxy_ips else {
        tracing::debug!(cid = %peer.id(), rid = %req.resource, domain = %req.domain, "Received `AssignedIpsEvent` with invalid proxy IPs");

        return inactive_domain_status(req.resource, req.domain);
    };

    buffered_events.push_back(DeviceEvent::ResolveDns(ResolveDnsRequest {
        domain: req.domain,
        client_public_key: peer.public_key().into(),
        resource: req.resource,
        proxy_ips,
    }));

    None
}

fn inactive_domain_status(resource: ResourceId, domain: DomainName) -> Option<IpPacket> {
    p2p_control::dns_resource_nat::domain_status(
        resource,
        domain,
        p2p_control::dns_resource_nat::NatStatus::Inactive,
    )
    .inspect_err(|e| tracing::warn!("Failed to create `DomainStatus` packet: {e:#}"))
    .ok()
}

fn encrypt_packet(
    packet: IpPacket,
    cid: DeviceId,
    node: &mut Node<DeviceId, RelayId>,
    now: Instant,
) -> Result<Option<snownet::Transmit>> {
    let Some(batch) = encapsulate(&packet, cid, node, now)? else {
        return Ok(None);
    };

    Ok(Some(batch.encrypt_single(&packet)?))
}

/// Encapsulates a packet for a peer we serve.
///
/// Nothing is buffered: we only ever answer a served peer, so a packet that
/// finds no established connection is dropped.
fn encapsulate<'n>(
    packet: &IpPacket,
    cid: DeviceId,
    node: &'n mut Node<DeviceId, RelayId>,
    now: Instant,
) -> Result<Option<snownet::EncapsulateBatch<'n>>> {
    match node.encapsulate(cid, packet, now) {
        Ok(batch) => Ok(batch),
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

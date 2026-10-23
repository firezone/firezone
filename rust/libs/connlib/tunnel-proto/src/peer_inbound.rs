//! What this device admits from one peer.

pub(crate) mod nat_table;
mod resource_targets;
mod self_targets;

use std::collections::BTreeSet;
use std::net::IpAddr;
use std::time::Instant;

use anyhow::Result;
use connlib_model::{DeviceId, ResourceId};
use dns_types::DomainName;
use ip_packet::IpPacket;

use crate::conn_track::Originator;
use crate::device::LocalResources;
use crate::messages::gateway::ResourceDescription;
use crate::messages::{Filter, IngestToken};
use crate::{IpConfig, p2p_control};

pub(crate) use resource_targets::ResourceTargets;
pub(crate) use self_targets::SelfTargets;

/// The targets one peer is authorized to send to through this device.
///
/// A peer that opened a connection to us may be reaching the device itself,
/// through a device pool, or a resource the device serves, or both. The
/// portal authorizes each target separately and this type keeps them side
/// by side: `self_targets` holds the pools with their filters, `resources`
/// the served resources with their routing table and NAT. A packet from the
/// peer is classified once, in [`PeerInbound::translate_outbound`].
pub(crate) struct PeerInbound {
    id: DeviceId,
    /// The peer's tunnel addresses, the only sources it may send from.
    peer_tun: IpConfig,
    /// Our tunnel addresses.
    local_tun: IpConfig,
    remote_name: String,
    remote_slug: String,

    self_targets: SelfTargets,
    resources: ResourceTargets,
    /// Whether the peer was ever served a resource, so its connection is ours to close.
    was_served: bool,
}

/// The decision for a packet the peer sent through the tunnel.
#[derive(Debug, PartialEq)]
pub(crate) enum TranslateOutboundResult {
    /// Forward the packet to the TUN device.
    Send(IpPacket),
    /// Drop the packet and send the ICMP error back to the peer.
    IcmpError {
        reply: IpPacket,
        /// Identifies traffic rejected by the access policy, so the peer
        /// can ask the portal for the authorization it lacks.
        no_authorization: Option<p2p_control::no_authorization::NoAuthorization>,
    },
}

impl PeerInbound {
    pub(crate) fn new(
        id: DeviceId,
        peer_tun: IpConfig,
        local_tun: IpConfig,
        remote_name: String,
        remote_slug: String,
    ) -> Self {
        Self {
            id,
            peer_tun,
            local_tun,
            remote_name,
            remote_slug,
            self_targets: SelfTargets::new(id, local_tun, peer_tun),
            resources: ResourceTargets::new(id, peer_tun, local_tun),
            was_served: false,
        }
    }

    pub(crate) fn id(&self) -> DeviceId {
        self.id
    }

    pub(crate) fn peer_tun(&self) -> IpConfig {
        self.peer_tun
    }

    pub(crate) fn remote_name(&self) -> &str {
        &self.remote_name
    }

    pub(crate) fn remote_slug(&self) -> &str {
        &self.remote_slug
    }

    pub(crate) fn set_remote_identity(&mut self, name: String, slug: String) {
        self.remote_name = name;
        self.remote_slug = slug;
    }

    /// Whether the peer is authorized for nothing, so its connection can go.
    pub(crate) fn is_empty(&self) -> bool {
        self.self_targets.is_empty() && self.resources.is_empty()
    }

    pub(crate) fn poll_timeout(&self) -> Option<Instant> {
        self.self_targets.poll_timeout()
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.self_targets.handle_timeout(now);
        self.resources.handle_timeout(now);
    }

    /// Whether the peer is currently served a resource.
    pub(crate) fn serves(&self) -> bool {
        !self.resources.is_empty()
    }

    /// Whether the peer was served a resource at some point.
    pub(crate) fn was_served(&self) -> bool {
        self.was_served
    }

    ////////////////////////////////////////
    // The device itself, through pools  //
    ////////////////////////////////////////

    /// Allows the peer to reach this device through `pool`, limited by `filters`.
    pub(crate) fn add_self_target(
        &mut self,
        pool: ResourceId,
        filters: Vec<Filter>,
        expires_at: Option<Instant>,
        ingest_token: IngestToken,
        now: Instant,
    ) {
        self.self_targets
            .add_target(pool, filters, expires_at, ingest_token, now);
    }

    /// The pools through which the peer may reach this device.
    pub(crate) fn self_target_ids(&self) -> impl Iterator<Item = ResourceId> + '_ {
        self.self_targets.target_ids()
    }

    pub(crate) fn update_self_target_filters(&mut self, pool: ResourceId, filters: Vec<Filter>) {
        self.self_targets.update_target_filters(pool, filters);
    }

    /// Records or refreshes a flow we opened to the peer so its replies are admitted.
    pub(crate) fn record_outbound_as_originator(&mut self, packet: &IpPacket, now: Instant) {
        self.self_targets.record_outbound_as_originator(packet, now);
    }

    /// Who opened the flow this outbound packet belongs to, if it is tracked.
    pub(crate) fn outbound_flow_originator(&self, packet: &IpPacket) -> Option<Originator> {
        self.self_targets.outbound_flow_originator(packet)
    }

    /// Whether an ICMP error we are about to send refers to a flow with this peer.
    pub(crate) fn is_known_outbound_error(&self, packet: &IpPacket) -> bool {
        self.self_targets.is_known_outbound_error(packet)
    }

    ////////////////////////////////////////
    // Resources the device serves       //
    ////////////////////////////////////////

    /// Allows the peer to reach `resource` through this device.
    pub(crate) fn add_resource(
        &mut self,
        resource: ResourceDescription,
        expires_at: Option<Instant>,
        now: Instant,
    ) {
        self.resources.add_resource(resource, expires_at, now);
        self.was_served = true;
    }

    /// Records the portal's per-flow ingest token for a served resource.
    pub(crate) fn set_ingest_token(&mut self, rid: ResourceId, token: IngestToken) {
        self.resources.set_ingest_token(rid, token);
    }

    pub(crate) fn update_resource(&mut self, new_description: &ResourceDescription) {
        self.resources.update_resource(new_description);
    }

    /// Whether the peer may reach `resource` through this device.
    pub(crate) fn is_allowed(&self, resource: ResourceId) -> bool {
        self.resources.is_allowed(resource)
    }

    pub(crate) fn setup_nat(
        &mut self,
        name: DomainName,
        resource_id: ResourceId,
        resolved_ips: BTreeSet<IpAddr>,
        proxy_ips: BTreeSet<IpAddr>,
    ) -> Result<()> {
        self.resources
            .setup_nat(name, resource_id, resolved_ips, proxy_ips)
    }

    /// Translates a packet from a served resource back to the peer.
    pub(crate) fn translate_inbound(&mut self, packet: &mut IpPacket, now: Instant) -> Result<()> {
        self.resources.translate_inbound(packet, now)
    }

    ////////////////////////////////////////
    // Both                               //
    ////////////////////////////////////////

    /// Drops the authorization for `resource_id`, whichever kind of target it was.
    pub(crate) fn revoke(&mut self, resource_id: &ResourceId) {
        self.self_targets.remove_target(resource_id);
        self.resources.remove_resource(resource_id);
    }

    /// Drops every authorization not in `retain`.
    pub(crate) fn retain(&mut self, retain: &BTreeSet<ResourceId>) {
        self.self_targets.retain_targets(retain);
        self.resources.retain_authorizations(retain.clone());
    }

    /// Updates when the authorization for `resource_id` expires.
    pub(crate) fn update_expiry(
        &mut self,
        resource_id: ResourceId,
        new_expiry: Instant,
        now: Instant,
    ) {
        self.self_targets
            .update_target_expiry(resource_id, new_expiry, now);
        self.resources
            .update_resource_expiry(resource_id, new_expiry, now);
    }

    /// Classifies a packet the peer sent us and decides where it goes.
    ///
    /// The device itself is reached through its pools, with their filters.
    /// A peer that is served resources may also ask the DNS server the device
    /// runs on its tunnel addresses for them. Everything else is a resource,
    /// admitted by the routing table of what the peer is authorized for; the
    /// Internet resource stops at the resources the device serves (`local`),
    /// and other devices' tunnel addresses are never forwarded.
    pub(crate) fn translate_outbound(
        &mut self,
        packet: IpPacket,
        local: &LocalResources,
        now: Instant,
    ) -> Result<TranslateOutboundResult> {
        let dst = packet.destination();

        if self.local_tun.is_ip(dst) {
            if self.serves() && is_tun_dns_query(&packet) {
                // The peer opened the query to the DNS server we run for it.
                flow_tracker::record_peer(self.id, flow_tracker::Role::Responder);

                return self.resources.translate_outbound(packet, now);
            }

            return self.self_targets.translate_outbound(packet, now);
        }

        if !self.serves() {
            return self.self_targets.translate_outbound(packet, now);
        }

        // A flow to a resource we serve is always the peer's.
        flow_tracker::record_peer(self.id, flow_tracker::Role::Responder);

        if local.contains(dst)
            && !self
                .resources
                .is_authorized_resource(dst, packet.destination_protocol())
        {
            tracing::debug!(%dst, "Peer is not authorized for the served resource it sends to");

            let no_authorization = packet.destination_protocol().ok().map(|protocol| {
                p2p_control::no_authorization::NoAuthorization {
                    dst,
                    protocol: protocol.into(),
                }
            });

            return Ok(TranslateOutboundResult::IcmpError {
                reply: ip_packet::make::icmp_dest_unreachable_prohibited(&packet)?,
                no_authorization,
            });
        }

        self.resources.translate_outbound(packet, now)
    }
}

/// Whether the packet queries the DNS server a serving device runs on its tunnel addresses.
fn is_tun_dns_query(packet: &IpPacket) -> bool {
    packet
        .destination_protocol()
        .is_ok_and(|protocol| match protocol {
            ip_packet::Protocol::Udp(port) | ip_packet::Protocol::Tcp(port) => {
                port == crate::TUN_DNS_PORT
            }
            ip_packet::Protocol::IcmpEcho(_) => false,
        })
}

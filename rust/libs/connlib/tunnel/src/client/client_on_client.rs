use crate::IpConfig;
use crate::conn_track::ConnTrack;
use crate::expiring_map::{ExpiringMap, NEVER_EXPIRES_TTL};
use crate::filter_engine::FilterEngine;
use crate::messages::Filter;
use anyhow::{Context, Result};
use connlib_model::{ClientId, ResourceId};
use ip_packet::IpPacket;
use smallvec::SmallVec;
use std::collections::BTreeSet;
use std::time::Instant;

/// Peer-level state of a connection with another Client.
///
/// Contrary to peer-level state of a connection with a Gateway,
/// we need to track two different things here:
///
/// 1. Traffic filters of resources that give the _remote_ Client access to our TUN device.
/// 2. Outbound layer-4 connections so we can allow return traffic back in.
///
/// Doing both of these ensures that event Clients which have access to each other via
/// different device pools can only access what they have been granted access to.
/// Most importantly, accessing another client does not allow any inbound traffic that
/// isn't the return traffic of packets that we have sent.
pub(crate) struct ClientOnClient {
    id: ClientId,
    remote_tun: IpConfig,
    remote_name: String,
    /// Inbound resources authorising the remote peer to send packets to us.
    ///
    /// When this map is empty, no inbound traffic from this peer is admitted
    /// unless it matches a recorded outbound flow (return traffic).
    resources: ExpiringMap<ResourceId, ResourceOnClient>,
    /// Cached OR of every resource's filters; recomputed whenever `resources` changes.
    inbound_filter: FilterEngine,
    /// Tracks outbound flows so legitimate return traffic is admitted.
    conn_track: ConnTrack,
}

/// An inbound resource: filters granted by a resource for traffic from the remote peer.
#[derive(Debug)]
struct ResourceOnClient {
    filters: Vec<Filter>,
}

/// The decision after applying inbound filters and the connection tracker.
pub(crate) enum InboundResult {
    /// Forward the packet to the TUN.
    Send(IpPacket),
    /// Drop the original packet and send the included ICMP destination
    /// unreachable (prohibited) reply back to the peer.
    Filtered(IpPacket),
}

impl ClientOnClient {
    pub(crate) fn new(id: ClientId, remote_tun: IpConfig, remote_name: String) -> ClientOnClient {
        ClientOnClient {
            id,
            remote_tun,
            remote_name,
            resources: ExpiringMap::default(),
            // No resources -> no allowed inbound traffic by default.
            inbound_filter: FilterEngine::DenyAll,
            conn_track: ConnTrack::default(),
        }
    }

    pub(crate) fn id(&self) -> ClientId {
        self.id
    }

    pub(crate) fn remote_tun(&self) -> IpConfig {
        self.remote_tun
    }

    pub(crate) fn remote_name(&self) -> &str {
        &self.remote_name
    }

    pub(crate) fn set_remote_name(&mut self, name: String) {
        self.remote_name = name;
    }

    /// Allow the remote peer to send us packets associated with `resource_id` limited by the given filter set.
    ///
    /// If a resource with the same id is already tracked, its filters are replaced.
    /// The combined inbound filter is the OR across every active resource's filter set.
    pub(crate) fn add_resource(
        &mut self,
        resource_id: ResourceId,
        filters: Vec<Filter>,
        expires_at: Option<Instant>,
        now: Instant,
    ) {
        let expires_in = expires_at.map(|e| e.saturating_duration_since(now));

        tracing::info!(
            %resource_id,
            expires_in = expires_in.map(tracing::field::debug),
            "Allowing inbound access from peer",
        );

        let ttl = expires_in.unwrap_or(NEVER_EXPIRES_TTL);
        self.resources
            .insert(resource_id, ResourceOnClient { filters }, now, ttl);
        self.recompute_inbound_filter();
    }

    /// Drops every inbound authorization not present in `retain`.
    pub(crate) fn retain_authorizations(&mut self, retain: &BTreeSet<ResourceId>) {
        let mut any_removed = false;

        for (resource_id, _) in self.resources.extract_if(|rid, _| !retain.contains(rid)) {
            tracing::info!(%resource_id, "Revoking peer authorization on resync");
            any_removed = true;
        }

        if any_removed {
            self.recompute_inbound_filter();
        }
    }

    /// Updates when an existing inbound authorization expires.
    pub(crate) fn update_resource_expiry(
        &mut self,
        resource_id: ResourceId,
        new_expiry: Instant,
        now: Instant,
    ) {
        if !self
            .resources
            .update_expiry_at(&resource_id, new_expiry, now)
        {
            tracing::debug!(%resource_id, "Unknown resource");
        }
    }

    /// Replace the filters carried by an existing resource.
    pub(crate) fn update_resource(&mut self, resource_id: ResourceId, filters: Vec<Filter>) {
        let Some(resource) = self.resources.get_mut(&resource_id) else {
            tracing::debug!(%resource_id, "Unknown resource");
            return;
        };

        tracing::info!(%resource_id, ?filters, "Updated peer authorization filters");
        resource.filters = filters;
        self.recompute_inbound_filter();
    }

    /// Drop a previously-active resource.
    pub(crate) fn remove_resource(&mut self, resource_id: &ResourceId) {
        let Some(_entry) = self.resources.remove(resource_id) else {
            return;
        };

        tracing::info!(%resource_id, "Revoking peer authorization");
        self.recompute_inbound_filter();
    }

    fn recompute_inbound_filter(&mut self) {
        if self.resources.is_empty() {
            // No resources -> deny all (except return traffic).
            self.inbound_filter = FilterEngine::DenyAll;
            return;
        }

        // If a single resource has no filters, we automatically permit all traffic.
        if self.resources.values().any(|r| r.filters.is_empty()) {
            self.inbound_filter = FilterEngine::PermitAll;
            return;
        }

        let combined = self
            .resources
            .values()
            .flat_map(|r| r.filters.iter().cloned())
            .collect::<SmallVec<[_; 16]>>();

        self.inbound_filter = FilterEngine::new(&combined);
    }

    /// Handles an outbound packet we sent to this peer.
    pub(crate) fn handle_outbound(&mut self, packet: &IpPacket, now: Instant) {
        self.conn_track.handle_outbound(packet, now);
    }

    /// Returns the next instant at which one of this peer's inbound authorizations expires.
    pub(crate) fn poll_timeout(&self) -> Option<Instant> {
        self.resources.poll_timeout()
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.conn_track.handle_timeout(now);
        self.resources.handle_timeout(now);

        let mut any_expired = false;

        while let Some(event) = self.resources.poll_event() {
            match event {
                crate::expiring_map::Event::EntryExpired { key, .. } => {
                    tracing::info!(rid = %key, "Resource authorization expired, revoking");
                    any_expired = true;
                }
            }
        }

        if any_expired {
            self.recompute_inbound_filter();
        }
    }

    /// Returns `true` if the *outbound* packet is part of an existing flow
    /// with this peer (either initiated by us or in reply to inbound from
    /// the peer). Lets `route_packet` skip the per-(resource, peer) intent
    /// when the connection is already established.
    pub(crate) fn is_known_flow(&self, packet: &IpPacket) -> bool {
        self.conn_track.is_known_flow(packet)
    }

    /// Decide whether an inbound packet from this peer is admitted.
    pub(crate) fn ensure_allowed_inbound(
        &mut self,
        packet: IpPacket,
        local_tun: IpConfig,
        now: Instant,
    ) -> Result<InboundResult> {
        let src = packet.source();
        let dst = packet.destination();
        anyhow::ensure!(
            self.remote_tun.is_ip(src) && local_tun.is_ip(dst),
            "Dropping spoofed inbound packet from peer (src {src}, dst {dst})"
        );

        if packet.icmp_error().is_ok_and(|e| e.is_some()) {
            anyhow::ensure!(
                self.conn_track.is_known_flow(&packet),
                "Dropping ICMP error from peer referencing an unknown flow"
            );

            return Ok(InboundResult::Send(packet));
        }

        if self.conn_track.is_return_traffic(&packet) {
            return Ok(InboundResult::Send(packet));
        }

        if let Err(e) = self.inbound_filter.apply(packet.destination_protocol()) {
            tracing::debug!(filtered_packet = ?packet, "{e:#}");
            let reply = ip_packet::make::icmp_dest_unreachable_prohibited(&packet)
                .context("Failed to build ICMP prohibited reply")?;
            return Ok(InboundResult::Filtered(reply));
        }

        // The packet passed our filters, record as successful inbound packet.
        self.conn_track.record_inbound(&packet, now);
        Ok(InboundResult::Send(packet))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::messages::PortRange;
    use connlib_model::{ClientId, ResourceId};
    use ip_packet::make;
    use std::collections::BTreeSet;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
    use std::time::Duration;

    #[test]
    fn spoofed_source_is_rejected() {
        let now = Instant::now();
        let mut peer = peer();
        peer.add_resource(ResourceId::from_u128(1), vec![], None, now);

        let spoofed = make::udp_packet(
            IpAddr::V4(Ipv4Addr::new(100, 64, 0, 99)),
            our_v4(),
            40000,
            80,
            &[],
        )
        .unwrap();
        assert!(
            peer.ensure_allowed_inbound(spoofed, local_tun(), now)
                .is_err()
        );
    }

    #[test]
    fn spoofed_destination_is_rejected() {
        let now = Instant::now();
        let mut peer = peer();
        peer.add_resource(ResourceId::from_u128(1), vec![], None, now);

        let spoofed = make::udp_packet(
            peer_v4(),
            IpAddr::V4(Ipv4Addr::new(100, 64, 0, 99)),
            40000,
            80,
            &[],
        )
        .unwrap();
        assert!(
            peer.ensure_allowed_inbound(spoofed, local_tun(), now)
                .is_err()
        );
    }

    #[test]
    fn icmp_error_for_known_flow_is_forwarded() {
        let now = Instant::now();
        let mut peer = peer();

        let outbound = make::udp_packet(our_v4(), peer_v4(), 8080, 80, &[]).unwrap();
        peer.record_outbound(&outbound, now);
        let icmp = make::icmp_dest_unreachable_prohibited(&outbound).unwrap();

        assert!(is_send(
            peer.ensure_allowed_inbound(icmp, local_tun(), now).unwrap()
        ));
    }

    #[test]
    fn icmp_error_for_unknown_flow_is_rejected() {
        let now = Instant::now();
        let mut peer = peer();

        let stray = make::udp_packet(our_v4(), peer_v4(), 8080, 80, &[]).unwrap();
        let icmp = make::icmp_dest_unreachable_prohibited(&stray).unwrap();

        assert!(peer.ensure_allowed_inbound(icmp, local_tun(), now).is_err());
    }

    #[test]
    fn peer_opened_flow_is_re_filtered_after_revocation() {
        let now = Instant::now();
        let rid = ResourceId::from_u128(1);
        let mut peer = peer();
        peer.add_resource(rid, udp_port(80), None, now);

        assert!(is_send(
            peer.ensure_allowed_inbound(udp_to(80), local_tun(), now)
                .unwrap()
        ));

        peer.remove_resource(&rid);

        assert!(is_filtered(
            peer.ensure_allowed_inbound(udp_to(80), local_tun(), now)
                .unwrap()
        ));
    }

    #[test]
    fn our_reply_admitted_for_flow_we_opened_without_authorization() {
        let now = Instant::now();
        let mut peer = peer();

        let outbound = make::udp_packet(our_v4(), peer_v4(), 8080, 80, &[]).unwrap();
        peer.handle_outbound(&outbound, now);

        let reply = make::udp_packet(peer_v4(), our_v4(), 80, 8080, &[]).unwrap();
        assert!(is_send(
            peer.ensure_allowed_inbound(reply, local_tun(), now)
                .unwrap()
        ));
    }

    #[test]
    fn authorization_expires_and_is_enforced() {
        let now = Instant::now();
        let rid = ResourceId::from_u128(1);
        let mut peer = peer();
        peer.add_resource(rid, udp_port(80), Some(now + Duration::from_secs(60)), now);

        assert!(is_send(
            peer.ensure_allowed_inbound(udp_to(80), local_tun(), now)
                .unwrap()
        ));
        assert_eq!(peer.poll_timeout(), Some(now + Duration::from_secs(60)));

        let later = now + Duration::from_secs(61);
        peer.handle_timeout(later);

        assert_eq!(peer.poll_timeout(), None);
        assert!(is_filtered(
            peer.ensure_allowed_inbound(udp_to(80), local_tun(), later)
                .unwrap()
        ));
    }

    #[test]
    fn retain_authorizations_drops_absent_resources() {
        let now = Instant::now();
        let keep = ResourceId::from_u128(1);
        let drop = ResourceId::from_u128(2);
        let mut peer = peer();
        peer.add_resource(keep, udp_port(80), None, now);
        peer.add_resource(drop, udp_port(90), None, now);

        assert!(is_send(
            peer.ensure_allowed_inbound(udp_to(80), local_tun(), now)
                .unwrap()
        ));
        assert!(is_send(
            peer.ensure_allowed_inbound(udp_to(90), local_tun(), now)
                .unwrap()
        ));

        peer.retain_authorizations(&BTreeSet::from([keep]));

        assert!(is_send(
            peer.ensure_allowed_inbound(udp_to(80), local_tun(), now)
                .unwrap()
        ));
        assert!(is_filtered(
            peer.ensure_allowed_inbound(udp_to(90), local_tun(), now)
                .unwrap()
        ));
    }

    #[test]
    fn update_resource_expiry_in_the_past_evicts_on_timeout() {
        let now = Instant::now();
        let rid = ResourceId::from_u128(1);
        let mut peer = peer();
        peer.add_resource(rid, udp_port(80), Some(now + Duration::from_secs(600)), now);

        peer.update_resource_expiry(rid, now, now);
        peer.handle_timeout(now);

        assert!(is_filtered(
            peer.ensure_allowed_inbound(udp_to(80), local_tun(), now)
                .unwrap()
        ));
    }

    fn peer() -> ClientOnClient {
        ClientOnClient::new(ClientId::from_u128(1), peer_tun(), "peer".to_owned())
    }

    fn peer_tun() -> IpConfig {
        IpConfig {
            v4: Ipv4Addr::new(100, 64, 0, 2),
            v6: Ipv6Addr::new(0xfd, 0, 0, 0, 0, 0, 0, 2),
        }
    }

    fn local_tun() -> IpConfig {
        IpConfig {
            v4: Ipv4Addr::new(100, 64, 0, 1),
            v6: Ipv6Addr::new(0xfd, 0, 0, 0, 0, 0, 0, 1),
        }
    }

    fn our_v4() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1))
    }

    fn peer_v4() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 64, 0, 2))
    }

    fn udp_to(dport: u16) -> IpPacket {
        make::udp_packet(peer_v4(), our_v4(), 40000, dport, &[]).unwrap()
    }

    fn udp_port(port: u16) -> Vec<Filter> {
        vec![Filter::Udp(PortRange {
            port_range_start: port,
            port_range_end: port,
        })]
    }

    fn is_send(result: InboundResult) -> bool {
        matches!(result, InboundResult::Send(_))
    }

    fn is_filtered(result: InboundResult) -> bool {
        matches!(result, InboundResult::Filtered(_))
    }
}

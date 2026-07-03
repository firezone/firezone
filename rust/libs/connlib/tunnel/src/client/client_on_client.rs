use crate::IpConfig;
use crate::conn_track::{ConnTrack, Originator};
use crate::expiring_map::{ExpiringMap, NEVER_EXPIRES_TTL};
use crate::filter_engine::FilterEngine;
use crate::messages::Filter;
use anyhow::{Context, Result};
use connlib_model::ResourceId;
use ip_packet::IpPacket;
use smallvec::SmallVec;
use std::collections::HashMap;
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

    /// The portal's per-flow ingest token for each resource of this peer, used to
    /// attribute the client-to-client flow logs. Per resource: the initiator token
    /// when we access the resource on the peer, the responder token when the peer
    /// accesses it on us.
    ingest_tokens: HashMap<ResourceId, String>,
}

/// An inbound resource: filters granted by a resource for traffic from the remote peer.
#[derive(Debug)]
struct ResourceOnClient {
    filters: Vec<Filter>,
}

/// The decision after applying inbound filters and the connection tracker.
pub(crate) enum InboundResult {
    /// Forward the packet to the TUN.
    Send {
        packet: IpPacket,
        /// Who initiated the flow the packet belongs to; `None` when the
        /// tracker was not consulted (ICMP errors are always admitted).
        flow_originator: Option<Originator>,
    },
    /// Drop the original packet and send the included ICMP destination
    /// unreachable (prohibited) reply back to the peer.
    Filtered(IpPacket),
}

impl ClientOnClient {
    pub(crate) fn new(remote_tun: IpConfig, remote_name: String) -> ClientOnClient {
        ClientOnClient {
            remote_tun,
            remote_name,
            resources: ExpiringMap::default(),
            // No resources -> no allowed inbound traffic by default.
            inbound_filter: FilterEngine::DenyAll,
            conn_track: ConnTrack::default(),
            ingest_tokens: HashMap::new(),
        }
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

    /// Records the ingest token minted for `resource_id`, or clears it when the
    /// portal sent none.
    pub(crate) fn set_ingest_token(&mut self, resource_id: ResourceId, token: Option<String>) {
        match token {
            Some(token) => {
                self.ingest_tokens.insert(resource_id, token);
            }
            None => {
                self.ingest_tokens.remove(&resource_id);
            }
        }
    }

    /// The ingest token for `resource_id`, if one was minted.
    pub(crate) fn ingest_token(&self, resource_id: &ResourceId) -> Option<String> {
        self.ingest_tokens.get(resource_id).cloned()
    }

    /// Resolves the ingest token attributing an inbound packet from this peer when
    /// we are the responder. Picks the first resource whose filter admits the
    /// packet, which is exact for the common single-resource case.
    pub(crate) fn ingest_token_for_inbound(&self, packet: &IpPacket) -> Option<String> {
        for (resource_id, resource) in self.resources.iter() {
            let admits = resource.filters.is_empty()
                || FilterEngine::new(&resource.filters)
                    .apply(packet.destination_protocol())
                    .is_ok();

            if admits {
                return self.ingest_tokens.get(resource_id).cloned();
            }
        }

        None
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
        self.ingest_tokens.remove(resource_id);

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

    /// Record an outbound packet so subsequent inbound replies are admitted.
    pub(crate) fn record_outbound(&mut self, packet: &IpPacket, now: Instant) {
        self.conn_track.record_outbound(packet, now);
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.conn_track.handle_timeout(now);
        self.resources.handle_timeout(now);

        let mut any_expired = false;

        while let Some(event) = self.resources.poll_event() {
            match event {
                crate::expiring_map::Event::EntryExpired { key, .. } => {
                    tracing::info!(rid = %key, "Resource authorization expired, revoking");
                    self.ingest_tokens.remove(&key);
                    any_expired = true;
                }
            }
        }

        if any_expired {
            self.recompute_inbound_filter();
        }
    }

    /// Who initiated the flow this *outbound* packet belongs to, if the flow
    /// is tracked. Lets `route_packet` skip the per-(resource, peer) intent
    /// when the connection is already established.
    pub(crate) fn outbound_flow_originator(&self, packet: &IpPacket) -> Option<Originator> {
        self.conn_track.outbound_flow_originator(packet)
    }

    /// Decide whether an inbound packet from this peer is admitted.
    pub(crate) fn ensure_allowed_inbound(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> Result<InboundResult> {
        // ICMP errors are always allowed through so unreachable / TTL-exceeded
        // notifications can reach the application even if the inbound filter
        // would otherwise drop them.
        if packet.icmp_error().is_ok_and(|e| e.is_some()) {
            return Ok(InboundResult::Send {
                packet,
                flow_originator: None,
            });
        }

        if let Some(originator) = self.conn_track.inbound_flow_originator(&packet) {
            return Ok(InboundResult::Send {
                packet,
                flow_originator: Some(originator),
            });
        }

        if let Err(e) = self.inbound_filter.apply(packet.destination_protocol()) {
            tracing::debug!(filtered_packet = ?packet, "{e:#}");
            let reply = ip_packet::make::icmp_dest_unreachable_prohibited(&packet)
                .context("Failed to build ICMP prohibited reply")?;
            return Ok(InboundResult::Filtered(reply));
        }

        // The packet passed our filters, record as successful inbound packet.
        self.conn_track.record_inbound(&packet, now);
        Ok(InboundResult::Send {
            packet,
            flow_originator: Some(Originator::Peer),
        })
    }
}

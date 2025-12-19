use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    net::SocketAddr,
    time::{Duration, Instant},
};

use connlib_model::ResourceId;
use ip_packet::IpPacket;
use ringbuffer::{AllocRingBuffer, RingBuffer as _};

use crate::{client::Resource, dns, unique_packet_buffer::UniquePacketBuffer};

#[derive(Default)]
pub struct PendingFlows {
    inner: HashMap<ResourceId, PendingFlow>,

    connection_intents: VecDeque<ResourceId>,
}

impl PendingFlows {
    #[tracing::instrument(level = "debug", skip_all, fields(%rid))]
    pub fn on_not_connected_resource(
        &mut self,
        rid: ResourceId,
        trigger: impl Into<ConnectionTrigger>,
        resources_by_id: &BTreeMap<ResourceId, Resource>,
        now: Instant,
    ) {
        use std::collections::hash_map::Entry;

        let trigger = trigger.into();
        let trigger_name = trigger.name();

        if !resources_by_id.contains_key(&rid) {
            tracing::debug!(%rid, "Resource not found, skipping connection intent");
            return;
        }

        match self.inner.entry(rid) {
            Entry::Vacant(v) => {
                v.insert(PendingFlow::new(now, trigger));
            }
            Entry::Occupied(mut o) => {
                let pending_flow = o.get_mut();
                pending_flow.push(trigger);

                let time_since_last_intent = now.duration_since(pending_flow.last_intent_sent_at);

                if time_since_last_intent < Duration::from_secs(2) {
                    tracing::trace!(?time_since_last_intent, "Skipping connection intent");
                    return;
                }

                pending_flow.last_intent_sent_at = now;
            }
        }

        tracing::debug!(trigger = %trigger_name, "Sending connection intent");

        self.connection_intents.push_back(rid);
    }

    pub fn remove(&mut self, rid: &ResourceId) -> Option<PendingFlow> {
        self.inner.remove(rid)
    }

    pub fn poll_connection_intents(&mut self) -> Option<ResourceId> {
        self.connection_intents.pop_front()
    }
}

pub struct PendingFlow {
    last_intent_sent_at: Instant,
    resource_packets: UniquePacketBuffer,
    dns_queries: AllocRingBuffer<DnsQueryForSite>,
}

impl PendingFlow {
    /// How many packets we will at most buffer in a [`PendingFlow`].
    ///
    /// `PendingFlow`s are per _resource_ (which could be Internet Resource or wildcard DNS resources).
    /// Thus, we may receive a fair few packets before we can send them.
    const CAPACITY_POW_2: usize = 7; // 2^7 = 128

    fn new(now: Instant, trigger: ConnectionTrigger) -> Self {
        let mut this = Self {
            last_intent_sent_at: now,
            resource_packets: UniquePacketBuffer::with_capacity_power_of_2(
                Self::CAPACITY_POW_2,
                "pending-flow-resources",
            ),
            dns_queries: AllocRingBuffer::with_capacity_power_of_2(Self::CAPACITY_POW_2),
        };
        this.push(trigger);

        this
    }

    fn push(&mut self, trigger: ConnectionTrigger) {
        match trigger {
            ConnectionTrigger::PacketForResource(packet) => self.resource_packets.push(packet),
            ConnectionTrigger::DnsQueryForSite(query) => {
                self.dns_queries.enqueue(query);
            }
            ConnectionTrigger::IcmpDestinationUnreachableProhibited => {}
        }
    }

    pub fn into_buffered_packets(self) -> (UniquePacketBuffer, AllocRingBuffer<DnsQueryForSite>) {
        let Self {
            resource_packets,
            dns_queries,
            ..
        } = self;

        (resource_packets, dns_queries)
    }
}

/// What triggered us to establish a connection to a Gateway.
pub enum ConnectionTrigger {
    /// A packet received on the TUN device with a destination IP that maps to one of our resources.
    PacketForResource(IpPacket),
    /// A DNS query that needs to be resolved within a particular site that we aren't connected to yet.
    DnsQueryForSite(DnsQueryForSite),
    /// We have received an ICMP error that is marked as "access prohibited".
    ///
    /// Most likely, the Gateway is filtering these packets because the Client doesn't have access (anymore).
    IcmpDestinationUnreachableProhibited,
}

pub struct DnsQueryForSite {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub transport: dns::Transport,
    pub message: dns_types::Query,
}

impl ConnectionTrigger {
    fn name(&self) -> &'static str {
        match self {
            ConnectionTrigger::PacketForResource(_) => "packet-for-resource",
            ConnectionTrigger::DnsQueryForSite(_) => "dns-query-for-site",
            ConnectionTrigger::IcmpDestinationUnreachableProhibited => {
                "icmp-destination-unreachable-prohibited"
            }
        }
    }
}

impl From<IpPacket> for ConnectionTrigger {
    fn from(v: IpPacket) -> Self {
        Self::PacketForResource(v)
    }
}

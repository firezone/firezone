use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    net::SocketAddr,
    time::{Duration, Instant},
};

use connlib_model::ResourceId;
use ip_packet::IpPacket;
use ringbuffer::{AllocRingBuffer, RingBuffer as _};

use crate::{
    client::Resource, dns, filter_engine::FilterEngine, unique_packet_buffer::UniquePacketBuffer,
};

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
        let trigger = trigger.into();
        let trigger_name = trigger.name();

        let Some(resource) = resources_by_id.get(&rid) else {
            tracing::debug!("Resource not found, skipping connection intent");
            return;
        };

        if !is_trigger_allowed(&trigger, resource) {
            tracing::debug!("Trigger filtered by resource filters, dropping");
            return;
        }

        let pending_flow = self
            .inner
            .entry(rid)
            .or_insert_with(|| PendingFlow::new(now - Duration::from_secs(10))); // Insert with a negative time to ensure we instantly send an intent.

        pending_flow.push(trigger);

        let time_since_last_intent = now.duration_since(pending_flow.last_intent_sent_at);

        if time_since_last_intent < Duration::from_secs(2) {
            tracing::trace!(?time_since_last_intent, "Skipping connection intent");
            return;
        }

        tracing::debug!(trigger = %trigger_name, "Sending connection intent");

        pending_flow.last_intent_sent_at = now;
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

    fn new(now: Instant) -> Self {
        Self {
            last_intent_sent_at: now,
            resource_packets: UniquePacketBuffer::with_capacity_power_of_2(
                Self::CAPACITY_POW_2,
                "pending-flow-resources",
            ),
            dns_queries: AllocRingBuffer::with_capacity_power_of_2(Self::CAPACITY_POW_2),
        }
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

impl From<DnsQueryForSite> for ConnectionTrigger {
    fn from(v: DnsQueryForSite) -> Self {
        Self::DnsQueryForSite(v)
    }
}

/// Check whether the trigger's protocol is allowed by the resource's filters.
fn is_trigger_allowed(trigger: &ConnectionTrigger, resource: &Resource) -> bool {
    let protocol = match trigger {
        ConnectionTrigger::PacketForResource(packet) => packet.destination_protocol(),
        // DNS queries and ICMP errors are control-plane triggers, not subject to data-plane filters.
        ConnectionTrigger::DnsQueryForSite(_)
        | ConnectionTrigger::IcmpDestinationUnreachableProhibited => return true,
    };

    if FilterEngine::new(resource.filters())
        .apply(protocol)
        .is_ok()
    {
        return true;
    }

    #[cfg(test)]
    if crate::malicious_behaviour::ignore_resource_filter() {
        tracing::debug!("Malicious client: ignoring resource filter");
        return true;
    }

    false
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, Ipv6Addr};

    use connlib_model::{Site, SiteId};
    use ip_network::IpNetwork;

    use crate::{
        client::resource::CidrResource, malicious_behaviour::MaliciousBehaviour, messages::Filter,
    };

    use super::*;

    #[test]
    fn skips_connection_intent_if_sent_within_last_two_seconds() {
        let mut pending_flows = PendingFlows::default();
        let mut now = Instant::now();
        let rid = ipv4_localhost_resource().id();
        let resources = BTreeMap::from([(rid, ipv4_localhost_resource())]);

        pending_flows.on_not_connected_resource(rid, udp_trigger(1), &resources, now);
        assert_eq!(pending_flows.poll_connection_intents(), Some(rid));

        now += Duration::from_secs(1);

        pending_flows.on_not_connected_resource(rid, udp_trigger(2), &resources, now);
        assert_eq!(pending_flows.poll_connection_intents(), None);
    }

    #[test]
    fn sends_new_intent_after_two_seconds() {
        let mut pending_flows = PendingFlows::default();
        let mut now = Instant::now();
        let rid = ipv4_localhost_resource().id();
        let resources = BTreeMap::from([(rid, ipv4_localhost_resource())]);

        pending_flows.on_not_connected_resource(rid, udp_trigger(1), &resources, now);
        assert_eq!(pending_flows.poll_connection_intents(), Some(rid));

        now += Duration::from_secs(3);

        pending_flows.on_not_connected_resource(rid, udp_trigger(2), &resources, now);
        assert_eq!(pending_flows.poll_connection_intents(), Some(rid));
    }

    #[test]
    fn sends_intent_for_same_site_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending_flows = PendingFlows::default();
        let now = Instant::now();
        let rid1 = ipv4_localhost_resource().id();
        let rid2 = ipv6_localhost_resource().id();
        let resources = BTreeMap::from([
            (rid1, ipv4_localhost_resource()),
            (rid2, ipv6_localhost_resource()),
        ]);

        pending_flows.on_not_connected_resource(rid1, udp_trigger(1), &resources, now);
        assert_eq!(pending_flows.poll_connection_intents(), Some(rid1));
        pending_flows.on_not_connected_resource(rid2, udp_trigger(2), &resources, now);
        assert_eq!(pending_flows.poll_connection_intents(), Some(rid2));
    }

    #[test]
    fn drops_packet_when_resource_filter_does_not_allow_protocol() {
        let mut pending_flows = PendingFlows::default();
        let now = Instant::now();
        let resource = icmp_only_localhost_resource();
        let rid = resource.id();
        let resources = BTreeMap::from([(rid, resource)]);

        // The trigger is a UDP packet, but the resource only permits ICMP.
        pending_flows.on_not_connected_resource(rid, udp_trigger(1), &resources, now);

        assert_eq!(pending_flows.poll_connection_intents(), None);
    }

    #[test]
    fn malicious_client_can_ignore_resource_filter() {
        let mut pending_flows = PendingFlows::default();
        let now = Instant::now();
        let resource = icmp_only_localhost_resource();
        let rid = resource.id();
        let resources = BTreeMap::from([(rid, resource)]);

        let _guard = MaliciousBehaviour {
            ignore_resource_filters: true,
        }
        .guard();

        // The trigger is a UDP packet that the resource's filter would normally reject.
        pending_flows.on_not_connected_resource(rid, udp_trigger(1), &resources, now);

        assert_eq!(pending_flows.poll_connection_intents(), Some(rid));
    }

    fn udp_trigger(payload: u8) -> IpPacket {
        ip_packet::make::udp_packet(
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::LOCALHOST,
            1,
            1,
            &[payload], // We need to vary the payload because identical packets don't get buffered.
        )
        .unwrap()
    }

    fn ipv4_localhost_resource() -> Resource {
        Resource::Cidr(CidrResource {
            id: ResourceId::from_u128(1),
            address: IpNetwork::from(Ipv4Addr::LOCALHOST),
            name: "localhost-ipv4".to_owned(),
            address_description: None,
            sites: vec![site1()],
            filters: Vec::default(),
        })
    }

    fn ipv6_localhost_resource() -> Resource {
        Resource::Cidr(CidrResource {
            id: ResourceId::from_u128(2),
            address: IpNetwork::from(Ipv6Addr::LOCALHOST),
            name: "localhost-ipv6".to_owned(),
            address_description: None,
            sites: vec![site1()],
            filters: Vec::default(),
        })
    }

    fn icmp_only_localhost_resource() -> Resource {
        Resource::Cidr(CidrResource {
            id: ResourceId::from_u128(3),
            address: IpNetwork::from(Ipv4Addr::LOCALHOST),
            name: "localhost-icmp-only".to_owned(),
            address_description: None,
            sites: vec![site1()],
            filters: vec![Filter::Icmp],
        })
    }

    fn site1() -> Site {
        Site {
            id: SiteId::from_u128(1),
            name: "site-1".to_owned(),
        }
    }
}

use std::{
    collections::{BTreeMap, VecDeque},
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};

use connlib_model::ResourceId;
use ip_packet::IpPacket;
use ringbuffer::{AllocRingBuffer, RingBuffer as _};

use crate::{
    client::Resource, dns, filter_engine::FilterEngine, unique_packet_buffer::UniquePacketBuffer,
};

/// Tracks authorizations we have requested from the portal but have not yet been granted.
///
/// Buffers the traffic that triggered each request so it can be sent once the
/// authorization is granted.
#[derive(Default)]
pub struct PendingAuthorizations {
    inner: BTreeMap<AuthorizationTarget, PendingAuthorization>,

    authorization_requests: VecDeque<AuthorizationRequest>,
}

/// What we are requesting authorization for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum AuthorizationTarget {
    Resource(ResourceId),
    Device { pool: ResourceId, addr: IpAddr },
}

impl From<ResourceId> for AuthorizationTarget {
    fn from(v: ResourceId) -> Self {
        Self::Resource(v)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthorizationRequest {
    pub resource_id: ResourceId,
    /// The address of the device we want to reach.
    ///
    /// `None` for gateway-routed resources where the portal picks the gateway.
    pub ip: Option<IpAddr>,
}

impl PendingAuthorizations {
    #[tracing::instrument(level = "debug", skip_all, fields(%rid))]
    pub fn on_not_authorized_resource(
        &mut self,
        rid: ResourceId,
        trigger: impl Into<Trigger>,
        resources_by_id: &BTreeMap<ResourceId, Resource>,
        now: Instant,
    ) {
        let trigger = trigger.into();

        let Some(resource) = resources_by_id.get(&rid) else {
            tracing::debug!("Resource not found, skipping authorization request");
            return;
        };

        if !is_trigger_allowed(&trigger, &FilterEngine::new(resource.filters())) {
            tracing::debug!("Trigger filtered by resource filters, dropping");
            return;
        }

        self.upsert(AuthorizationTarget::Resource(rid), trigger, now);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%resource_id, %ip))]
    pub fn on_not_authorized_device(
        &mut self,
        resource_id: ResourceId,
        ip: IpAddr,
        trigger: impl Into<Trigger>,
        resources_by_id: &BTreeMap<ResourceId, Resource>,
        now: Instant,
    ) {
        let trigger = trigger.into();

        let Some(resource) = resources_by_id.get(&resource_id) else {
            tracing::debug!("Resource not found, skipping authorization request");
            return;
        };

        if !is_trigger_allowed(&trigger, &FilterEngine::new(resource.filters())) {
            tracing::debug!("Trigger filtered by resource filters, dropping");
            return;
        }

        self.upsert(
            AuthorizationTarget::Device {
                pool: resource_id,
                addr: ip,
            },
            trigger,
            now,
        );
    }

    pub fn remove(
        &mut self,
        target: impl Into<AuthorizationTarget>,
    ) -> Option<PendingAuthorization> {
        self.inner.remove(&target.into())
    }

    /// Removes and returns every device entry whose (pool, address) matches the predicate.
    ///
    /// The iterator must be consumed for the entries to be removed.
    pub fn remove_device_authorizations<'a>(
        &'a mut self,
        mut f: impl FnMut(ResourceId, IpAddr) -> bool + 'a,
    ) -> impl Iterator<Item = (ResourceId, PendingAuthorization)> + 'a {
        self.inner
            .extract_if(.., move |target, _| match target {
                AuthorizationTarget::Resource(_) => false,
                AuthorizationTarget::Device { pool, addr } => f(*pool, *addr),
            })
            .filter_map(|(target, pending)| match target {
                AuthorizationTarget::Device { pool, .. } => Some((pool, pending)),
                AuthorizationTarget::Resource(_) => None,
            })
    }

    pub fn poll_authorization_requests(&mut self) -> Option<AuthorizationRequest> {
        self.authorization_requests.pop_front()
    }

    fn upsert(&mut self, target: AuthorizationTarget, trigger: Trigger, now: Instant) {
        let trigger_name = trigger.name();

        let pending = self.inner.entry(target).or_insert_with(|| {
            // Insert with a negative time to ensure we instantly send a request.
            PendingAuthorization::new(now - Duration::from_secs(10))
        });

        pending.push(trigger);

        let time_since_last_request = now.duration_since(pending.last_request_sent_at);

        if time_since_last_request < Duration::from_secs(2) {
            tracing::trace!(?time_since_last_request, "Skipping authorization request");
            return;
        }

        tracing::debug!(trigger = %trigger_name, "Requesting authorization");

        pending.last_request_sent_at = now;

        let request = match target {
            AuthorizationTarget::Resource(rid) => AuthorizationRequest {
                resource_id: rid,
                ip: None,
            },
            AuthorizationTarget::Device { pool, addr } => AuthorizationRequest {
                resource_id: pool,
                ip: Some(addr),
            },
        };
        self.authorization_requests.push_back(request);
    }
}

pub struct PendingAuthorization {
    last_request_sent_at: Instant,
    resource_packets: UniquePacketBuffer,
    dns_queries: AllocRingBuffer<DnsQueryForSite>,
}

impl PendingAuthorization {
    /// How many packets we will at most buffer in a [`PendingAuthorization`].
    ///
    /// `PendingAuthorization`s can span an entire _resource_ (which could be
    /// an Internet Resource or wildcard DNS resource).
    /// Thus, we may receive a fair few packets before we can send them.
    const CAPACITY_POW_2: usize = 7; // 2^7 = 128

    fn new(now: Instant) -> Self {
        Self {
            last_request_sent_at: now,
            resource_packets: UniquePacketBuffer::with_capacity_power_of_2(
                Self::CAPACITY_POW_2,
                "pending-authorization",
            ),
            dns_queries: AllocRingBuffer::with_capacity_power_of_2(Self::CAPACITY_POW_2),
        }
    }

    fn push(&mut self, trigger: Trigger) {
        match trigger {
            Trigger::PacketForResource(packet) => self.resource_packets.push(packet),
            Trigger::DnsQueryForSite(query) => {
                self.dns_queries.enqueue(query);
            }
            Trigger::IcmpDestinationUnreachableProhibited => {}
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

/// What triggered us to request an authorization.
pub enum Trigger {
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

impl Trigger {
    fn name(&self) -> &'static str {
        match self {
            Trigger::PacketForResource(_) => "packet-for-resource",
            Trigger::DnsQueryForSite(_) => "dns-query-for-site",
            Trigger::IcmpDestinationUnreachableProhibited => {
                "icmp-destination-unreachable-prohibited"
            }
        }
    }
}

impl From<IpPacket> for Trigger {
    fn from(v: IpPacket) -> Self {
        Self::PacketForResource(v)
    }
}

impl From<DnsQueryForSite> for Trigger {
    fn from(v: DnsQueryForSite) -> Self {
        Self::DnsQueryForSite(v)
    }
}

/// Checks whether the trigger's protocol is allowed by the given filters.
fn is_trigger_allowed(trigger: &Trigger, filter: &FilterEngine) -> bool {
    let protocol = match trigger {
        Trigger::PacketForResource(packet) => packet.destination_protocol(),
        // DNS queries and ICMP errors are control-plane triggers, not subject to data-plane filters.
        Trigger::DnsQueryForSite(_) | Trigger::IcmpDestinationUnreachableProhibited => return true,
    };

    if filter.apply(protocol).is_ok() {
        return true;
    }

    #[cfg(any(test, feature = "test-util"))]
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
    fn skips_authorization_request_if_sent_within_last_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let (rid, resources) = single_resource();

        pending.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );

        now += Duration::from_secs(1);

        pending.on_not_authorized_resource(rid, udp_trigger(2), &resources, now);
        assert_eq!(pending.poll_authorization_requests(), None);
    }

    #[test]
    fn sends_new_request_after_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let (rid, resources) = single_resource();

        pending.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );

        now += Duration::from_secs(3);

        pending.on_not_authorized_resource(rid, udp_trigger(2), &resources, now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );
    }

    #[test]
    fn sends_request_for_same_site_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let (rid1, rid2, resources) = two_resources();

        pending.on_not_authorized_resource(rid1, udp_trigger(1), &resources, now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid1))
        );
        pending.on_not_authorized_resource(rid2, udp_trigger(2), &resources, now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid2))
        );
    }

    #[test]
    fn drops_packet_when_resource_filter_does_not_allow_protocol() {
        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let resource = icmp_only_localhost_resource();
        let rid = resource.id();
        let resources = BTreeMap::from([(rid, resource)]);

        // The trigger is a UDP packet, but the resource only permits ICMP.
        pending.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);

        assert_eq!(pending.poll_authorization_requests(), None);
    }

    #[test]
    fn malicious_client_can_ignore_resource_filter() {
        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let resource = icmp_only_localhost_resource();
        let rid = resource.id();
        let resources = BTreeMap::from([(rid, resource)]);

        let _guard = MaliciousBehaviour {
            ignore_resource_filters: true,
        }
        .guard();

        // The trigger is a UDP packet that the resource's filter would normally reject.
        pending.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);

        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );
    }

    #[test]
    fn skips_device_authorization_request_if_sent_within_last_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let (rid, resources) = single_resource();
        let ip = device_ip();

        pending.on_not_authorized_device(rid, ip, udp_trigger(1), &resources, now);
        assert!(pending.poll_authorization_requests().is_some());

        now += Duration::from_secs(1);

        pending.on_not_authorized_device(rid, ip, udp_trigger(2), &resources, now);
        assert!(pending.poll_authorization_requests().is_none());
    }

    #[test]
    fn sends_new_device_request_after_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let (rid, resources) = single_resource();
        let ip = device_ip();

        pending.on_not_authorized_device(rid, ip, udp_trigger(1), &resources, now);
        assert!(pending.poll_authorization_requests().is_some());

        now += Duration::from_secs(3);

        pending.on_not_authorized_device(rid, ip, udp_trigger(2), &resources, now);
        assert!(pending.poll_authorization_requests().is_some());
    }

    #[test]
    fn sends_request_for_different_devices_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let (rid, resources) = single_resource();
        let ip_foo = device_ip();
        let ip_bar = other_device_ip();

        pending.on_not_authorized_device(rid, ip_foo, udp_trigger(1), &resources, now);
        let request = pending.poll_authorization_requests().unwrap();
        assert_eq!(request.ip, Some(ip_foo));
        pending.on_not_authorized_device(rid, ip_bar, udp_trigger(2), &resources, now);
        let request = pending.poll_authorization_requests().unwrap();
        assert_eq!(request.ip, Some(ip_bar));
    }

    #[test]
    fn same_address_in_two_pools_is_requested_per_pool() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let (rid_one, rid_two, resources) = two_resources();
        let ip = device_ip();

        pending.on_not_authorized_device(rid_one, ip, udp_trigger(1), &resources, now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(rid_one, ip))
        );

        // The other pool's throttle window must not suppress this request.
        now += Duration::from_millis(500);

        pending.on_not_authorized_device(rid_two, ip, udp_trigger(2), &resources, now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(rid_two, ip))
        );
    }

    #[test]
    fn remove_device_authorizations_leaves_resource_entries() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let (rid, resources) = single_resource();
        let ip = device_ip();

        pending.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);
        pending.on_not_authorized_device(rid, ip, udp_trigger(2), &resources, now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(rid, ip))
        );

        assert_eq!(pending.remove_device_authorizations(|_, _| true).count(), 1);

        now += Duration::from_millis(500);

        // The resource entry survived: within its throttle window, no new request.
        pending.on_not_authorized_resource(rid, udp_trigger(3), &resources, now);
        assert_eq!(pending.poll_authorization_requests(), None);

        // The device entry was removed: a new trigger requests again immediately.
        pending.on_not_authorized_device(rid, ip, udp_trigger(4), &resources, now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(rid, ip))
        );
    }

    fn single_resource() -> (ResourceId, BTreeMap<ResourceId, Resource>) {
        let resource = ipv4_localhost_resource();
        let rid = resource.id();

        (rid, BTreeMap::from([(rid, resource)]))
    }

    fn two_resources() -> (ResourceId, ResourceId, BTreeMap<ResourceId, Resource>) {
        let one = ipv4_localhost_resource();
        let two = ipv6_localhost_resource();
        let (rid_one, rid_two) = (one.id(), two.id());

        (
            rid_one,
            rid_two,
            BTreeMap::from([(rid_one, one), (rid_two, two)]),
        )
    }

    fn device_request(resource_id: ResourceId, ip: IpAddr) -> AuthorizationRequest {
        AuthorizationRequest {
            resource_id,
            ip: Some(ip),
        }
    }

    fn device_ip() -> IpAddr {
        IpAddr::from(Ipv4Addr::new(100, 64, 0, 100))
    }

    fn other_device_ip() -> IpAddr {
        IpAddr::from(Ipv4Addr::new(100, 64, 0, 200))
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

    fn resource_request(resource_id: ResourceId) -> AuthorizationRequest {
        AuthorizationRequest {
            resource_id,
            ip: None,
        }
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

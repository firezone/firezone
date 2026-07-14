use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};

use connlib_model::{ClientId, ResourceId};
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
    inner: HashMap<AuthorizationTarget, PendingAuthorization>,

    authorization_requests: VecDeque<AuthorizationRequest>,
}

/// What we are requesting authorization for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AuthorizationTarget {
    Resource(ResourceId),
    Device(ClientId),
}

impl From<ResourceId> for AuthorizationTarget {
    fn from(v: ResourceId) -> Self {
        Self::Resource(v)
    }
}

impl From<ClientId> for AuthorizationTarget {
    fn from(v: ClientId) -> Self {
        Self::Device(v)
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

        self.upsert(AuthorizationTarget::Resource(rid), rid, None, trigger, now);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%client_id, %resource_id, %ip))]
    pub fn on_not_authorized_device(
        &mut self,
        client_id: ClientId,
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
            AuthorizationTarget::Device(client_id),
            resource_id,
            Some(ip),
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

    pub fn poll_authorization_requests(&mut self) -> Option<AuthorizationRequest> {
        self.authorization_requests.pop_front()
    }

    fn upsert(
        &mut self,
        target: AuthorizationTarget,
        resource_id: ResourceId,
        ip: Option<IpAddr>,
        trigger: Trigger,
        now: Instant,
    ) {
        let trigger_name = trigger.name();

        let pending = self.inner.entry(target).or_insert_with(|| {
            // Insert with a negative time to ensure we instantly send a request.
            PendingAuthorization::new(resource_id, now - Duration::from_secs(10))
        });

        pending.push(trigger);

        let time_since_last_request = now.duration_since(pending.last_request_sent_at);

        if time_since_last_request < Duration::from_secs(2) {
            tracing::trace!(?time_since_last_request, "Skipping authorization request");
            return;
        }

        tracing::debug!(trigger = %trigger_name, "Requesting authorization");

        pending.resource_id = resource_id;
        pending.last_request_sent_at = now;
        self.authorization_requests
            .push_back(AuthorizationRequest { resource_id, ip });
    }
}

pub struct PendingAuthorization {
    /// The resource of the most recent authorization request for this target.
    resource_id: ResourceId,
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

    fn new(resource_id: ResourceId, now: Instant) -> Self {
        Self {
            resource_id,
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

    pub fn resource_id(&self) -> ResourceId {
        self.resource_id
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
    fn skips_authorization_request_if_sent_within_last_two_seconds() {
        let mut pending_authorizations = PendingAuthorizations::default();
        let mut now = Instant::now();
        let rid = ipv4_localhost_resource().id();
        let resources = BTreeMap::from([(rid, ipv4_localhost_resource())]);

        pending_authorizations.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);
        assert_eq!(
            pending_authorizations.poll_authorization_requests(),
            Some(resource_request(rid))
        );

        now += Duration::from_secs(1);

        pending_authorizations.on_not_authorized_resource(rid, udp_trigger(2), &resources, now);
        assert_eq!(pending_authorizations.poll_authorization_requests(), None);
    }

    #[test]
    fn sends_new_request_after_two_seconds() {
        let mut pending_authorizations = PendingAuthorizations::default();
        let mut now = Instant::now();
        let rid = ipv4_localhost_resource().id();
        let resources = BTreeMap::from([(rid, ipv4_localhost_resource())]);

        pending_authorizations.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);
        assert_eq!(
            pending_authorizations.poll_authorization_requests(),
            Some(resource_request(rid))
        );

        now += Duration::from_secs(3);

        pending_authorizations.on_not_authorized_resource(rid, udp_trigger(2), &resources, now);
        assert_eq!(
            pending_authorizations.poll_authorization_requests(),
            Some(resource_request(rid))
        );
    }

    #[test]
    fn sends_request_for_same_site_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending_authorizations = PendingAuthorizations::default();
        let now = Instant::now();
        let rid1 = ipv4_localhost_resource().id();
        let rid2 = ipv6_localhost_resource().id();
        let resources = BTreeMap::from([
            (rid1, ipv4_localhost_resource()),
            (rid2, ipv6_localhost_resource()),
        ]);

        pending_authorizations.on_not_authorized_resource(rid1, udp_trigger(1), &resources, now);
        assert_eq!(
            pending_authorizations.poll_authorization_requests(),
            Some(resource_request(rid1))
        );
        pending_authorizations.on_not_authorized_resource(rid2, udp_trigger(2), &resources, now);
        assert_eq!(
            pending_authorizations.poll_authorization_requests(),
            Some(resource_request(rid2))
        );
    }

    #[test]
    fn drops_packet_when_resource_filter_does_not_allow_protocol() {
        let mut pending_authorizations = PendingAuthorizations::default();
        let now = Instant::now();
        let resource = icmp_only_localhost_resource();
        let rid = resource.id();
        let resources = BTreeMap::from([(rid, resource)]);

        // The trigger is a UDP packet, but the resource only permits ICMP.
        pending_authorizations.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);

        assert_eq!(pending_authorizations.poll_authorization_requests(), None);
    }

    #[test]
    fn malicious_client_can_ignore_resource_filter() {
        let mut pending_authorizations = PendingAuthorizations::default();
        let now = Instant::now();
        let resource = icmp_only_localhost_resource();
        let rid = resource.id();
        let resources = BTreeMap::from([(rid, resource)]);

        let _guard = MaliciousBehaviour {
            ignore_resource_filters: true,
        }
        .guard();

        // The trigger is a UDP packet that the resource's filter would normally reject.
        pending_authorizations.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);

        assert_eq!(
            pending_authorizations.poll_authorization_requests(),
            Some(resource_request(rid))
        );
    }

    #[test]
    fn skips_device_authorization_request_if_sent_within_last_two_seconds() {
        let mut pending_authorizations = PendingAuthorizations::default();
        let mut now = Instant::now();
        let cid = client_foo();
        let rid = ipv4_localhost_resource().id();
        let resources = BTreeMap::from([(rid, ipv4_localhost_resource())]);
        let ip = IpAddr::from(Ipv4Addr::new(100, 64, 0, 100));

        pending_authorizations.on_not_authorized_device(
            cid,
            rid,
            ip,
            udp_trigger(1),
            &resources,
            now,
        );
        assert!(
            pending_authorizations
                .poll_authorization_requests()
                .is_some()
        );

        now += Duration::from_secs(1);

        pending_authorizations.on_not_authorized_device(
            cid,
            rid,
            ip,
            udp_trigger(2),
            &resources,
            now,
        );
        assert!(
            pending_authorizations
                .poll_authorization_requests()
                .is_none()
        );
    }

    #[test]
    fn sends_new_device_request_after_two_seconds() {
        let mut pending_authorizations = PendingAuthorizations::default();
        let mut now = Instant::now();
        let cid = client_foo();
        let rid = ipv4_localhost_resource().id();
        let resources = BTreeMap::from([(rid, ipv4_localhost_resource())]);
        let ip = IpAddr::from(Ipv4Addr::new(100, 64, 0, 100));

        pending_authorizations.on_not_authorized_device(
            cid,
            rid,
            ip,
            udp_trigger(1),
            &resources,
            now,
        );
        assert!(
            pending_authorizations
                .poll_authorization_requests()
                .is_some()
        );

        now += Duration::from_secs(3);

        pending_authorizations.on_not_authorized_device(
            cid,
            rid,
            ip,
            udp_trigger(2),
            &resources,
            now,
        );
        assert!(
            pending_authorizations
                .poll_authorization_requests()
                .is_some()
        );
    }

    #[test]
    fn sends_request_for_different_devices_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending_authorizations = PendingAuthorizations::default();
        let now = Instant::now();
        let cid_foo = client_foo();
        let cid_bar = client_bar();
        let rid = ipv4_localhost_resource().id();
        let resources = BTreeMap::from([(rid, ipv4_localhost_resource())]);
        let ip_foo = IpAddr::from(Ipv4Addr::new(100, 64, 0, 100));
        let ip_bar = IpAddr::from(Ipv4Addr::new(100, 64, 0, 200));

        pending_authorizations.on_not_authorized_device(
            cid_foo,
            rid,
            ip_foo,
            udp_trigger(1),
            &resources,
            now,
        );
        let request = pending_authorizations
            .poll_authorization_requests()
            .unwrap();
        assert_eq!(request.ip, Some(ip_foo));
        pending_authorizations.on_not_authorized_device(
            cid_bar,
            rid,
            ip_bar,
            udp_trigger(2),
            &resources,
            now,
        );
        let request = pending_authorizations
            .poll_authorization_requests()
            .unwrap();
        assert_eq!(request.ip, Some(ip_bar));
    }

    #[test]
    fn entry_tracks_resource_of_most_recent_request() {
        let mut pending_authorizations = PendingAuthorizations::default();
        let mut now = Instant::now();
        let cid = client_foo();
        let rid_one = ipv4_localhost_resource().id();
        let rid_two = ipv6_localhost_resource().id();
        let resources = BTreeMap::from([
            (rid_one, ipv4_localhost_resource()),
            (rid_two, ipv6_localhost_resource()),
        ]);
        let ip = IpAddr::from(Ipv4Addr::new(100, 64, 0, 100));

        pending_authorizations.on_not_authorized_device(
            cid,
            rid_one,
            ip,
            udp_trigger(1),
            &resources,
            now,
        );
        assert!(
            pending_authorizations
                .poll_authorization_requests()
                .is_some()
        );

        now += Duration::from_secs(3);

        pending_authorizations.on_not_authorized_device(
            cid,
            rid_two,
            ip,
            udp_trigger(2),
            &resources,
            now,
        );
        assert!(
            pending_authorizations
                .poll_authorization_requests()
                .is_some()
        );

        let entry = pending_authorizations.remove(cid).unwrap();
        assert_eq!(entry.resource_id(), rid_two);
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

    fn client_foo() -> ClientId {
        ClientId::from_u128(1)
    }

    fn client_bar() -> ClientId {
        ClientId::from_u128(2)
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

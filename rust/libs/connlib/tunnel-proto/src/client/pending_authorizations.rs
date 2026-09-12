use std::{
    collections::{BTreeMap, VecDeque},
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};

use connlib_model::ResourceId;
use ip_packet::IpPacket;
use ringbuffer::{AllocRingBuffer, RingBuffer as _};

use crate::{
    client::{NEGATIVE_CACHE_TTL, Resource},
    dns,
    expiring_map::ExpiringMap,
    filter_engine::FilterEngine,
    messages::client::Flow,
    unique_packet_buffer::UniquePacketBuffer,
};

/// Tracks authorizations we have requested from the portal but have not yet been granted.
///
/// Buffers the traffic that triggered each request so it can be sent once the
/// authorization is granted.
#[derive(Default)]
pub struct PendingAuthorizations {
    inner: BTreeMap<AuthorizationTarget, PendingAuthorization>,
    /// Requests the portal denied recently; the same request is answered locally until it expires.
    denied: ExpiringMap<Denied, ()>,

    authorization_requests: VecDeque<AuthorizationRequest>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Denied {
    Resource(ResourceId),
    /// No device answers at the address, so every flow to it is denied.
    Device(IpAddr),
    Flow {
        addr: IpAddr,
        flow: Flow,
    },
}

/// What we are requesting authorization for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum AuthorizationTarget {
    Resource(ResourceId),
    Device { addr: IpAddr },
}

impl From<ResourceId> for AuthorizationTarget {
    fn from(v: ResourceId) -> Self {
        Self::Resource(v)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthorizationRequest {
    Resource(ResourceId),
    /// Access to the device at `addr` for `flow`; the portal picks the pool.
    Device {
        addr: IpAddr,
        flow: Flow,
    },
}

impl PendingAuthorizations {
    /// Buffers the trigger and asks the portal for access to the resource.
    ///
    /// Returns the trigger when the portal denied the resource recently, so the caller can
    /// answer it without asking again.
    #[tracing::instrument(level = "debug", skip_all, fields(%rid))]
    pub fn on_not_authorized_resource(
        &mut self,
        rid: ResourceId,
        trigger: impl Into<Trigger>,
        resources_by_id: &BTreeMap<ResourceId, Resource>,
        now: Instant,
    ) -> Option<Trigger> {
        let trigger = trigger.into();

        if self.denied.contains_key(&Denied::Resource(rid)) {
            return Some(trigger);
        }

        let Some(resource) = resources_by_id.get(&rid) else {
            tracing::debug!("Resource not found, skipping authorization request");
            return None;
        };

        if !is_trigger_allowed(&trigger, &FilterEngine::new(resource.filters())) {
            tracing::debug!("Trigger filtered by resource filters, dropping");
            return None;
        }

        self.upsert(
            AuthorizationTarget::Resource(rid),
            AuthorizationRequest::Resource(rid),
            trigger,
            now,
        );

        None
    }

    /// Buffers the packet and asks the portal for access to the device for its flow.
    ///
    /// Returns the packet when the portal denied the address or the flow recently, so the
    /// caller can answer it without asking again.
    #[tracing::instrument(level = "debug", skip_all, fields(%ip, ?flow))]
    pub fn on_not_authorized_device(
        &mut self,
        ip: IpAddr,
        flow: Flow,
        packet: IpPacket,
        now: Instant,
    ) -> Option<IpPacket> {
        if self.denied.contains_key(&Denied::Device(ip))
            || self.denied.contains_key(&Denied::Flow { addr: ip, flow })
        {
            return Some(packet);
        }

        self.upsert(
            AuthorizationTarget::Device { addr: ip },
            AuthorizationRequest::Device { addr: ip, flow },
            packet.into(),
            now,
        );

        None
    }

    /// Records the portal's denial for the address and returns what was waiting on it.
    ///
    /// A `whole_address` denial covers every flow to the address; otherwise only the flow
    /// the request was sent for is remembered.
    pub fn deny_device(
        &mut self,
        addr: IpAddr,
        whole_address: bool,
        now: Instant,
    ) -> Option<PendingAuthorization> {
        let pending = self.inner.remove(&AuthorizationTarget::Device { addr });

        let denied = if whole_address {
            Some(Denied::Device(addr))
        } else {
            pending
                .as_ref()
                .and_then(|p| p.requested_flow)
                .map(|flow| Denied::Flow { addr, flow })
        };

        if let Some(denied) = denied {
            self.denied.insert(denied, (), now, NEGATIVE_CACHE_TTL);
        }

        pending
    }

    /// Records the portal's denial for the resource and returns what was waiting on it.
    pub fn deny_resource(&mut self, rid: ResourceId, now: Instant) -> Option<PendingAuthorization> {
        self.denied
            .insert(Denied::Resource(rid), (), now, NEGATIVE_CACHE_TTL);

        self.inner.remove(&AuthorizationTarget::Resource(rid))
    }

    /// Drops the remembered denials for every address `f` matches, e.g. once the portal
    /// granted access after all.
    pub fn forget_device_denials(&mut self, f: impl Fn(IpAddr) -> bool) {
        for _ in self.denied.extract_if(|denied, _| match denied {
            Denied::Device(addr) | Denied::Flow { addr, .. } => f(*addr),
            Denied::Resource(_) => false,
        }) {}
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.denied.handle_timeout(now);
        while self.denied.poll_event().is_some() {}
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        self.denied.poll_timeout()
    }

    /// Forgets the request and any denial for the target, e.g. when access was granted or
    /// the resource went away.
    pub fn remove(
        &mut self,
        target: impl Into<AuthorizationTarget>,
    ) -> Option<PendingAuthorization> {
        let target = target.into();

        if let AuthorizationTarget::Resource(rid) = target {
            self.denied.remove(&Denied::Resource(rid));
        }

        self.inner.remove(&target)
    }

    /// Removes and returns every device entry whose address matches the predicate.
    ///
    /// The iterator must be consumed for the entries to be removed.
    pub fn remove_device_authorizations<'a>(
        &'a mut self,
        mut f: impl FnMut(IpAddr) -> bool + 'a,
    ) -> impl Iterator<Item = PendingAuthorization> + 'a {
        self.inner
            .extract_if(.., move |target, _| match target {
                AuthorizationTarget::Resource(_) => false,
                AuthorizationTarget::Device { addr } => f(*addr),
            })
            .map(|(_, pending)| pending)
    }

    pub fn poll_authorization_requests(&mut self) -> Option<AuthorizationRequest> {
        self.authorization_requests.pop_front()
    }

    fn upsert(
        &mut self,
        target: AuthorizationTarget,
        request: AuthorizationRequest,
        trigger: Trigger,
        now: Instant,
    ) {
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

        if let AuthorizationRequest::Device { flow, .. } = request {
            pending.requested_flow = Some(flow);
        }

        self.authorization_requests.push_back(request);
    }
}

pub struct PendingAuthorization {
    last_request_sent_at: Instant,
    /// The flow the last device access request was sent for.
    requested_flow: Option<Flow>,
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
            requested_flow: None,
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
    #[cfg_attr(not(feature = "telemetry"), expect(dead_code))]
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

    #[cfg(any(test, feature = "malicious-behaviour"))]
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
            ..Default::default()
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
        let ip = device_ip();

        pending.on_not_authorized_device(ip, udp_flow(), udp_trigger(1), now);
        assert!(pending.poll_authorization_requests().is_some());

        now += Duration::from_secs(1);

        pending.on_not_authorized_device(ip, udp_flow(), udp_trigger(2), now);
        assert!(pending.poll_authorization_requests().is_none());
    }

    #[test]
    fn sends_new_device_request_after_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let ip = device_ip();

        pending.on_not_authorized_device(ip, udp_flow(), udp_trigger(1), now);
        assert!(pending.poll_authorization_requests().is_some());

        now += Duration::from_secs(3);

        pending.on_not_authorized_device(ip, udp_flow(), udp_trigger(2), now);
        assert!(pending.poll_authorization_requests().is_some());
    }

    #[test]
    fn sends_request_for_different_devices_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let ip_foo = device_ip();
        let ip_bar = other_device_ip();

        pending.on_not_authorized_device(ip_foo, udp_flow(), udp_trigger(1), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(ip_foo))
        );
        pending.on_not_authorized_device(ip_bar, udp_flow(), udp_trigger(2), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(ip_bar))
        );
    }

    #[test]
    fn denied_flow_is_answered_locally_until_the_denial_expires() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let ip = device_ip();

        assert!(
            pending
                .on_not_authorized_device(ip, udp_flow(), udp_trigger(1), now)
                .is_none()
        );
        assert!(pending.poll_authorization_requests().is_some());

        let denied = pending.deny_device(ip, false, now);
        assert!(denied.is_some());

        // The same flow is denied without a request; another flow still asks.
        assert!(
            pending
                .on_not_authorized_device(ip, udp_flow(), udp_trigger(2), now)
                .is_some()
        );
        assert!(pending.poll_authorization_requests().is_none());
        assert!(
            pending
                .on_not_authorized_device(ip, tcp_flow(), udp_trigger(3), now)
                .is_none()
        );
        assert!(pending.poll_authorization_requests().is_some());

        now += NEGATIVE_CACHE_TTL + Duration::from_secs(1);
        pending.handle_timeout(now);

        assert!(
            pending
                .on_not_authorized_device(ip, udp_flow(), udp_trigger(4), now)
                .is_none()
        );
        assert!(pending.poll_authorization_requests().is_some());
    }

    #[test]
    fn whole_address_denial_covers_every_flow() {
        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let ip = device_ip();

        pending.on_not_authorized_device(ip, udp_flow(), udp_trigger(1), now);
        pending.poll_authorization_requests();
        pending.deny_device(ip, true, now);

        assert!(
            pending
                .on_not_authorized_device(ip, tcp_flow(), udp_trigger(2), now)
                .is_some()
        );
        assert!(pending.poll_authorization_requests().is_none());
        assert!(
            pending
                .on_not_authorized_device(other_device_ip(), tcp_flow(), udp_trigger(3), now)
                .is_none()
        );
    }

    #[test]
    fn denied_resource_returns_the_trigger_and_a_grant_forgets_the_denial() {
        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let (rid, resources) = single_resource();

        assert!(
            pending
                .on_not_authorized_resource(rid, udp_trigger(1), &resources, now)
                .is_none()
        );
        pending.poll_authorization_requests();
        assert!(pending.deny_resource(rid, now).is_some());

        assert!(matches!(
            pending.on_not_authorized_resource(rid, udp_trigger(2), &resources, now),
            Some(Trigger::PacketForResource(_))
        ));
        assert!(pending.poll_authorization_requests().is_none());

        pending.remove(rid);

        assert!(
            pending
                .on_not_authorized_resource(rid, udp_trigger(3), &resources, now)
                .is_none()
        );
        assert!(pending.poll_authorization_requests().is_some());
    }

    #[test]
    fn remove_device_authorizations_leaves_resource_entries() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let (rid, resources) = single_resource();
        let ip = device_ip();

        pending.on_not_authorized_resource(rid, udp_trigger(1), &resources, now);
        pending.on_not_authorized_device(ip, udp_flow(), udp_trigger(2), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(ip))
        );

        assert_eq!(pending.remove_device_authorizations(|_| true).count(), 1);

        now += Duration::from_millis(500);

        // The resource entry survived: within its throttle window, no new request.
        pending.on_not_authorized_resource(rid, udp_trigger(3), &resources, now);
        assert_eq!(pending.poll_authorization_requests(), None);

        // The device entry was removed: a new trigger requests again immediately.
        pending.on_not_authorized_device(ip, udp_flow(), udp_trigger(4), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(ip))
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

    fn device_request(addr: IpAddr) -> AuthorizationRequest {
        AuthorizationRequest::Device {
            addr,
            flow: udp_flow(),
        }
    }

    fn udp_flow() -> Flow {
        ip_packet::Protocol::Udp(1).into()
    }

    fn tcp_flow() -> Flow {
        ip_packet::Protocol::Tcp(22).into()
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
        AuthorizationRequest::Resource(resource_id)
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

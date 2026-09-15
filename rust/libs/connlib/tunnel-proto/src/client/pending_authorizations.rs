use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};

use connlib_model::ResourceId;
use ip_packet::IpPacket;
use ringbuffer::{AllocRingBuffer, RingBuffer as _};

use crate::{dns, unique_packet_buffer::UniquePacketBuffer};

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
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
enum AuthorizationTarget {
    Resources(Vec<ResourceId>),
    Device { addr: IpAddr },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthorizationRequest {
    Resources(Vec<ResourceId>),
    Device {
        addr: IpAddr,
        pools: Vec<ResourceId>,
    },
}

impl AuthorizationRequest {
    fn target(&self) -> AuthorizationTarget {
        match self {
            Self::Resources(resources) => AuthorizationTarget::Resources(resources.clone()),
            Self::Device { addr, .. } => AuthorizationTarget::Device { addr: *addr },
        }
    }

    fn is_empty(&self) -> bool {
        match self {
            Self::Resources(resources) => resources.is_empty(),
            Self::Device { pools, .. } => pools.is_empty(),
        }
    }
}

impl PendingAuthorizations {
    #[tracing::instrument(level = "debug", skip_all, fields(?request))]
    pub fn on_not_authorized(
        &mut self,
        request: AuthorizationRequest,
        trigger: impl Into<Trigger>,
        now: Instant,
    ) {
        if request.is_empty() {
            return;
        }

        self.upsert(request.target(), request, trigger.into(), now);
    }

    /// Removes every pending request that includes `resource` among its candidates.
    pub fn remove_resource_authorizations(
        &mut self,
        resource: ResourceId,
    ) -> Vec<PendingAuthorization> {
        self.remove_matching(|target| match target {
            AuthorizationTarget::Resources(resources) => resources.contains(&resource),
            AuthorizationTarget::Device { .. } => false,
        })
        .collect()
    }

    /// Removes pending device requests that named `pool` among their candidates.
    pub fn remove_device_authorizations_for_pool(&mut self, pool: ResourceId) {
        let removed_addrs = self
            .inner
            .extract_if(.., |target, pending| {
                matches!(target, AuthorizationTarget::Device { .. })
                    && pending.device_pools.contains(&pool)
            })
            .filter_map(|(target, _)| match target {
                AuthorizationTarget::Device { addr } => Some(addr),
                AuthorizationTarget::Resources(_) => None,
            })
            .collect::<BTreeSet<_>>();

        if removed_addrs.is_empty() {
            return;
        }

        self.authorization_requests = self
            .authorization_requests
            .drain(..)
            .filter(|request| match request {
                AuthorizationRequest::Resources(_) => true,
                AuthorizationRequest::Device { addr, .. } => !removed_addrs.contains(addr),
            })
            .collect();
    }

    /// Removes and returns every device entry whose address matches the predicate.
    ///
    /// The iterator must be consumed for the entries to be removed.
    pub fn remove_device_authorizations<'a>(
        &'a mut self,
        mut f: impl FnMut(IpAddr) -> bool + 'a,
    ) -> impl Iterator<Item = PendingAuthorization> + 'a {
        self.remove_matching(move |target| match target {
            AuthorizationTarget::Resources(_) => false,
            AuthorizationTarget::Device { addr } => f(*addr),
        })
    }

    pub fn poll_authorization_requests(&mut self) -> Option<AuthorizationRequest> {
        self.authorization_requests.pop_front()
    }

    fn remove_matching<'a>(
        &'a mut self,
        mut f: impl FnMut(&AuthorizationTarget) -> bool + 'a,
    ) -> impl Iterator<Item = PendingAuthorization> + 'a {
        self.inner
            .extract_if(.., move |target, _| f(target))
            .map(|(_, pending)| pending)
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

        if let AuthorizationRequest::Device { pools, .. } = &request {
            pending.device_pools.extend(pools.iter().copied());
        }

        pending.push(trigger);

        let time_since_last_request = now.duration_since(pending.last_request_sent_at);

        if time_since_last_request < Duration::from_secs(2) {
            tracing::trace!(?time_since_last_request, "Skipping authorization request");
            return;
        }

        tracing::debug!(trigger = %trigger_name, "Requesting authorization");

        pending.last_request_sent_at = now;

        self.authorization_requests.push_back(request);
    }
}

pub struct PendingAuthorization {
    last_request_sent_at: Instant,
    device_pools: BTreeSet<ResourceId>,
    packets: UniquePacketBuffer,
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
            device_pools: BTreeSet::new(),
            packets: UniquePacketBuffer::with_capacity_power_of_2(
                Self::CAPACITY_POW_2,
                "pending-authorization",
            ),
            dns_queries: AllocRingBuffer::with_capacity_power_of_2(Self::CAPACITY_POW_2),
        }
    }

    fn push(&mut self, trigger: Trigger) {
        match trigger {
            Trigger::Packet(packet) => self.packets.push(packet),
            Trigger::DnsQueryForSite(query) => {
                self.dns_queries.enqueue(query);
            }
            Trigger::IcmpDestinationUnreachableProhibited => {}
        }
    }

    pub fn into_buffers(self) -> (UniquePacketBuffer, AllocRingBuffer<DnsQueryForSite>) {
        let Self {
            packets,
            dns_queries,
            ..
        } = self;

        (packets, dns_queries)
    }
}

/// What triggered us to request an authorization.
pub enum Trigger {
    /// A packet received on the TUN device that needs outbound authorization.
    Packet(IpPacket),
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
            Trigger::Packet(_) => "packet",
            Trigger::DnsQueryForSite(_) => "dns-query-for-site",
            Trigger::IcmpDestinationUnreachableProhibited => {
                "icmp-destination-unreachable-prohibited"
            }
        }
    }
}

impl From<IpPacket> for Trigger {
    fn from(v: IpPacket) -> Self {
        Self::Packet(v)
    }
}

impl From<DnsQueryForSite> for Trigger {
    fn from(v: DnsQueryForSite) -> Self {
        Self::DnsQueryForSite(v)
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    #[test]
    fn skips_authorization_request_if_sent_within_last_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let rid = ResourceId::from_u128(1);

        pending.on_not_authorized(resource_request(rid), udp_trigger(1), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );

        now += Duration::from_secs(1);

        pending.on_not_authorized(resource_request(rid), udp_trigger(2), now);
        assert_eq!(pending.poll_authorization_requests(), None);
    }

    #[test]
    fn sends_new_request_after_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let rid = ResourceId::from_u128(1);

        pending.on_not_authorized(resource_request(rid), udp_trigger(1), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );

        now += Duration::from_secs(3);

        pending.on_not_authorized(resource_request(rid), udp_trigger(2), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );
    }

    #[test]
    fn requests_every_matching_resource_in_order() {
        let mut pending = PendingAuthorizations::default();
        let first = ResourceId::from_u128(1);
        let second = ResourceId::from_u128(2);
        let resource_ids = vec![second, first];

        pending.on_not_authorized(
            AuthorizationRequest::Resources(resource_ids.clone()),
            udp_trigger(1),
            Instant::now(),
        );

        assert_eq!(
            pending.poll_authorization_requests(),
            Some(AuthorizationRequest::Resources(resource_ids))
        );
        assert_eq!(pending.remove_resource_authorizations(first).len(), 1);
        assert!(pending.remove_resource_authorizations(second).is_empty());
    }

    #[test]
    fn throttles_only_identical_candidate_lists() {
        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let a = ResourceId::from_u128(1);
        let b = ResourceId::from_u128(2);
        let c = ResourceId::from_u128(3);

        for candidates in [vec![a, b], vec![a, c], vec![b, a]] {
            pending.on_not_authorized(
                AuthorizationRequest::Resources(candidates.clone()),
                udp_trigger(1),
                now,
            );
            assert_eq!(
                pending.poll_authorization_requests(),
                Some(AuthorizationRequest::Resources(candidates.clone()))
            );

            pending.on_not_authorized(
                AuthorizationRequest::Resources(candidates),
                udp_trigger(2),
                now + Duration::from_secs(1),
            );
            assert_eq!(pending.poll_authorization_requests(), None);
        }
    }

    #[test]
    fn authorization_drains_all_lists_containing_the_granted_resource() {
        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let a = ResourceId::from_u128(1);
        let b = ResourceId::from_u128(2);
        let c = ResourceId::from_u128(3);
        let first_packet = udp_trigger(1);
        let second_packet = udp_trigger(2);
        pending.on_not_authorized(
            AuthorizationRequest::Resources(vec![a, b]),
            first_packet.clone(),
            now,
        );
        pending.on_not_authorized(
            AuthorizationRequest::Resources(vec![c, b]),
            second_packet.clone(),
            now,
        );
        pending.on_not_authorized(
            AuthorizationRequest::Resources(vec![a, c]),
            udp_trigger(3),
            now,
        );
        pending.on_not_authorized(device_request(device_ip()), udp_trigger(4), now);

        let drained = pending.remove_resource_authorizations(b);
        let packets = drained
            .into_iter()
            .flat_map(|entry| entry.into_buffers().0)
            .collect::<Vec<_>>();
        assert_eq!(packets, vec![first_packet, second_packet]);
        assert!(pending.remove_resource_authorizations(b).is_empty());
        assert_eq!(pending.remove_resource_authorizations(a).len(), 1);
        assert_eq!(pending.remove_device_authorizations(|_| true).count(), 1);
    }

    #[test]
    fn sends_request_for_different_resources_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let rid1 = ResourceId::from_u128(1);
        let rid2 = ResourceId::from_u128(2);

        pending.on_not_authorized(resource_request(rid1), udp_trigger(1), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid1))
        );
        pending.on_not_authorized(resource_request(rid2), udp_trigger(2), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid2))
        );
    }

    #[test]
    fn skips_device_authorization_request_if_sent_within_last_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let ip = device_ip();

        pending.on_not_authorized(device_request(ip), udp_trigger(1), now);
        assert!(pending.poll_authorization_requests().is_some());

        now += Duration::from_secs(1);

        pending.on_not_authorized(device_request(ip), udp_trigger(2), now);
        assert!(pending.poll_authorization_requests().is_none());
    }

    #[test]
    fn sends_new_device_request_after_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let ip = device_ip();

        pending.on_not_authorized(device_request(ip), udp_trigger(1), now);
        assert!(pending.poll_authorization_requests().is_some());

        now += Duration::from_secs(3);

        pending.on_not_authorized(device_request(ip), udp_trigger(2), now);
        assert!(pending.poll_authorization_requests().is_some());
    }

    #[test]
    fn sends_request_for_different_devices_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let ip_foo = device_ip();
        let ip_bar = other_device_ip();

        pending.on_not_authorized(device_request(ip_foo), udp_trigger(1), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(ip_foo))
        );
        pending.on_not_authorized(device_request(ip_bar), udp_trigger(2), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(ip_bar))
        );
    }

    #[test]
    fn remove_device_authorizations_leaves_resource_entries() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let rid = ResourceId::from_u128(1);
        let ip = device_ip();

        pending.on_not_authorized(resource_request(rid), udp_trigger(1), now);
        pending.on_not_authorized(device_request(ip), udp_trigger(2), now);
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
        pending.on_not_authorized(resource_request(rid), udp_trigger(3), now);
        assert_eq!(pending.poll_authorization_requests(), None);

        // The device entry was removed: a new trigger requests again immediately.
        pending.on_not_authorized(device_request(ip), udp_trigger(4), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(ip))
        );
    }

    #[test]
    fn removing_pool_clears_only_device_requests_that_named_it() {
        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let removed_pool = ResourceId::from_u128(1);
        let remaining_pool = ResourceId::from_u128(2);
        let removed_device = device_ip();
        let other_device = other_device_ip();
        let first_request = AuthorizationRequest::Device {
            addr: removed_device,
            pools: vec![removed_pool],
        };
        let updated_request = AuthorizationRequest::Device {
            addr: removed_device,
            pools: vec![remaining_pool],
        };
        let other_request = AuthorizationRequest::Device {
            addr: other_device,
            pools: vec![remaining_pool],
        };

        pending.on_not_authorized(first_request.clone(), udp_trigger(1), now);
        assert_eq!(pending.poll_authorization_requests(), Some(first_request));

        let later = now + Duration::from_secs(3);
        pending.on_not_authorized(updated_request.clone(), udp_trigger(2), later);
        pending.on_not_authorized(other_request.clone(), udp_trigger(3), later);

        pending.remove_device_authorizations_for_pool(removed_pool);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(other_request.clone())
        );
        assert_eq!(pending.poll_authorization_requests(), None);

        pending.on_not_authorized(
            updated_request.clone(),
            udp_trigger(4),
            later + Duration::from_secs(1),
        );
        assert_eq!(pending.poll_authorization_requests(), Some(updated_request));

        pending.on_not_authorized(
            other_request,
            udp_trigger(5),
            later + Duration::from_secs(1),
        );
        assert_eq!(pending.poll_authorization_requests(), None);
    }

    fn device_request(addr: IpAddr) -> AuthorizationRequest {
        AuthorizationRequest::Device {
            addr,
            pools: pools(),
        }
    }

    fn pools() -> Vec<ResourceId> {
        vec![ResourceId::from_u128(7)]
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
        AuthorizationRequest::Resources(vec![resource_id])
    }
}

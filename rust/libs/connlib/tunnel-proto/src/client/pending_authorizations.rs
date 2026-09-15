use std::{
    collections::{BTreeMap, VecDeque},
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthorizationRequest {
    Resources(Vec<ResourceId>),
    /// Access to the device at `addr` through `pools`, most preferred first; the portal
    /// grants the first that holds the device.
    Device {
        addr: IpAddr,
        pools: Vec<ResourceId>,
    },
}

impl PendingAuthorizations {
    #[tracing::instrument(level = "debug", skip_all, fields(?resource_ids))]
    pub fn on_not_authorized_resource(
        &mut self,
        resource_ids: Vec<ResourceId>,
        trigger: impl Into<Trigger>,
        now: Instant,
    ) {
        let Some(rid) = resource_ids.first().copied() else {
            return;
        };

        self.upsert(
            AuthorizationTarget::Resource(rid),
            AuthorizationRequest::Resources(resource_ids),
            trigger.into(),
            now,
        );
    }

    /// Buffers the packet and asks the portal for access to the device through `pools`.
    #[tracing::instrument(level = "debug", skip_all, fields(%ip, ?pools))]
    pub fn on_not_authorized_device(
        &mut self,
        ip: IpAddr,
        pools: Vec<ResourceId>,
        packet: IpPacket,
        now: Instant,
    ) {
        self.upsert(
            AuthorizationTarget::Device { addr: ip },
            AuthorizationRequest::Device { addr: ip, pools },
            packet.into(),
            now,
        );
    }

    pub fn remove(
        &mut self,
        target: impl Into<AuthorizationTarget>,
    ) -> Option<PendingAuthorization> {
        self.inner.remove(&target.into())
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

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    #[test]
    fn skips_authorization_request_if_sent_within_last_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let rid = ResourceId::from_u128(1);

        pending.on_not_authorized_resource(vec![rid], udp_trigger(1), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );

        now += Duration::from_secs(1);

        pending.on_not_authorized_resource(vec![rid], udp_trigger(2), now);
        assert_eq!(pending.poll_authorization_requests(), None);
    }

    #[test]
    fn sends_new_request_after_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let rid = ResourceId::from_u128(1);

        pending.on_not_authorized_resource(vec![rid], udp_trigger(1), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid))
        );

        now += Duration::from_secs(3);

        pending.on_not_authorized_resource(vec![rid], udp_trigger(2), now);
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

        pending.on_not_authorized_resource(resource_ids.clone(), udp_trigger(1), Instant::now());

        assert_eq!(
            pending.poll_authorization_requests(),
            Some(AuthorizationRequest::Resources(resource_ids))
        );
        assert!(pending.remove(second).is_some());
        assert!(pending.remove(first).is_none());
    }

    #[test]
    fn sends_request_for_different_resources_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let rid1 = ResourceId::from_u128(1);
        let rid2 = ResourceId::from_u128(2);

        pending.on_not_authorized_resource(vec![rid1], udp_trigger(1), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(resource_request(rid1))
        );
        pending.on_not_authorized_resource(vec![rid2], udp_trigger(2), now);
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

        pending.on_not_authorized_device(ip, pools(), udp_trigger(1), now);
        assert!(pending.poll_authorization_requests().is_some());

        now += Duration::from_secs(1);

        pending.on_not_authorized_device(ip, pools(), udp_trigger(2), now);
        assert!(pending.poll_authorization_requests().is_none());
    }

    #[test]
    fn sends_new_device_request_after_two_seconds() {
        let mut pending = PendingAuthorizations::default();
        let mut now = Instant::now();
        let ip = device_ip();

        pending.on_not_authorized_device(ip, pools(), udp_trigger(1), now);
        assert!(pending.poll_authorization_requests().is_some());

        now += Duration::from_secs(3);

        pending.on_not_authorized_device(ip, pools(), udp_trigger(2), now);
        assert!(pending.poll_authorization_requests().is_some());
    }

    #[test]
    fn sends_request_for_different_devices_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending = PendingAuthorizations::default();
        let now = Instant::now();
        let ip_foo = device_ip();
        let ip_bar = other_device_ip();

        pending.on_not_authorized_device(ip_foo, pools(), udp_trigger(1), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(ip_foo))
        );
        pending.on_not_authorized_device(ip_bar, pools(), udp_trigger(2), now);
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

        pending.on_not_authorized_resource(vec![rid], udp_trigger(1), now);
        pending.on_not_authorized_device(ip, pools(), udp_trigger(2), now);
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
        pending.on_not_authorized_resource(vec![rid], udp_trigger(3), now);
        assert_eq!(pending.poll_authorization_requests(), None);

        // The device entry was removed: a new trigger requests again immediately.
        pending.on_not_authorized_device(ip, pools(), udp_trigger(4), now);
        assert_eq!(
            pending.poll_authorization_requests(),
            Some(device_request(ip))
        );
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

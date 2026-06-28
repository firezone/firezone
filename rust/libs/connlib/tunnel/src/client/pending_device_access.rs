use std::{
    collections::{HashMap, VecDeque},
    net::IpAddr,
    time::{Duration, Instant},
};

use connlib_model::{ClientId, ResourceId};
use ip_packet::IpPacket;

use crate::filter_engine::FilterEngine;
use crate::unique_packet_buffer::UniquePacketBuffer;

#[derive(Default)]
pub struct PendingDeviceAccessRequests {
    inner: HashMap<ClientId, PendingClientAccessRequest>,

    connection_intents: VecDeque<DeviceConnectionIntent>,
}

#[derive(Debug, Clone, Copy)]
pub struct DeviceConnectionIntent {
    pub resource_id: ResourceId,
    pub ip: IpAddr,
}

impl PendingDeviceAccessRequests {
    #[tracing::instrument(level = "debug", skip_all, fields(%client_id, %resource_id, %ip))]
    pub fn on_not_connected_device(
        &mut self,
        client_id: ClientId,
        resource_id: ResourceId,
        ip: IpAddr,
        filter: &FilterEngine,
        trigger: IpPacket,
        now: Instant,
    ) {
        if !is_trigger_allowed(filter, &trigger) {
            tracing::debug!("Trigger filtered by device filters, dropping");
            return;
        }

        let pending_flow = self.inner.entry(client_id).or_insert_with(|| {
            // Insert with a negative time to ensure we instantly send an intent.
            PendingClientAccessRequest::new(resource_id, now - Duration::from_secs(10))
        });

        pending_flow.push(trigger);

        let time_since_last_intent = now.duration_since(pending_flow.last_intent_sent_at);

        if time_since_last_intent < Duration::from_secs(2) {
            tracing::trace!(?time_since_last_intent, "Skipping connection intent");
            return;
        }

        tracing::debug!("Sending connection intent");

        pending_flow.last_intent_sent_at = now;
        self.connection_intents
            .push_back(DeviceConnectionIntent { resource_id, ip });
    }

    pub fn remove(&mut self, client_id: &ClientId) -> Option<PendingClientAccessRequest> {
        self.inner.remove(client_id)
    }

    pub fn poll_connection_intents(&mut self) -> Option<DeviceConnectionIntent> {
        self.connection_intents.pop_front()
    }
}

pub struct PendingClientAccessRequest {
    /// The resource that triggered this intent.
    resource_id: ResourceId,
    last_intent_sent_at: Instant,
    packets: UniquePacketBuffer,
}

impl PendingClientAccessRequest {
    /// How many packets we will at most buffer in a [`PendingClientAccessRequest`].
    const CAPACITY_POW_2: usize = 7; // 2^7 = 128

    fn new(resource_id: ResourceId, now: Instant) -> Self {
        Self {
            resource_id,
            last_intent_sent_at: now,
            packets: UniquePacketBuffer::with_capacity_power_of_2(
                Self::CAPACITY_POW_2,
                "pending-device-access",
            ),
        }
    }

    fn push(&mut self, packet: IpPacket) {
        self.packets.push(packet);
    }

    pub fn resource_id(&self) -> ResourceId {
        self.resource_id
    }

    pub fn into_buffered_packets(self) -> UniquePacketBuffer {
        let Self { packets, .. } = self;

        packets
    }
}

/// Check whether the device pool's filter allows the trigger packet, with
/// the malicious-behaviour `ignore_resource_filter` bypass available in tests.
fn is_trigger_allowed(filter: &FilterEngine, trigger: &IpPacket) -> bool {
    if filter.apply(trigger.destination_protocol()).is_ok() {
        return true;
    }

    #[cfg(any(test, feature = "test-util"))]
    if crate::malicious_behaviour::ignore_resource_filter() {
        tracing::debug!("Malicious client: ignoring resource filter");
        coverage::cov!("client.malicious_ignore_filter");
        return true;
    }

    false
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    #[test]
    fn skips_connection_intent_if_sent_within_last_two_seconds() {
        let mut pending_requests = PendingDeviceAccessRequests::default();
        let mut now = Instant::now();
        let cid = client_foo();
        let rid = ResourceId::from_u128(1);
        let ip = IpAddr::from(Ipv4Addr::new(100, 64, 0, 100));

        pending_requests.on_not_connected_device(cid, rid, ip, &permit_all(), trigger(1), now);
        assert!(pending_requests.poll_connection_intents().is_some());

        now += Duration::from_secs(1);

        pending_requests.on_not_connected_device(cid, rid, ip, &permit_all(), trigger(2), now);
        assert!(pending_requests.poll_connection_intents().is_none());
    }

    #[test]
    fn sends_new_intent_after_two_seconds() {
        let mut pending_requests = PendingDeviceAccessRequests::default();
        let mut now = Instant::now();
        let cid = client_foo();
        let rid = ResourceId::from_u128(1);
        let ip = IpAddr::from(Ipv4Addr::new(100, 64, 0, 100));

        pending_requests.on_not_connected_device(cid, rid, ip, &permit_all(), trigger(1), now);
        assert!(pending_requests.poll_connection_intents().is_some());

        now += Duration::from_secs(3);

        pending_requests.on_not_connected_device(cid, rid, ip, &permit_all(), trigger(2), now);
        assert!(pending_requests.poll_connection_intents().is_some());
    }

    #[test]
    fn sends_intent_for_different_clients_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending_flows = PendingDeviceAccessRequests::default();
        let now = Instant::now();
        let cid_foo = client_foo();
        let cid_bar = client_bar();
        let rid = ResourceId::from_u128(1);
        let ip_foo = IpAddr::from(Ipv4Addr::new(100, 64, 0, 100));
        let ip_bar = IpAddr::from(Ipv4Addr::new(100, 64, 0, 200));

        pending_flows.on_not_connected_device(cid_foo, rid, ip_foo, &permit_all(), trigger(1), now);
        let intent = pending_flows.poll_connection_intents().unwrap();
        assert_eq!(intent.ip, ip_foo);
        pending_flows.on_not_connected_device(cid_bar, rid, ip_bar, &permit_all(), trigger(2), now);
        let intent = pending_flows.poll_connection_intents().unwrap();
        assert_eq!(intent.ip, ip_bar);
    }

    fn trigger(payload: u8) -> IpPacket {
        ip_packet::make::udp_packet(
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::LOCALHOST,
            1,
            1,
            &[payload], // We need to vary the payload because identical packets don't get buffered.
        )
        .unwrap()
    }

    fn permit_all() -> FilterEngine {
        FilterEngine::PermitAll
    }

    fn client_foo() -> ClientId {
        ClientId::from_u128(1)
    }

    fn client_bar() -> ClientId {
        ClientId::from_u128(2)
    }
}

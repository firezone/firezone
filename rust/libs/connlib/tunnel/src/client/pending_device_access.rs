use std::{
    collections::{HashMap, VecDeque},
    net::Ipv4Addr,
    time::{Duration, Instant},
};

use ip_packet::IpPacket;

use crate::unique_packet_buffer::UniquePacketBuffer;

#[derive(Default)]
pub struct PendingDeviceAccessRequests {
    inner: HashMap<Ipv4Addr, PendingClientAccessRequest>,

    connection_intents: VecDeque<Ipv4Addr>,
}

impl PendingDeviceAccessRequests {
    #[tracing::instrument(level = "debug", skip_all, fields(%device))]
    pub fn on_not_connected_device(&mut self, device: Ipv4Addr, trigger: IpPacket, now: Instant) {
        let pending_flow = self
            .inner
            .entry(device.clone())
            .or_insert_with(|| PendingClientAccessRequest::new(now - Duration::from_secs(10))); // Insert with a negative time to ensure we instantly send an intent.

        pending_flow.push(trigger);

        let time_since_last_intent = now.duration_since(pending_flow.last_intent_sent_at);

        if time_since_last_intent < Duration::from_secs(2) {
            tracing::trace!(?time_since_last_intent, "Skipping connection intent");
            return;
        }

        tracing::debug!(%device, "Sending connection intent");

        pending_flow.last_intent_sent_at = now;
        self.connection_intents.push_back(device);
    }

    pub fn remove(&mut self, device: &Ipv4Addr) -> Option<PendingClientAccessRequest> {
        self.inner.remove(device)
    }

    pub fn poll_connection_intents(&mut self) -> Option<Ipv4Addr> {
        self.connection_intents.pop_front()
    }
}

pub struct PendingClientAccessRequest {
    last_intent_sent_at: Instant,
    packets: UniquePacketBuffer,
}

impl PendingClientAccessRequest {
    /// How many packets we will at most buffer in a [`PendingFlow`].
    ///
    /// `PendingFlow`s are per _resource_ (which could be Internet Resource or wildcard DNS resources).
    /// Thus, we may receive a fair few packets before we can send them.
    const CAPACITY_POW_2: usize = 7; // 2^7 = 128

    fn new(now: Instant) -> Self {
        Self {
            last_intent_sent_at: now,
            packets: UniquePacketBuffer::with_capacity_power_of_2(
                Self::CAPACITY_POW_2,
                "pending-client-access",
            ),
        }
    }

    fn push(&mut self, packet: IpPacket) {
        self.packets.push(packet);
    }

    pub fn into_buffered_packets(self) -> UniquePacketBuffer {
        let Self { packets, .. } = self;

        packets
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    #[test]
    fn skips_connection_intent_if_sent_within_last_two_seconds() {
        let mut pending_requests = PendingDeviceAccessRequests::default();
        let mut now = Instant::now();
        let device = device_foo();

        pending_requests.on_not_connected_device(device.clone(), trigger(1), now);
        assert_eq!(
            pending_requests.poll_connection_intents(),
            Some(device.clone())
        );

        now += Duration::from_secs(1);

        pending_requests.on_not_connected_device(device, trigger(2), now);
        assert_eq!(pending_requests.poll_connection_intents(), None);
    }

    #[test]
    fn sends_new_intent_after_two_seconds() {
        let mut pending_requests = PendingDeviceAccessRequests::default();
        let mut now = Instant::now();
        let device = device_foo();

        pending_requests.on_not_connected_device(device.clone(), trigger(1), now);
        assert_eq!(
            pending_requests.poll_connection_intents(),
            Some(device.clone())
        );

        now += Duration::from_secs(3);

        pending_requests.on_not_connected_device(device, trigger(2), now);
        assert_eq!(pending_requests.poll_connection_intents(), None);
    }

    #[test]
    fn sends_intent_for_different_clients_in_parallel() {
        let _guard = logging::test("trace");

        let mut pending_flows = PendingDeviceAccessRequests::default();
        let now = Instant::now();
        let device_foo = device_foo();
        let device_bar = device_bar();

        pending_flows.on_not_connected_device(device_foo.clone(), trigger(1), now);
        assert_eq!(pending_flows.poll_connection_intents(), Some(device_foo));
        pending_flows.on_not_connected_device(device_bar.clone(), trigger(2), now);
        assert_eq!(pending_flows.poll_connection_intents(), Some(device_bar));
    }

    fn trigger(payload: u8) -> IpPacket {
        ip_packet::make::udp_packet(
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::LOCALHOST,
            1,
            1,
            vec![payload], // We need to vary the payload because identical packets don't get buffered.
        )
        .unwrap()
    }

    fn device_foo() -> Ipv4Addr {
        Ipv4Addr::new(100, 64, 0, 100)
    }

    fn device_bar() -> Ipv4Addr {
        Ipv4Addr::new(100, 64, 0, 200)
    }
}

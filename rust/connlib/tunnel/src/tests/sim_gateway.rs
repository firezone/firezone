use super::{
    reference::{private_key, PrivateKey},
    sim_net::{any_ip_stack, any_port, host, Host},
};
use crate::{tests::sut::hickory_name_to_domain, GatewayState};
use connlib_shared::{messages::GatewayId, proptest::gateway_id, DomainName};
use ip_packet::{IpPacket, MutableIpPacket};
use proptest::prelude::*;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, HashSet, VecDeque},
    net::{IpAddr, SocketAddr},
    time::Instant,
};

/// Simulation state for a particular client.
#[derive(Debug, Clone)]
pub(crate) struct SimGateway {
    pub(crate) id: GatewayId,

    pub(crate) received_icmp_requests: VecDeque<IpPacket<'static>>,

    buffer: Vec<u8>,
}

impl SimGateway {
    pub(crate) fn new(id: GatewayId) -> Self {
        Self {
            id,
            received_icmp_requests: Default::default(),
            buffer: vec![0u8; (1 << 16) - 1],
        }
    }

    pub(crate) fn encapsulate(
        &mut self,
        sut: &mut GatewayState,
        packet: MutableIpPacket<'static>,
        now: Instant,
    ) -> Option<snownet::Transmit<'static>> {
        Some(sut.encapsulate(packet, now)?.into_owned())
    }

    pub(crate) fn handle_packet(
        &mut self,
        sut: &mut GatewayState,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
        payload: &[u8],
        src: SocketAddr,
        dst: SocketAddr,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        let packet = sut
            .decapsulate(dst, src, payload, now, &mut self.buffer)?
            .to_owned();

        self.on_received_packet(sut, global_dns_records, packet, now)
    }

    /// Process an IP packet received on the gateway.
    fn on_received_packet(
        &mut self,
        sut: &mut GatewayState,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
        packet: IpPacket<'_>,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        let packet = packet.to_owned();

        if packet.as_icmp().is_some() {
            self.received_icmp_requests.push_back(packet.clone());

            let echo_response = ip_packet::make::icmp_response_packet(packet);
            let maybe_transmit = self.encapsulate(sut, echo_response, now);

            return maybe_transmit;
        }

        if packet.as_udp().is_some() {
            let response = ip_packet::make::dns_ok_response(packet, |name| {
                global_dns_records
                    .get(&hickory_name_to_domain(name.clone()))
                    .cloned()
                    .into_iter()
                    .flatten()
            });

            let maybe_transmit = self.encapsulate(sut, response, now);

            return maybe_transmit;
        }

        panic!("Unhandled packet")
    }
}

/// Reference state for a particular gateway.
#[derive(Debug, Clone)]
pub struct RefGateway {
    pub(crate) key: PrivateKey,
}

impl RefGateway {
    /// Initialize the [`GatewayState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(self) -> GatewayState {
        GatewayState::new(self.key)
    }
}

pub(crate) fn ref_gateway_host() -> impl Strategy<Value = Host<RefGateway, GatewayId>> {
    host(any_ip_stack(), any_port(), ref_gateway(), gateway_id())
}

fn ref_gateway() -> impl Strategy<Value = RefGateway> {
    private_key().prop_map(move |key| RefGateway { key })
}
